import Foundation
#if canImport(Network)
import Network
#endif
#if canImport(AVFoundation) && canImport(CoreGraphics) && canImport(ImageIO)
import AVFoundation
import CoreGraphics
import ImageIO
#endif

// ─────────────────────────────────────────────────────────────────────────────
// CALL MODULE (Sources/ZolaKit/Call) — native voice/video calling.
// Verified with two-way voice and video calls on real iPhones. Incoming calls share the
// UXChatSocket (0x7d0) with realtime chat, so change socket/keySet/session code with care.
// ─────────────────────────────────────────────────────────────────────────────

extension ZolaClient {
    // MARK: - 5B. Persistent VoIP Incoming Listener (`UXChatSocket 0x7d0` keep-alive)

    /// `true` while the persistent background `0x7d0` listener is owned by `startVoipIncomingListener`.
    public func isVoipIncomingListenerActive() -> Bool {
        #if canImport(Network)
        return voipListenerActive
        #else
        return false
        #endif
    }

    /// Sanitized lifecycle flags only: no account identity, credential, host or payload.
    public func incomingCallListenerDiagnostic() async -> String {
        #if canImport(Network)
        let socketAlive = if let socket = activeVoipSocket { await socket.isSocketAlive() } else { false }
        return "active=\(voipListenerActive ? 1 : 0) socket=\(socketAlive ? 1 : 0) capable=\(session.canConnectLiveVoipSocket ? 1 : 0) expired=\(session.isExpired ? 1 : 0) native=\(session.zcidIsNative ? 1 : 0) keyset=\(session.hasValidKeySet ? 1 : 0) refresh=\(session.canRefreshKeySet ? 1 : 0)"
        #else
        return "unsupported=1"
        #endif
    }

    /// Starts (idempotently) the persistent incoming-call listener: an authenticated `UXChatSocket`
    /// (`0x7d0`, `EncryptProtocolVer2`, `keepAliveAfterCallEnd: true`, 20s heartbeat) that forwards
    /// every `ZolaVoipCallEvent` to `voipEventHandler`. The same socket is reused by
    /// `startVoipCall`/`answerVoipCall`/`rejectVoipCall`/`cancelVoipCall` while alive.
    ///
    /// Auto-reconnects on TCP drop with backoff `2s → 5s → 15s → 30s`; refreshes `keySetId` once on
    /// `retCode == -67`; **stops immediately** (circuit breaker) on `retCode == -1`, `102`, `-96`,
    /// `.safetyGate`, or `session.isExpired` to protect `session_key`.
    public func startVoipIncomingListener() async throws {
        try assertSessionAlive()
        try assertNativeSocketLocallyOwned()
        #if canImport(Network)
        if voipListenerActive {
            let generation = voipListenerGeneration
            // Foreground recovery should not wait through the supervisor's network backoff.
            if let existing = activeVoipSocket, await existing.isSocketAlive() {
                guard generation == voipListenerGeneration else { throw CancellationError() }
                return
            }
            do {
                try await voipListenerConnectOnce(generation: generation)
            } catch let error as ZolaError {
                guard generation == voipListenerGeneration else { throw CancellationError() }
                switch error {
                case .sessionExpired, .safetyGate, .invalidArgument:
                    await stopVoipIncomingListener()
                case let .server(code, _) where code == -1 || code == 102 || code == -96
                    || code == ZolaConstants.errorInvalidSessionKey:
                    await stopVoipIncomingListener()
                default: break // Existing supervisor retries transient transport failures.
                }
                throw error
            }
            return
        }
        guard session.canConnectLiveVoipSocket else {
            throw ZolaError.invalidArgument("Thiếu sessionKey để mở listener cuộc gọi Zalo")
        }
        let generation = UUID()
        voipListenerGeneration = generation
        voipListenerActive = true

        // Eager first connect: abort listener ONLY on terminal auth/safety circuit-breakers;
        // on transient transport errors, spawn `voipListenerLoop` so it reconnects automatically.
        var startupTransientError: Error?
        do {
            try await voipListenerConnectOnce(generation: generation)
        } catch let err as ZolaError {
            guard generation == voipListenerGeneration else { throw CancellationError() }
            switch err {
            case .sessionExpired, .safetyGate, .invalidArgument:
                voipListenerActive = false
                throw err
            case let .server(code, _)
                where code == -1 || code == 102 || code == -96 || code == ZolaConstants.errorInvalidSessionKey:
                voipListenerActive = false
                throw err
            default:
                startupTransientError = err
            }
        } catch {
            startupTransientError = error
        }

        guard generation == voipListenerGeneration, voipListenerActive else { throw CancellationError() }
        voipListenerTask = Task { [weak self] in
            await self?.voipListenerLoop(generation: generation)
        }
        if let startupTransientError {
            throw startupTransientError
        }
        #else
        throw ZolaError.transport("Nền tảng hiện tại không hỗ trợ Network.framework cho VoIP socket")
        #endif
    }

    /// Stops the background listener and closes its `0x7d0` socket.
    public func stopVoipIncomingListener() async {
        #if canImport(Network)
        voipListenerGeneration = UUID()
        voipListenerActive = false
        pendingCloudWakeupTask?.cancel()
        pendingCloudWakeupTask = nil
        chatSocketMailbox.removeAll()
        lastDrainedSocketObjectId = nil
        voipListenerTask?.cancel()
        voipListenerTask = nil
        sharedSocketGeneration = UUID()
        pendingSharedSocketID = nil
        pendingSharedSocketTask?.cancel()
        pendingSharedSocketTask = nil
        if let sock = activeVoipSocket {
            activeVoipSocket = nil
            await sock.close()
        }
        #endif
    }

    /// Raw `extendData` JSON captured from the `cmd=402` invite for `callId` (P2P endpoints,
    /// codec hints, `sP2P`/`tpType`). Stored outside `ZolaVoipCallEvent.incomingInvite` so the enum
    /// signature stays source-compatible with existing pattern matches.
    public func voipExtendData(forCallId callId: Int32) async -> String? {
        #if canImport(Network)
        if let sock = activeVoipSocket {
            return await sock.voipExtendData(forCallId: callId)
        }
        #endif
        return nil
    }

    /// Snapshot of `(rtpAddress, sessionId, extendData)` captured from `401`/`402`/`407`/`403`/`408` for `callId`.
    public func voipCallEndpoints(forCallId callId: Int32) async -> (rtpAddress: String, sessionId: String, extendData: String)? {
        #if canImport(Network)
        if let sock = activeVoipSocket, let ctx = await sock.callContext(forCallId: callId) {
            return (ctx.rtpAddress, ctx.sessionId, ctx.extendData)
        }
        #endif
        return nil
    }

    #if canImport(Network)
    /// Opens + authenticates the keep-alive listener socket via serialized `ensureSharedVoipSocket`
    /// so listener reconnects never open a duplicate `0x7d0` link over an active call socket.
    private func voipListenerConnectOnce(generation: UUID) async throws {
        guard generation == voipListenerGeneration, voipListenerActive else { throw CancellationError() }
        let sock = try await ensureSharedVoipSocket(
            heartbeatIntervalSeconds: 20.0,
            keepAliveAfterCallEnd: true
        )
        guard generation == voipListenerGeneration else { throw CancellationError() }
        guard voipListenerActive, session.canConnectLiveVoipSocket else {
            if activeVoipSocket === sock {
                activeVoipSocket = nil
            }
            await sock.close()
            return
        }
        await requestInitialSocketOfflineDrainIfNeeded(on: sock)
    }

    /// Reconnect supervisor: polls the live socket every second; on drop, cleans up and reconnects
    /// with capped exponential backoff until the circuit breaker trips or `voipListenerActive` clears.
    private func voipListenerLoop(generation: UUID) async {
        let backoffsNs: [UInt64] = [2, 5, 15, 30].map { $0 * 1_000_000_000 }
        var backoffIdx = 0
        while generation == voipListenerGeneration, voipListenerActive, !Task.isCancelled {
            // Circuit breaker: revoked/expired session — stop immediately, never retry.
            guard session.canConnectLiveVoipSocket else { break }

            if let sock = activeVoipSocket {
                let alive = await sock.isSocketAlive()
                guard generation == voipListenerGeneration, !Task.isCancelled else { break }
                if alive {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    continue
                }
                if activeVoipSocket === sock {
                    activeVoipSocket = nil
                    await sock.close()
                }
            }
            guard generation == voipListenerGeneration, !Task.isCancelled else { break }

            let delay = backoffsNs[min(backoffIdx, backoffsNs.count - 1)]
            backoffIdx += 1
            try? await Task.sleep(nanoseconds: delay)
            guard generation == voipListenerGeneration, voipListenerActive, !Task.isCancelled else { break }

            do {
                try await voipListenerConnectOnce(generation: generation)
                backoffIdx = 0
            } catch let err as ZolaError {
                if case .sessionExpired = err { break }
                if case .safetyGate = err { break }
                if case .server(let code, _) = err,
                   code == -1 || code == 102 || code == -96 || code == ZolaConstants.errorInvalidSessionKey
                {
                    break
                }
                // Transport/.server(other) → keep looping with the next backoff step.
            } catch {
                // Unknown transient → keep looping with the next backoff step.
            }
        }
        if generation == voipListenerGeneration { voipListenerActive = false }
    }
    #endif
}
