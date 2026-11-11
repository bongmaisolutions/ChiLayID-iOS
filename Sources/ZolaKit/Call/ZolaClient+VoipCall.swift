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

public struct ZolaVoipCallReceipt: Sendable, Equatable {
    public let ok: Bool
    public let callId: Int32
    public let clientCallId: Int32
    public let partnerUid: Int64
    public let isVideo: Bool
    public let preselectFrameSize: UInt32
    public let callFrameSize: UInt32
    public let relayHost: String
    public let relayPort: UInt16
    public let relayToken: String
    public let rtpAddress: String
    public let rtcpAddress: String
    public let voipSessionId: String
    public let serverStatus: Int
    public let serverCommands: [Int16]

    public init(
        ok: Bool,
        callId: Int32,
        clientCallId: Int32 = 0,
        partnerUid: Int64,
        isVideo: Bool,
        preselectFrameSize: UInt32,
        callFrameSize: UInt32,
        relayHost: String = "49.213.95.89",
        relayPort: UInt16 = 443,
        relayToken: String = "",
        rtpAddress: String = "",
        rtcpAddress: String = "",
        voipSessionId: String = "",
        serverStatus: Int = 0,
        serverCommands: [Int16] = []
    ) {
        self.ok = ok
        self.callId = callId
        self.clientCallId = clientCallId != 0 ? clientCallId : callId
        self.partnerUid = partnerUid
        self.isVideo = isVideo
        self.preselectFrameSize = preselectFrameSize
        self.callFrameSize = callFrameSize
        self.relayHost = relayHost
        self.relayPort = relayPort
        self.relayToken = relayToken
        self.rtpAddress = rtpAddress
        self.rtcpAddress = rtcpAddress
        self.voipSessionId = voipSessionId
        self.serverStatus = serverStatus
        self.serverCommands = serverCommands
    }
}

extension ZolaClient {
    // MARK: - 5. Native Zalo VoIP Signaling (`UXVoipSocket` + `VoipChatModule` `cmd=401/subCmd=4` -> `cmd=416/subCmd=2|3` -> `cmd=407`/`423`/`403`/`405`/`406`/`408`/`409`)

    public func setVoipEventHandler(_ handler: (@Sendable (ZolaVoipCallEvent) -> Void)?) async {
        self.voipEventHandler = handler
        #if canImport(Network)
        if let sock = activeVoipSocket {
            await sock.setEventHandler(handler)
        }
        #endif
    }

    /// Registers the real-time chat push/offline-batch consumer for `UXChatSocket` (`0x7d0`).
    /// Must be bound before `startVoipIncomingListener()` (or attaches immediately if `activeVoipSocket` is already live).
    public func setRealtimeEventHandler(_ handler: (@Sendable (ZolaEvent) -> Void)?) async {
        self.realtimeEventHandler = handler
        #if canImport(Network)
        if handler == nil {
            pendingCloudWakeupTask?.cancel()
            pendingCloudWakeupTask = nil
            chatSocketMailbox.removeAll()
        } else if let sock = activeVoipSocket, await sock.isSocketAlive() {
            await attachChatHandler(to: sock)
            await requestInitialSocketOfflineDrainIfNeeded(on: sock)
        }
        #endif
    }

    /// Opt-in durable intake for native socket message batches. Install before opening the socket.
    /// The second argument identifies offline/history delivery, which must not produce fresh alerts.
    /// Returning successfully means full message snapshots were persisted; throwing withholds the
    /// Delivered ACK and staged watermarks. A callback that merely starts a Task is not durable.
    /// Existing app/call clients keep the default nil behavior.
    public func setDurableRealtimeMessageHandler(
        _ handler: (@Sendable ([ZolaEvent], Bool) async throws -> Void)?
    ) {
        durableRealtimeMessageHandler = handler
    }

    public func closeVoipCallSession() async {
        pendingKeySetRefreshTask?.cancel()
        pendingKeySetRefreshId = nil
        pendingKeySetRefreshTask = nil
        #if canImport(Network)
        pendingCloudWakeupTask?.cancel()
        pendingCloudWakeupTask = nil
        chatSocketMailbox.removeAll()
        lastDrainedSocketObjectId = nil
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

    #if canImport(Network)
    private func attachChatHandler(to sock: ZolaVoipSocketSession) async {
        let mailbox = self.chatSocketMailbox
        await sock.setChatElementHandler { [weak self, weak sock] element in
            guard let self, let sock else { return }
            guard mailbox.push(element, socket: sock) else { return }
            Task { [weak self] in
                await self?.drainChatSocketElements()
            }
        }
    }

    private func drainChatSocketElements() async {
        guard !isDrainingChatSocketElements else { return }
        isDrainingChatSocketElements = true
        defer { isDrainingChatSocketElements = false }
        while true {
            let step = chatSocketMailbox.popNextOrFinishDrain()
            guard let next = step.item else {
                if step.didOverflow {
                    triggerCoalescedSocketWakeupPoll()
                }
                break
            }
            guard !session.isExpired, realtimeEventHandler != nil else {
                chatSocketMailbox.removeAll()
                break
            }
            guard let sock = next.socket else { continue }
            await handleIncomingChatSocketElement(next.element, fromSocket: sock)
        }
    }

    /// Serializes `0x7d0` `UXChatSocket` connection establishment so concurrent VoIP calls,
    /// background incoming-call listeners, and `FriendRequestManager` queries never open duplicate
    /// `AUTHEN subCmd = 5` connections that kick each other on Zalo's server.
    func ensureSharedVoipSocket(
        heartbeatIntervalSeconds: Double = 20.0,
        keepAliveAfterCallEnd: Bool
    ) async throws -> ZolaVoipSocketSession {
        try assertNativeSocketLocallyOwned()
        let generation = sharedSocketGeneration
        while true {
            try assertNativeSocketLocallyOwned()
            guard generation == sharedSocketGeneration else { throw CancellationError() }
            if let existing = activeVoipSocket {
                let alive = await existing.isSocketAlive()
                guard generation == sharedSocketGeneration else { throw CancellationError() }
                guard activeVoipSocket === existing else { continue }
                if alive {
                    await existing.setEventHandler(self.voipEventHandler)
                    await attachChatHandler(to: existing)
                    if keepAliveAfterCallEnd { await existing.enableKeepAliveAfterCallEnd() }
                    guard generation == sharedSocketGeneration else { throw CancellationError() }
                    guard activeVoipSocket === existing else { continue }
                    return existing
                }
                activeVoipSocket = nil
                await existing.close()
                continue // Re-read ownership after every suspension; never close a replacement.
            }
            if let inFlight = pendingSharedSocketTask {
                let taskID = pendingSharedSocketID
                let awaited = try await inFlight.value
                guard generation == sharedSocketGeneration else { throw CancellationError() }
                let alive = await awaited.isSocketAlive()
                guard generation == sharedSocketGeneration else { throw CancellationError() }
                // The creator may already have published this socket, or a different task may
                // have replaced it. Re-enter the loop to use the current owner in either case.
                if activeVoipSocket != nil { continue }
                guard pendingSharedSocketID == taskID else { continue }
                if alive {
                    // Publishing a completed shared task is safe for both its creator/waiters;
                    // leave task ownership intact until the creator has also resumed.
                    activeVoipSocket = awaited
                } else {
                    pendingSharedSocketID = nil
                    pendingSharedSocketTask = nil
                }
                continue
            }
            // No await between checking both owners and installing the new task.
            let shouldKeepAlive = keepAliveAfterCallEnd || voipListenerActive
            let hb = shouldKeepAlive ? max(heartbeatIntervalSeconds, 20.0) : heartbeatIntervalSeconds
            let task = Task<ZolaVoipSocketSession, Error> {
                try await self.openVoipSocket(
                    heartbeatIntervalSeconds: hb,
                    keepAliveAfterCallEnd: shouldKeepAlive,
                    onEvent: self.voipEventHandler
                )
            }
            let taskID = UUID()
            pendingSharedSocketID = taskID
            pendingSharedSocketTask = task
            do {
                let connected = try await task.value
                guard generation == sharedSocketGeneration, pendingSharedSocketID == taskID else {
                    await connected.close()
                    throw CancellationError()
                }
                pendingSharedSocketID = nil
                pendingSharedSocketTask = nil
                activeVoipSocket = connected
                return connected
            } catch {
                if pendingSharedSocketID == taskID {
                    pendingSharedSocketID = nil
                    pendingSharedSocketTask = nil
                }
                throw error
            }
        }
    }
    #endif

    func makeVoipAuthenPayload(srcId: Int32) -> Data {
        let (imei, platform) = ZolaCrypto.extractZCIDIdentity(zcid: session.zcid)
        return ZolaCrypto.packSocketAuthenFrame(
            srcId: srcId,
            sessionKey: session.sessionKey,
            deviceModel: platform,
            imei: imei,
            subCmd: 5,
            seqId: 1
        ).payload
    }

    #if canImport(Network)
    private func obtainAuthenticatedVoipSocket(
        partnerUid: Int64,
        callId: Int32,
        isVideo: Bool
    ) async throws -> ZolaVoipSocketSession {
        try assertNativeSocketLocallyOwned()
        if let existing = activeVoipSocket, await existing.matchesCall(callId: callId, partnerUid: partnerUid) {
            try assertNativeSocketLocallyOwned()
            return existing
        }
        throw ZolaError.safetyGate("Không mở mới kết nối UXVoipSocket ngoài phiên gọi đang hoạt động để bảo vệ phiên đăng nhập Zalo.")
    }

    /// Merges the session's `socketServers` endpoints with the two live-verified
    /// `ZolaVoipProtocol.defaultVerifiedEncryptedEndpoints` (`49.213.95.89`/`.90`, real X25519
    /// `pubKey`), deduplicated by `host:port`. Sessions persisted before `socketServers` existed
    /// therefore still satisfy the `EncryptProtocolVer2` gate without forcing a re-login.
    func resolvedLiveVoipEndpoints() -> [ZolaVoipEndpoint] {
        var seen = Set<String>()
        var merged: [ZolaVoipEndpoint] = []
        for ep in session.encryptedSocketEndpoints {
            let key = "\(ep.host):\(ep.port)"
            guard seen.insert(key).inserted else { continue }
            merged.append(
                ZolaVoipEndpoint(host: ep.host, port: ep.port, serverPubKeyBase64: ep.serverPubKeyBase64)
            )
        }
        for ep in ZolaVoipProtocol.defaultVerifiedEncryptedEndpoints {
            let key = "\(ep.host):\(ep.port)"
            guard seen.insert(key).inserted else { continue }
            merged.append(ep)
        }
        return merged
    }

    /// Opens + authenticates a `UXChatSocket` (`0x7d0`) for VoIP:
    /// - `voipLoopbackEndpoints` configured (unit tests) → plaintext loopback session.
    /// - Otherwise → `EncryptProtocolVer2` (`0x08` X25519 + `0x04` AES-256-GCM) over
    ///   `resolvedLiveVoipEndpoints()`, refreshing `keySetId` at most once on `retCode == -67`.
    /// Throws `.sessionExpired` for `102`/`-96`, `.safetyGate` when native `zcid`/key material is
    /// missing — callers must not bypass those errors.
    private func openVoipSocket(
        heartbeatIntervalSeconds: Double = 18.0,
        keepAliveAfterCallEnd: Bool = false,
        onEvent: (@Sendable (ZolaVoipCallEvent) -> Void)?
    ) async throws -> ZolaVoipSocketSession {
        try assertNativeSocketLocallyOwned()
        let ownershipGeneration = nativeSocketOwnershipGeneration
        let srcId = Int32(truncatingIfNeeded: session.uid)

        if let safeEndpoints = voipLoopbackEndpoints,
           !safeEndpoints.isEmpty,
           safeEndpoints.allSatisfy({ ZolaVoipProtocol.isLoopbackHost($0.host) }) {
            let loopbackSock = ZolaVoipSocketSession(
                selfUid: session.uid,
                authenPayload: makeVoipAuthenPayload(srcId: srcId),
                encryptedEndpoints: safeEndpoints.map {
                    ZolaVoipEndpoint(host: $0.host, port: $0.port, serverPubKeyBase64: nil)
                },
                socketCrypto: nil,
                heartbeatIntervalSeconds: heartbeatIntervalSeconds,
                keepAliveAfterCallEnd: keepAliveAfterCallEnd,
                onEvent: onEvent,
                incomingPartnerAllowlist: incomingVoipPartnerAllowlist
            )
            await attachChatHandler(to: loopbackSock)
            try await connectLocallyOwnedSocket(loopbackSock, generation: ownershipGeneration)
            return loopbackSock
        }

        guard session.zcidIsNative else {
            throw ZolaError.safetyGate(
                "Nick này chưa có khoá zcid gốc của iOS Native. Hãy đăng nhập trực tiếp nick này bằng đăng nhập native (ZolaLoginClient)."
            )
        }
        try assertSocketKeySetUsable()
        let endpoints = resolvedLiveVoipEndpoints()
        if !session.hasValidKeySet {
            if session.canRefreshKeySet {
                _ = try await refreshKeySetForNativeSocket(generation: ownershipGeneration)
            } else {
                throw ZolaError.safetyGate(Self.legacyMissingVoipKeySetMessage)
            }
        }
        guard let initialKsId = session.keySetId,
              let initialKsVal = session.keySetValue,
              session.hasValidKeySet
        else {
            throw ZolaError.safetyGate(Self.legacyMissingVoipKeySetMessage)
        }

        let initialCrypto = try ZolaSocketCrypto(
            keySetId: initialKsId,
            keySetValueBase64: initialKsVal
        )
        var candidateSock = ZolaVoipSocketSession(
            selfUid: session.uid,
            authenPayload: makeVoipAuthenPayload(srcId: srcId),
            encryptedEndpoints: endpoints,
            socketCrypto: initialCrypto,
            heartbeatIntervalSeconds: heartbeatIntervalSeconds,
            keepAliveAfterCallEnd: keepAliveAfterCallEnd,
            onEvent: onEvent,
            incomingPartnerAllowlist: incomingVoipPartnerAllowlist
        )
        await attachChatHandler(to: candidateSock)
        do {
            try await connectLocallyOwnedSocket(candidateSock, generation: ownershipGeneration)
        } catch let ZolaError.sessionExpired(code, ep, msg) {
            session.markExpired(code: code, reason: msg)
            throw ZolaError.sessionExpired(code: code, endpoint: ep, message: msg)
        } catch let ZolaError.server(code, _) where code == ZolaConstants.errorInvalidSessionKey {
            // `retCode == -67` on `0x7d0` indicates stale/rotated `keySetId`: close rejected socket and refresh `/api/helper/getKeySet` at most once.
            await candidateSock.close()
            let previousKsVal = session.keySetValue
            let refreshed = try await refreshKeySetForNativeSocket(generation: ownershipGeneration)
            let refreshedCrypto = try ZolaSocketCrypto(
                keySetId: refreshed.keySetId,
                keySetValueBase64: refreshed.keySetValue,
                previousKeySetValueBase64: previousKsVal
            )
            candidateSock = ZolaVoipSocketSession(
                selfUid: session.uid,
                authenPayload: makeVoipAuthenPayload(srcId: srcId),
                encryptedEndpoints: endpoints,
                socketCrypto: refreshedCrypto,
                heartbeatIntervalSeconds: heartbeatIntervalSeconds,
                keepAliveAfterCallEnd: keepAliveAfterCallEnd,
                onEvent: onEvent,
                incomingPartnerAllowlist: incomingVoipPartnerAllowlist
            )
            await attachChatHandler(to: candidateSock)
            do {
                try await connectLocallyOwnedSocket(candidateSock, generation: ownershipGeneration)
            } catch let ZolaError.sessionExpired(expCode, expEp, expMsg) {
                session.markExpired(code: expCode, reason: expMsg)
                throw ZolaError.sessionExpired(code: expCode, endpoint: expEp, message: expMsg)
            }
        }
        return candidateSock
    }
    #endif

    #if canImport(Network) && canImport(AVFoundation) && canImport(AudioToolbox)
    /// Claims ownership of the `ZolaVoipMediaEngine` whose UDP socket was pre-registered with the
    /// ZRTC `:4200` relay (`initZRTPToServer` `pktCmd = 11`) before `cmd = 416` in `startVoipCall`,
    /// preserving the exact ephemeral UDP port for subsequent `0x7f` RTP media.
    public func takePreparedVoipMediaEngine(forCallId callId: Int32) -> ZolaVoipMediaEngine? {
        guard let engine = preparedVoipMediaEngine else { return nil }
        if callId == 0 || engine.callId == callId {
            preparedVoipMediaEngine = nil
            return engine
        }
        return nil
    }
    #endif

    private func discardPreparedVoipMediaEngine() {
        #if canImport(Network) && canImport(AVFoundation) && canImport(AudioToolbox)
        preparedVoipMediaEngine?.stopAsync()
        preparedVoipMediaEngine = nil
        #endif
    }

    public func startVoipCall(
        partnerUid: Int64,
        callId: Int32? = nil,
        isVideo: Bool = false,
        localEndpoint: String = "",
        rtpAddress: String = "49.213.95.89:10000",
        rtcpAddress: String = "49.213.95.89:10001",
        dryRun: Bool = false
    ) async throws -> ZolaVoipCallReceipt {
        try assertSessionAlive()
        let srcId = Int32(truncatingIfNeeded: session.uid)
        let partnerId = Int32(truncatingIfNeeded: partnerUid)
        let resolvedCallId = callId ?? Int32(truncatingIfNeeded: Int64(Date().timeIntervalSince1970) & 0x7FFFFFFF)
        let extendJson = ZolaCrypto.makeVoipExtendDataJson(localEndpoint: localEndpoint, isVideo: isVideo)

        let preselectFrame = ZolaCrypto.packVoipPreselectFrame(
            srcId: srcId,
            partnerId: partnerId,
            requestId: resolvedCallId,
            subCmd: 3,
            seqId: 2
        )
        let callFrame = ZolaCrypto.packVoipCallRequestFrame(
            srcId: srcId,
            partnerId: partnerId,
            callId: resolvedCallId,
            isVideo: isVideo,
            codec: ZolaCrypto.defaultVoipCodecJson,
            paramsJson: extendJson,
            seqId: 3
        )

        if dryRun {
            return ZolaVoipCallReceipt(
                ok: true,
                callId: resolvedCallId,
                clientCallId: resolvedCallId,
                partnerUid: partnerUid,
                isVideo: isVideo,
                preselectFrameSize: preselectFrame.frameSize,
                callFrameSize: callFrame.frameSize,
                relayHost: "49.213.95.89",
                relayPort: 443,
                relayToken: "",
                rtpAddress: rtpAddress,
                rtcpAddress: rtcpAddress,
                voipSessionId: String(resolvedCallId),
                serverStatus: 0,
                serverCommands: []
            )
        }

        discardPreparedVoipMediaEngine()

        #if canImport(Network)
        guard session.canConnectLiveVoipSocket else {
            throw ZolaError.invalidArgument("Thiếu sessionKey để kết nối cuộc gọi Zalo")
        }
        inFlightVoipClientCallId = resolvedCallId
        inFlightVoipServerCallId = 0
        defer {
            inFlightVoipClientCallId = 0
            inFlightVoipServerCallId = 0
        }

        let sock = try await ensureSharedVoipSocket(
            heartbeatIntervalSeconds: voipListenerActive ? 20.0 : 18.0,
            keepAliveAfterCallEnd: voipListenerActive
        )
        let ownsSocket = !(await sock.isKeepAliveEnabled())

        let handler = self.voipEventHandler
        if cancelledClientCallIds.remove(resolvedCallId) != nil {
            if ownsSocket {
                await sock.close()
            } else {
                await sock.unbindCall()
            }
            throw ZolaError.transport("Cuộc gọi đã được huỷ trước khi đổ chuông")
        }

        await sock.bindCall(
            serverCallId: resolvedCallId,
            clientCallId: resolvedCallId,
            partnerUid: partnerUid,
            isVideo: isVideo
        )
        handler?(
            .connecting(
                callId: resolvedCallId,
                clientCallId: resolvedCallId,
                partnerUid: partnerUid,
                isVideo: isVideo
            )
        )

        // Step 0 (`cmd = 425, subCmd = 3`): fire-and-forget preselect relay server (`0x102fa8528`).
        let preSeq = await sock.nextSeqId()
        let livePreselect = ZolaCrypto.packVoipPreselectFrame(
            srcId: srcId,
            partnerId: partnerId,
            requestId: resolvedCallId,
            subCmd: 3,
            seqId: preSeq
        )
        try? await sock.sendFrame(livePreselect)

        let reqSeq = await sock.nextSeqId()
        let liveCallFrame = ZolaCrypto.packVoipCallRequestFrame(
            srcId: srcId,
            partnerId: partnerId,
            callId: resolvedCallId,
            isVideo: isVideo,
            codec: ZolaCrypto.defaultVoipCodecJson,
            paramsJson: extendJson,
            seqId: reqSeq
        )

        let resp401: ZolaUnpackedChatElement
        do {
            resp401 = try await sock.sendAndWait(
                rawPayload: liveCallFrame.payload,
                expectedCmd: 401,
                timeoutSeconds: 6.0
            )
        } catch {
            // Tear down only a socket this call opened; the shared listener socket just unbinds.
            if ownsSocket {
                await sock.close()
            } else {
                await sock.unbindCall()
            }
            throw error
        }

        let parsed = ZolaVoipProtocol.parseCallResponse(
            from: resp401,
            fallbackCallId: resolvedCallId,
            fallbackRtpAddress: rtpAddress,
            fallbackRtcpAddress: rtcpAddress
        )

        guard parsed.isAllowed else {
            if ownsSocket {
                await sock.close()
            } else {
                await sock.unbindCall()
            }
            let errText = ZolaVoipProtocol.describeCallError(
                errorCode: parsed.errorCode,
                status: parsed.status,
                serverMessage: parsed.errorMessage
            )
            if parsed.status == 6 {
                handler?(.busy(callId: parsed.serverCallId, partnerUid: partnerUid))
            } else {
                handler?(
                    .failed(
                        callId: parsed.serverCallId,
                        partnerUid: partnerUid,
                        code: parsed.errorCode != 0 ? parsed.errorCode : parsed.status,
                        message: errText
                    )
                )
            }
            throw ZolaError.server(
                code: parsed.errorCode != 0 ? parsed.errorCode : parsed.status,
                message: errText
            )
        }

        inFlightVoipServerCallId = parsed.serverCallId
        if cancelledClientCallIds.remove(resolvedCallId) != nil
            || cancelledClientCallIds.remove(parsed.serverCallId) != nil
        {
            let cancelSeq = await sock.nextSeqId()
            let cancelFrame = ZolaCrypto.packVoipCancelCallFrame(
                srcId: srcId,
                partnerId: partnerId,
                callId: parsed.serverCallId,
                status: 1,
                isVideo: isVideo,
                seqId: cancelSeq
            )
            try? await sock.sendFrame(cancelFrame)
            if ownsSocket {
                await sock.close()
            } else {
                await sock.unbindCall()
            }
            throw ZolaError.transport("Cuộc gọi đã được huỷ trước khi đổ chuông")
        }

        await sock.bindCall(
            serverCallId: parsed.serverCallId,
            clientCallId: resolvedCallId,
            partnerUid: partnerUid,
            isVideo: isVideo
        )
        await sock.storeCallContext(
            callId: parsed.serverCallId,
            sessionId: parsed.sessionId,
            rtpAddress: parsed.rtpAddress,
            rtcpAddress: parsed.rtcpAddress,
            extendData: parsed.extendDataString
        )

        var reflectedPublicAddr = ""
        #if canImport(AVFoundation) && canImport(AudioToolbox)
        let preSnap = await sock.snapshotCommands()
        let isLoopbackSignaling = (voipLoopbackEndpoints?.isEmpty == false)
            || ZolaVoipProtocol.isLoopbackHost(preSnap.host)
        if !parsed.sessionId.isEmpty,
           let relayEp = ZolaVoipMediaEngine.parseEndpointString(parsed.rtpAddress),
           (!isLoopbackSignaling || ZolaVoipProtocol.isLoopbackHost(relayEp.host))
        {
            let mediaEngine = ZolaVoipMediaEngine(callId: parsed.serverCallId)
            if isVideo {
                mediaEngine.setVideoMode(enabled: true)
            }
            if ZolaVoipProtocol.isLoopbackHost(relayEp.host) {
                mediaEngine.forceZrtcFramingOnLoopback = true
            }
            mediaEngine.configureZrtcSession(
                isCaller: true,
                selfUid: session.uid,
                partnerUid: partnerUid,
                sessionId: parsed.sessionId
            )
            let preferredLocalPort = ZolaVoipMediaEngine.parseEndpointString(localEndpoint)?.port ?? 0
            do {
                do {
                    try mediaEngine.prepareTransport(relay: relayEp, preferredLocalPort: preferredLocalPort)
                } catch {
                    throw ZolaError.server(code: -3401, message: "Không thể chuẩn bị đường truyền cuộc gọi.")
                }
                let relayReady = await mediaEngine.waitForRelayHandshake(timeoutMs: isLoopbackSignaling ? 1200 : 3000)
                try Task.checkCancellation()
                guard relayReady else {
                    throw ZolaError.server(code: -3402, message: "Máy chủ cuộc gọi chưa xác nhận kết nối. Vui lòng thử lại.")
                }
            } catch {
                mediaEngine.stopAsync()
                // The allocated native call must be cancelled without ever publishing416. Never
                // unbind a newer call if this suspended setup lost ownership in the meantime.
                if await sock.matchesCall(callId: parsed.serverCallId, partnerUid: partnerUid) {
                    let cancelSeq = await sock.nextSeqId()
                    let cancel = ZolaCrypto.packVoipCancelCallFrame(srcId: srcId, partnerId: partnerId,
                        callId: parsed.serverCallId, status: 1, isVideo: isVideo, seqId: cancelSeq)
                    try? await sock.sendFrame(cancel)
                    await sock.finishFailedOutgoingSetup(callId: parsed.serverCallId,
                        partnerUid: partnerUid, closeSocket: ownsSocket)
                }
                if case let ZolaError.server(code, message) = error {
                    NSLog("zolakit outgoing-relay setup-failed code=%d video=%d", code, isVideo ? 1 : 0)
                    handler?(.failed(callId: parsed.serverCallId, partnerUid: partnerUid, code: code, message: message))
                }
                throw error
            }

            if cancelledClientCallIds.remove(resolvedCallId) != nil
                || cancelledClientCallIds.remove(parsed.serverCallId) != nil
            {
                mediaEngine.stopAsync()
                let cancelSeq = await sock.nextSeqId()
                let cancelFrame = ZolaCrypto.packVoipCancelCallFrame(
                    srcId: srcId,
                    partnerId: partnerId,
                    callId: parsed.serverCallId,
                    status: 1,
                    isVideo: isVideo,
                    seqId: cancelSeq
                )
                try? await sock.sendFrame(cancelFrame)
                let logSeq = await sock.nextSeqId()
                let logFrame = ZolaCrypto.packVoipFinishCallLogFrame(
                    srcId: srcId,
                    partnerId: partnerId,
                    callId: parsed.serverCallId,
                    status: 162,
                    durationSeconds: 0,
                    protocolVersion: 3,
                    sendType: 1,
                    paramsJson: #"{"ver":4,"net":1,"rel":1}"#,
                    seqId: logSeq
                )
                try? await sock.sendFrame(logFrame)
                if ownsSocket {
                    await sock.close()
                } else {
                    await sock.unbindCall()
                }
                throw ZolaError.transport("Cuộc gọi đã được huỷ trước khi đổ chuông")
            }

            reflectedPublicAddr = mediaEngine.reflectedPublicEndpoint
            self.preparedVoipMediaEngine = mediaEngine
        }
        #endif

        let zrtpExternData = ZolaCrypto.makeVoipExtendDataJson(
            localEndpoint: localEndpoint,
            reflectedPublicEndpoint: reflectedPublicAddr,
            rtpServerAddr: parsed.rtpAddress,
            rtcpServerAddr: parsed.rtcpAddress,
            isVideo: isVideo
        )
        ownVoipExtendDataByCallId = [parsed.serverCallId: zrtpExternData]

        // Step 2 (`ZrtpVoipService::requestVoiceToZrtpByClientCallId:` -> `cmd=416/subCmd=2|3`):
        // Transmits canonical `serverCallId`, `defaultVoipCodecJson`, `rtpIP`, `rtcpIP`, `sessId`, `extendData`
        // AFTER caller UDP `InitZRTP` (`pktCmd=11`) registration so Zalo pushes the call invite cleanly without premature `cmd=403 status=5`.
        let zrtpSeq = await sock.nextSeqId()
        let zrtpFrame = ZolaCrypto.packVoipRequestZRTPFrame(
            srcId: srcId,
            partnerId: partnerId,
            callId: parsed.serverCallId,
            isVideo: isVideo,
            codec: ZolaCrypto.defaultVoipCodecJson,
            rtpAddress: parsed.rtpAddress,
            rtcpAddress: parsed.rtcpAddress,
            sessionId: parsed.sessionId,
            externData: zrtpExternData,
            source: 1,
            seqId: zrtpSeq
        )
        do {
            try await sock.sendFrame(zrtpFrame)
        } catch {
            discardPreparedVoipMediaEngine()
            if ownsSocket {
                await sock.close()
            } else {
                await sock.unbindCall()
            }
            throw error
        }

        self.activeVoipSocket = sock
        let snap = await sock.snapshotCommands()

        return ZolaVoipCallReceipt(
            ok: true,
            callId: parsed.serverCallId,
            clientCallId: resolvedCallId,
            partnerUid: partnerUid,
            isVideo: isVideo,
            preselectFrameSize: preselectFrame.frameSize,
            callFrameSize: liveCallFrame.frameSize,
            relayHost: parsed.relayHost,
            relayPort: parsed.relayPort,
            relayToken: parsed.relayToken,
            rtpAddress: parsed.rtpAddress,
            rtcpAddress: parsed.rtcpAddress,
            voipSessionId: parsed.sessionId,
            serverStatus: parsed.status,
            serverCommands: snap.commands
        )
        #else
        throw ZolaError.transport("Nền tảng hiện tại không hỗ trợ Network.framework cho VoIP socket")
        #endif
    }

    public func answerVoipCall(
        partnerUid: Int64,
        callId: Int32,
        isVideo: Bool = false,
        localEndpoint: String = "",
        rtpAddress: String = "",
        rtcpAddress: String = "",
        sessionId: String = "",
        dryRun: Bool = false
    ) async throws {
        try assertSessionAlive()
        let srcId = Int32(truncatingIfNeeded: session.uid)
        let partnerId = Int32(truncatingIfNeeded: partnerUid)
        let answerFrame = ZolaCrypto.packVoipAnswerCallFrame(
            srcId: srcId,
            partnerId: partnerId,
            callId: callId,
            status: 0,
            sessionId: sessionId,
            rtpAddress: rtpAddress,
            seqId: 3
        )
        guard !dryRun else {
            _ = answerFrame
            return
        }

        #if canImport(Network)
        let sock = try await obtainAuthenticatedVoipSocket(
            partnerUid: partnerUid,
            callId: callId,
            isVideo: isVideo
        )
        let cached = await sock.callContext(forCallId: callId)
        let resolvedSessionId = !sessionId.isEmpty ? sessionId : (cached?.sessionId ?? "")
        let resolvedRtp = !rtpAddress.isEmpty ? rtpAddress : (cached?.rtpAddress ?? "")
        let answerExtend = ZolaCrypto.makeVoipExtendDataJson(
            localEndpoint: localEndpoint,
            rtpServerAddr: resolvedRtp,
            isVideo: isVideo
        )
        ownVoipExtendDataByCallId = [callId: answerExtend]
        // Callee accept (`ZrtpVoipService` `0x102f9fad8` -> `VoipRequestOperation` `0x102f93234`):
        // sends ONLY `cmd = 402, subCmd = 3` (`status = 0`) with `[sessId, rtpIP, "", codecJson, extendDataJson]`;
        // server pushes `cmd = 403` to caller; caller confirms via 408 after relay readiness,
        // allowing the callee to receive `didReceiveCallRequestAnswerACK:`.
        let seq = await sock.nextSeqId()
        let liveFrame = ZolaCrypto.packVoipAnswerCallFrame(
            srcId: srcId,
            partnerId: partnerId,
            callId: callId,
            status: 0,
            sessionId: resolvedSessionId,
            rtpAddress: resolvedRtp,
            rtpServer: "",
            codec: ZolaCrypto.defaultVoipCodecJson,
            paramsJson: answerExtend,
            seqId: seq
        )
        try await sock.sendFrame(liveFrame)
        #endif
    }

    /// Complete the caller's native 403 → relay-ready → 408 handshake. Invoke only after
    /// the media transport confirms its primary relay; duplicate calls are idempotent.
    /// This uses the existing bound socket and cannot open or transfer socket ownership.
    public func acknowledgeOutgoingVoipAnswer(partnerUid: Int64, callId: Int32) async throws {
        try assertSessionAlive()
        #if canImport(Network)
        guard !nativeSocketExternallyOwned, let socket = activeVoipSocket else {
            throw ZolaError.safetyGate("Không có kết nối sở hữu cuộc gọi đi")
        }
        try await socket.acknowledgeOutgoingAnswer(partnerUid: partnerUid, callId: callId)
        #else
        throw ZolaError.transport("Xác nhận cuộc gọi cần Network.framework")
        #endif
    }

    public func ackVoipRinging(
        partnerUid: Int64,
        callId: Int32,
        dryRun: Bool = false
    ) async throws {
        try assertSessionAlive()
        let srcId = Int32(truncatingIfNeeded: session.uid)
        let partnerId = Int32(truncatingIfNeeded: partnerUid)
        let ackFrame = ZolaCrypto.packVoipRingingAckFrame(
            srcId: srcId,
            partnerId: partnerId,
            callId: callId,
            seqId: 4
        )
        guard !dryRun else { return }

        #if canImport(Network)
        let sock = try await obtainAuthenticatedVoipSocket(
            partnerUid: partnerUid,
            callId: callId,
            isVideo: false
        )
        let seq = await sock.nextSeqId()
        let liveFrame = ZolaCrypto.packVoipRingingAckFrame(
            srcId: srcId,
            partnerId: partnerId,
            callId: callId,
            seqId: seq
        )
        _ = ackFrame
        try await sock.sendFrame(liveFrame)
        #endif
    }

    /// Sends `cmd = 421, subCmd = 0` (`VoipRequestOperation` `0x102f94f0c`) over the active `0x7d0` VoIP socket
    /// to notify the remote peer when our local camera is turned on (`isCameraOn == true`) or off (`isCameraOn == false`).
    public func sendVoipCameraState(
        partnerUid: Int64,
        callId: Int32,
        isCameraOn: Bool,
        reason: Int32 = 0,
        dryRun: Bool = false
    ) async throws {
        try assertSessionAlive()
        let srcId = Int32(truncatingIfNeeded: session.uid)
        let partnerId = Int32(truncatingIfNeeded: partnerUid)
        let previewFrame = ZolaCrypto.packVoipVideoCameraStateFrame(
            srcId: srcId,
            partnerId: partnerId,
            callId: callId,
            isCameraOn: isCameraOn,
            reason: reason,
            seqId: 6
        )
        guard !dryRun else {
            _ = previewFrame
            return
        }

        #if canImport(Network)
        guard let sock = activeVoipSocket else {
            return
        }
        let seq = await sock.nextSeqId()
        let liveFrame = ZolaCrypto.packVoipVideoCameraStateFrame(
            srcId: srcId,
            partnerId: partnerId,
            callId: callId,
            isCameraOn: isCameraOn,
            reason: reason,
            seqId: seq
        )
        try await sock.sendFrame(liveFrame)
        #endif
    }

    /// Rebuilds the `extendData` advertised in a `cmd = 416` ZRTP frame so it negotiates **video**:
    /// flips `callType` to `1` and injects the `video.codec = h264/payload 97` block (`libzrtc
    /// _parseExtendData`), while preserving the P2P / relay candidates already negotiated during the
    /// voice phase. Falls back to a fresh video `extendData` only when the base JSON is missing/unparseable.
    static func makeVoipVideoUpgradeExtendData(from base: String?) -> String {
        if let base,
           let data = base.data(using: .utf8),
           var dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        {
            dict["callType"] = 1
            dict["sP2P"] = 0
            dict["supportHevcDecode"] = 0
            dict["video"] = ["codec": [["name": "h264", "payload": 97]]]
            if let out = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
               let str = String(data: out, encoding: .utf8)
            {
                return str
            }
        }
        return ZolaCrypto.makeVoipExtendDataJson(isVideo: true)
    }

    /// Pure builder for the voice→video upgrade frame (`cmd = 416, subCmd = 3`). Kept separate from
    /// `upgradeVoipToVideo` so it can be unit-tested without opening a live `0x7d0` socket.
    static func buildVoipVideoUpgradeFrame(
        srcId: Int32,
        partnerId: Int32,
        callId: Int32,
        codec: String = ZolaCrypto.defaultVoipCodecJson,
        baseExtendData: String?,
        rtpAddress: String,
        rtcpAddress: String,
        sessionId: String,
        seqId: Int32
    ) -> ZolaChatElementFrame {
        ZolaCrypto.packVoipRequestZRTPFrame(
            srcId: srcId,
            partnerId: partnerId,
            callId: callId,
            isVideo: true,
            codec: codec,
            rtpAddress: rtpAddress,
            rtcpAddress: rtcpAddress,
            sessionId: sessionId,
            externData: makeVoipVideoUpgradeExtendData(from: baseExtendData),
            source: 1,
            seqId: seqId
        )
    }

    /// Promotes an in-progress **voice** call to **video** by re-broadcasting the ZRTP negotiation
    /// frame (`cmd = 416, subCmd = 3`, `callType = 1` + h264 codec) over the live `0x7d0` VoIP socket.
    ///
    /// A voice call negotiated `subCmd = 2` with no `video.codec` block, so turning the local camera
    /// on with `sendVoipCameraState` (`cmd = 421`) alone never makes the relay/peer open a video
    /// stream — the outbound `0x0d` video packets are dropped and the peer never sends video back,
    /// killing video **both ways** while audio keeps working. This frame renegotiates the session to
    /// video so the relay forwards video in both directions. Pair it with `sendVoipCameraState`.
    ///
    /// Throws (instead of silently returning) when there is no active VoIP socket, so a lost upgrade
    /// surfaces to the caller rather than being swallowed.
    public func upgradeVoipToVideo(
        partnerUid: Int64,
        callId: Int32,
        codec: String = ZolaCrypto.defaultVoipCodecJson,
        dryRun: Bool = false
    ) async throws {
        try assertSessionAlive()
        let srcId = Int32(truncatingIfNeeded: session.uid)
        let partnerId = Int32(truncatingIfNeeded: partnerUid)
        guard !dryRun else { return }

        #if canImport(Network)
        guard let sock = activeVoipSocket else {
            throw ZolaError.transport("Không có phiên VoIP đang hoạt động để nâng cấp cuộc gọi lên video")
        }
        let ctx = await sock.callContext(forCallId: callId)
        let seq = await sock.nextSeqId()
        let frame = Self.buildVoipVideoUpgradeFrame(
            srcId: srcId,
            partnerId: partnerId,
            callId: callId,
            codec: codec,
            baseExtendData: ownVoipExtendDataByCallId[callId],
            rtpAddress: ctx?.rtpAddress ?? "49.213.95.89:10000",
            rtcpAddress: ctx?.rtcpAddress ?? "49.213.95.89:10001",
            sessionId: (ctx?.sessionId).flatMap { $0.isEmpty ? nil : $0 } ?? String(callId),
            seqId: seq
        )
        try await sock.sendFrame(frame)
        await sock.markCallVideo()
        #else
        throw ZolaError.transport("Nền tảng không hỗ trợ socket VoIP để nâng cấp lên video")
        #endif
    }

    /// `true` when the active `0x7d0` VoIP call was negotiated as (or upgraded to) video. Lets the app
    /// decide whether turning the local camera on needs a voice→video upgrade (`upgradeVoipToVideo`)
    /// or is just a camera toggle on an already-video call.
    public func isActiveVoipCallVideo() async -> Bool {
        #if canImport(Network)
        guard let sock = activeVoipSocket else { return false }
        return await sock.isCallVideo()
        #else
        return false
        #endif
    }

    public func rejectVoipCall(
        partnerUid: Int64,
        callId: Int32,
        isVideo: Bool = false,
        reason: String = "",
        dryRun: Bool = false
    ) async throws {
        try assertSessionAlive()
        let srcId = Int32(truncatingIfNeeded: session.uid)
        let partnerId = Int32(truncatingIfNeeded: partnerUid)
        let rejectFrame = ZolaCrypto.packVoipAnswerCallFrame(
            srcId: srcId,
            partnerId: partnerId,
            callId: callId,
            status: 3,
            codec: "",
            paramsJson: "",
            seqId: 5
        )
        guard !dryRun else {
            _ = rejectFrame
            return
        }

        #if canImport(Network)
        let sock = try await obtainAuthenticatedVoipSocket(
            partnerUid: partnerUid,
            callId: callId,
            isVideo: isVideo
        )
        let cached = await sock.callContext(forCallId: callId)
        let resolvedSessionId = cached?.sessionId ?? ""
        let resolvedRtp = cached?.rtpAddress ?? ""
        // Callee decline (`ZrtpVoipService` `0x102f9f11c` / `0x102f9f428`): `cmd = 402, subCmd = 3, status = 3`
        // followed by `cmd = 406` finish call log (`status = 158`).
        let seq = await sock.nextSeqId()
        let liveFrame = ZolaCrypto.packVoipAnswerCallFrame(
            srcId: srcId,
            partnerId: partnerId,
            callId: callId,
            status: 3,
            sessionId: resolvedSessionId,
            rtpAddress: resolvedRtp,
            rtpServer: "",
            codec: "",
            paramsJson: "",
            seqId: seq
        )
        try? await sock.sendFrame(liveFrame)

        let logSeq = await sock.nextSeqId()
        let logFrame = ZolaCrypto.packVoipFinishCallLogFrame(
            srcId: srcId,
            partnerId: partnerId,
            callId: callId,
            status: 158,
            durationSeconds: 0,
            protocolVersion: 3,
            sendType: 2,
            paramsJson: #"{"ver":4,"net":1,"rel":1}"#,
            seqId: logSeq
        )
        try? await sock.sendFrame(logFrame)

        if voipListenerActive {
            // Background listener owns the socket: unbind the rejected call, keep `0x7d0` alive.
            await sock.unbindCall()
        } else {
            activeVoipSocket = nil
            await sock.close()
        }
        #endif
    }

    public func cancelVoipCall(
        partnerUid: Int64,
        callId: Int32,
        isVideo: Bool = false,
        durationSeconds: Int32 = 0,
        isConnected: Bool = false,
        dryRun: Bool = false,
        sendEndSignal: Bool = true
    ) async throws {
        try assertSessionAlive()
        let srcId = Int32(truncatingIfNeeded: session.uid)
        let partnerId = Int32(truncatingIfNeeded: partnerUid)
        let wasConnected = durationSeconds > 0 || isConnected
        var finishStatus: Int32 = wasConnected ? 160 : 162

        if dryRun {
            if wasConnected && sendEndSignal {
                _ = ZolaCrypto.packVoipEndCallFrame(
                    srcId: srcId,
                    partnerId: partnerId,
                    callId: callId,
                    seqId: 3
                )
            } else if sendEndSignal {
                _ = ZolaCrypto.packVoipCancelCallFrame(
                    srcId: srcId,
                    partnerId: partnerId,
                    callId: callId,
                    status: 1,
                    isVideo: isVideo,
                    seqId: 3
                )
            }
            _ = ZolaCrypto.packVoipFinishCallLogFrame(
                srcId: srcId,
                partnerId: partnerId,
                callId: callId,
                status: finishStatus,
                durationSeconds: durationSeconds,
                protocolVersion: 3,
                sendType: 1,
                paramsJson: #"{"ver":4,"net":1,"rel":1}"#,
                seqId: 6
            )
            return
        }

        #if canImport(Network)
        if !wasConnected,
           callId != 0,
           (callId == inFlightVoipClientCallId || callId == inFlightVoipServerCallId || activeVoipSocket == nil)
        {
            cancelledClientCallIds.insert(callId)
        }
        guard let sock = activeVoipSocket else {
            return
        }
        guard let finish = await sock.claimFinishLog(callId: callId, partnerUid: partnerUid) else { return }
        let shouldSendEnd = sendEndSignal && !finish.remotelyEnded
        #if canImport(AVFoundation) && canImport(AudioToolbox)
        if preparedVoipMediaEngine?.callId == callId { discardPreparedVoipMediaEngine() }
        #endif
        let finishIdentity = finish.identity
        if wasConnected, finishIdentity.receivedIncomingAnswerAcknowledgement == true {
            // Native 408 records an acknowledgement state (163), not a measured
            // media outcome. Sandbox native↔SDK testing verified that neutral
            // status0 + positive duration + callee role1 yields server calltime, whereas
            // 163 yields misscall. Use this interoperability result only for this exact
            // acknowledged incoming call; do not invent a native quality score.
            finishStatus = 0
        }
        let cached = finish.context
        let termSeq = await sock.nextSeqId()
        if wasConnected && shouldSendEnd {
            // Connected call hangup (`VoipRequestOperation` `0x102f94264` / `Zalo2` `0x102fc7fb8`): `cmd = 409, subCmd = 0`.
            let endFrame = ZolaCrypto.packVoipEndCallFrame(
                srcId: srcId,
                partnerId: partnerId,
                callId: callId,
                reasonByte: 0,
                sessionId: cached?.sessionId ?? "",
                rtpAddress: cached?.rtpAddress ?? "",
                extendData: "",
                reasonCode: 1,
                seqId: termSeq
            )
            try? await sock.sendFrame(endFrame)
        } else if !wasConnected && shouldSendEnd {
            // Unanswered outgoing cancel (`cmd = 405, subCmd = 0`).
            let cancelFrame = ZolaCrypto.packVoipCancelCallFrame(
                srcId: srcId,
                partnerId: partnerId,
                callId: callId,
                status: 1,
                isVideo: isVideo,
                seqId: termSeq
            )
            try? await sock.sendFrame(cancelFrame)
        }

        // Send a single authoritative `cmd = 406, subCmd = 3` (`protocolVersion: 3`) finish-call-log frame (`mac35`).
        // Sending a second `protocolVersion: 1` frame causes Zalo's server to insert duplicate `recommened.calltime` bubbles.
        let logV3Seq = await sock.nextSeqId()
        let logV3Frame = ZolaCrypto.packVoipFinishCallLogFrame(
            srcId: srcId,
            partnerId: partnerId,
            callId: callId,
            status: finishStatus,
            durationSeconds: durationSeconds,
            protocolVersion: 3,
            sendType: finishIdentity.sendType,
            paramsJson: #"{"ver":4,"net":1,"rel":1}"#,
            seqId: logV3Seq
        )
        try? await sock.sendFrame(logV3Frame)

        await sock.completeClaimedFinish(callId: callId, partnerUid: partnerUid)
        #endif
    }
}
