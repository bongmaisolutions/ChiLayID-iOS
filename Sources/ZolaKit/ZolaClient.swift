import Foundation
#if canImport(Network)
import Network
#endif
#if canImport(AVFoundation) && canImport(CoreGraphics) && canImport(ImageIO)
import AVFoundation
import CoreGraphics
import ImageIO
#endif

public struct ZolaFemcResponse: Sendable, Equatable {
    public let e: Int
    public let hasMore: Bool
    public let maxCliMsgId: Int64
    public let maxGlbMsgId: Int64
    public let messages: [ZolaMessage]
    internal var reactionEvents: [ZolaEvent] = []
}

public struct ZolaPreloadResponse: Sendable, Equatable {
    public let e: Int
    public let joinedGroups: [Int64: ZolaGroupCursor]
    public let messages: [ZolaMessage]
    internal var reactionEvents: [ZolaEvent] = []
}

/// `EncryptProtocolVer2` key material returned by `POST /api/helper/getKeySet?` (Mode 2 `zcid`)
/// (`StartupFlowManager getKeySetWithLoginUid:success:failure:`). `keySetValue` is secret — never log it.
public struct ZolaKeySet: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public let keySetId: String
    public let keySetValue: String
    public let aesPublicId: Int64?
    public let aesPrivateId: Int64?

    public init(keySetId: String, keySetValue: String, aesPublicId: Int64? = nil, aesPrivateId: Int64? = nil) {
        self.keySetId = keySetId
        self.keySetValue = keySetValue
        self.aesPublicId = aesPublicId
        self.aesPrivateId = aesPrivateId
    }

    public var description: String {
        let kvFp = keySetValue.isEmpty ? "none" : ZolaCrypto.sha256Hex8(Data(keySetValue.utf8))
        return "ZolaKeySet(keySetId='\(keySetId)', kv_sha256_8='\(kvFp)')"
    }

    public var debugDescription: String { description }
}

#if canImport(Network)
final class ChatSocketElementMailbox: @unchecked Sendable {
    private struct QueuedItem {
        let element: ZolaUnpackedChatElement
        weak var socket: ZolaVoipSocketSession?
    }

    static let maxCapacity = 2048

    private let lock = NSLock()
    private var buffer: [QueuedItem] = []
    private var headIndex: Int = 0
    private var hasScheduledDrain = false
    private var overflowedSinceLastDrain = false

    /// Appends in wire order under `lock` and returns `true` iff the caller must spawn a single drain `Task`.
    func push(_ element: ZolaUnpackedChatElement, socket: ZolaVoipSocketSession) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let liveCount = buffer.count - headIndex
        if liveCount < Self.maxCapacity {
            buffer.append(QueuedItem(element: element, socket: socket))
        } else {
            overflowedSinceLastDrain = true
        }
        guard !hasScheduledDrain else { return false }
        hasScheduledDrain = true
        return true
    }

    func popNextOrFinishDrain() -> (item: (element: ZolaUnpackedChatElement, socket: ZolaVoipSocketSession?)?, didOverflow: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard headIndex < buffer.count else {
            buffer.removeAll(keepingCapacity: false)
            headIndex = 0
            hasScheduledDrain = false
            let overflow = overflowedSinceLastDrain
            overflowedSinceLastDrain = false
            return (nil, overflow)
        }
        let queued = buffer[headIndex]
        headIndex += 1
        if headIndex >= 64 && headIndex * 2 >= buffer.count {
            buffer.removeFirst(headIndex)
            headIndex = 0
        }
        return ((queued.element, queued.socket), false)
    }

    func removeAll() {
        lock.lock()
        buffer.removeAll(keepingCapacity: false)
        headIndex = 0
        hasScheduledDrain = false
        overflowedSinceLastDrain = false
        lock.unlock()
    }
}
#endif

/// Thread-safe Swift `actor` implementing the complete Native Zalo iOS SDK for iOS & macOS.
public actor ZolaClient {
    private var seenGroupNotificationIDs: [String] = []
    private let groupPollReadQueue = ZolaGroupPollReadQueue()
    public internal(set) var session: ZolaSession
    public private(set) var watermarks: ZolaWatermarkState
    public let watermarkFileURL: URL?
    public let minPollIntervalSeconds: Double
    /// Set before starting the client when a paired Mac owns this account’s native socket.
    public private(set) var nativeSocketExternallyOwned: Bool
    var nativeSocketOwnershipGeneration = UUID()
    let incomingVoipPartnerAllowlist: Set<Int64>?

    internal let transport: ZolaNetworkTransport
    private var lastPollUptime: TimeInterval = 0
    internal var groupsCache: [Int64: ZolaGroup] = [:]
    internal var usersCache: [Int64: ZolaUser] = [:]
    internal var stickerMetaCache: [Int64: (cateId: Int32, stickerType: Int8)] = [:]
    internal var stickerStoreCidCache: [Int64: String] = [:]
    internal var cachedUploadConfigURL: String?
    var voipEventHandler: (@Sendable (ZolaVoipCallEvent) -> Void)?
    var realtimeEventHandler: (@Sendable (ZolaEvent) -> Void)?
    var durableRealtimeMessageHandler: (@Sendable ([ZolaEvent], Bool) async throws -> Void)?
    private var preloadRotationOffset: Int = 0
    /// Per-group latch: backward `api/cm/mfetch` paging has reached the start of the
    /// server-held history window for this gid. Set only, never cleared during a session.
    private var historyExhaustedGids: Set<Int64> = []
    var pendingKeySetRefreshId: UUID?
    var pendingKeySetRefreshTask: Task<ZolaKeySet, Error>?
    private var terminalHandoffStarted = false
    private var terminalHandoffRefreshTask: Task<ZolaKeySet, Error>?
    private var pendingSessionRequests: [UUID: Task<(Int, Data), Error>] = [:]
    internal let voipLoopbackEndpoints: [(host: String, port: UInt16)]?

    public static let legacyMissingVoipKeySetMessage =
        "Nick này đăng nhập từ bản cũ chưa có khoá gọi thoại Zalo — vui lòng đăng nhập lại nick này 1 lần trong tab Tài khoản để bật gọi."
    #if canImport(Network)
    var activeVoipSocket: ZolaVoipSocketSession?
    private var pendingOwnershipSockets: [UUID: ZolaVoipSocketSession] = [:]
    /// Our own `extendData` per call. The socket's call context stores the PEER's copy from 402/403/407,
    /// so a voice→video upgrade built from it advertised the peer's P2P candidates as ours.
    var ownVoipExtendDataByCallId: [Int32: String] = [:]
    var pendingSharedSocketTask: Task<ZolaVoipSocketSession, Error>?
    var pendingSharedSocketID: UUID?
    var sharedSocketGeneration = UUID()
    var voipListenerGeneration = UUID()
    var voipListenerTask: Task<Void, Never>?
    var voipListenerActive = false
    var lastDrainedSocketObjectId: ObjectIdentifier?
    private var socketOfflineSinglePagesDrained: Int = 0
    private var socketOfflineGroupPagesDrained: Int = 0
    var pendingCloudWakeupTask: Task<Void, Never>?
    let chatSocketMailbox = ChatSocketElementMailbox()
    var isDrainingChatSocketElements = false
    var cancelledClientCallIds: Set<Int32> = []
    var inFlightVoipClientCallId: Int32 = 0
    var inFlightVoipServerCallId: Int32 = 0
    #endif
    #if canImport(Network) && canImport(AVFoundation) && canImport(AudioToolbox)
    var preparedVoipMediaEngine: ZolaVoipMediaEngine?
    #endif

    public init(
        session: ZolaSession,
        watermarks: ZolaWatermarkState? = nil,
        watermarkFileURL: URL? = nil,
        transport: ZolaNetworkTransport? = nil,
        minPollIntervalSeconds: Double = ZolaConstants.minPollIntervalSeconds,
        voipLoopbackEndpoints: [(host: String, port: UInt16)]? = nil,
        nativeSocketExternallyOwned: Bool = false,
        incomingVoipPartnerAllowlist: Set<Int64>? = nil
    ) {
        var normalizedSession = session
        normalizedSession.friendHost = ZolaSession.normalizeFriendHost(session.friendHost)
        self.session = normalizedSession
        if let watermarks {
            self.watermarks = watermarks
        } else if let url = watermarkFileURL, let loaded = try? ZolaFileSessionStore.loadWatermark(from: url) {
            self.watermarks = loaded
        } else {
            self.watermarks = ZolaWatermarkState()
        }
        self.watermarks.registerGroups(session.groupIds)
        if session.sendToMeId > 0 {
            self.watermarks.registerSingles([session.sendToMeId])
        }
        self.watermarkFileURL = watermarkFileURL
        self.transport = transport ?? ZolaURLSessionTransport()
        self.minPollIntervalSeconds = max(minPollIntervalSeconds, 0)
        self.voipLoopbackEndpoints = voipLoopbackEndpoints
        self.nativeSocketExternallyOwned = nativeSocketExternallyOwned
        self.incomingVoipPartnerAllowlist = incomingVoipPartnerAllowlist
    }

    /// Revoke local socket ownership before a paired test service starts its listener.
    /// HTTP APIs remain available. Callers must await this before enabling the external owner.
    public func setNativeSocketExternallyOwned(_ owned: Bool) async {
        guard owned != nativeSocketExternallyOwned else { return }
        nativeSocketExternallyOwned = owned
        nativeSocketOwnershipGeneration = UUID()
        guard owned else { return }
        await revokePendingAndActiveNativeSockets()
    }

    private func revokePendingAndActiveNativeSockets() async {
        #if canImport(Network)
        let pending = Array(pendingOwnershipSockets.values)
        let openingSharedSocket = pendingSharedSocketTask
        pendingOwnershipSockets.removeAll()
        for socket in pending { await socket.revokeLocalOwnership() }
        await stopVoipIncomingListener()
        // A connect can finish between the tracked authentication and its publication as active.
        // Await/close that completed result before promising the external owner exclusivity.
        if let openingSharedSocket, case let .success(socket) = await openingSharedSocket.result {
            await socket.revokeLocalOwnership()
        }
        #endif
    }

    /// Terminal handoff for a quiesced client. Refuses active native calls, fences opens/reconnects,
    /// then waits for an already-running key refresh before returning the final session snapshot.
    /// The owner must persist this snapshot before acknowledging transfer, then discard this client.
    public func prepareNativeSocketHandoffSession() async throws -> ZolaSession {
        try assertSessionAlive()
        let previousOwnerFlag = nativeSocketExternallyOwned
        let previousHandoffStarted = terminalHandoffStarted
        if !terminalHandoffStarted {
            terminalHandoffRefreshTask = pendingKeySetRefreshTask
        }
        terminalHandoffStarted = true
        nativeSocketExternallyOwned = true
        nativeSocketOwnershipGeneration = UUID()
        #if canImport(Network)
        if let socket = activeVoipSocket, !(await socket.revokeLocalOwnershipIfIdle()) {
            nativeSocketExternallyOwned = previousOwnerFlag
            terminalHandoffStarted = previousHandoffStarted
            if !previousHandoffStarted { terminalHandoffRefreshTask = nil }
            nativeSocketOwnershipGeneration = UUID()
            throw ZolaError.safetyGate("Đang có cuộc gọi, chưa thể chuyển quyền kết nối.")
        }
        #endif
        let requests = Array(pendingSessionRequests.values)
        requests.forEach { $0.cancel() }
        await revokePendingAndActiveNativeSockets()
        for request in requests { _ = await request.result }
        if let refresh = terminalHandoffRefreshTask { _ = try await refresh.value }
        try assertSessionAlive()
        return session
    }

    /// Only terminal ownership transfer fences HTTP. Ordinary external socket ownership keeps
    /// existing HTTP APIs available. Late/cancelled results cannot reach envelope/session parsing.
    internal func executeSessionRequest(
        _ request: URLRequest, completingKeyRefresh: Bool = false
    ) async throws -> (Int, Data) {
        if terminalHandoffStarted && !completingKeyRefresh {
            throw ZolaError.safetyGate("Phiên này đã bàn giao, cần sử dụng phiên mới.")
        }
        if completingKeyRefresh {
            return try await transport.execute(request)
        }
        let id = UUID()
        let transport = self.transport
        let task = Task { try await transport.execute(request) }
        pendingSessionRequests[id] = task
        defer { pendingSessionRequests[id] = nil }
        return try await withTaskCancellationHandler {
            let result = try await task.value
            try Task.checkCancellation()
            guard !terminalHandoffStarted else {
                throw ZolaError.safetyGate("Đã bỏ phản hồi từ phiên cũ sau khi bàn giao.")
            }
            return result
        } onCancel: { task.cancel() }
    }

    /// Recheck the captured owner epoch after any suspension (notably a rejected -67 socket close).
    func refreshKeySetForNativeSocket(generation: UUID) async throws -> ZolaKeySet {
        try assertNativeSocketLocallyOwned(generation: generation)
        let result: ZolaKeySet
        do {
            result = try await fetchKeySet()
        } catch {
            // The server rejected the current socket keySet and this session has no login token to
            // fetch a new one: every further socket attempt would be dropped the same way. Stop
            // opening sockets for this client (HTTP polling keeps delivering messages) until re-login.
            if !session.canRefreshKeySet { nativeSocketKeySetRejected = true }
            throw error
        }
        try assertNativeSocketLocallyOwned(generation: generation)
        return result
    }

    /// Set once the server rejected the socket keySet and it cannot be refreshed (no login token).
    private var nativeSocketKeySetRejected = false

    public static let socketKeySetRejectedMessage =
        "Kết nối nhận tin tức thì của nick này đã hết hạn trên máy này và không tự làm mới được. "
        + "Tin nhắn vẫn được cập nhật định kỳ; đăng nhập lại nick bằng số điện thoại để nhận tin tức thì."

    /// `internal` (not `private`): `Call/ZolaClient+VoipCall.swift` (`openVoipSocket`) checks it too.
    internal func assertSocketKeySetUsable() throws {
        if nativeSocketKeySetRejected && !session.canRefreshKeySet {
            throw ZolaError.safetyGate(Self.socketKeySetRejectedMessage)
        }
    }

    internal func assertNativeSocketLocallyOwned(generation: UUID? = nil) throws {
        guard !terminalHandoffStarted, !nativeSocketExternallyOwned else {
            throw ZolaError.safetyGate("Native socket của nick này đang do dịch vụ cuộc gọi quản lý.")
        }
        if let generation, generation != nativeSocketOwnershipGeneration { throw CancellationError() }
    }

    #if canImport(Network)
    /// Track authentication in progress so transferring ownership also closes a pending connection.
    func connectLocallyOwnedSocket(
        _ socket: ZolaVoipSocketSession, generation: UUID, timeout: Double = 3.5
    ) async throws {
        try assertNativeSocketLocallyOwned(generation: generation)
        let id = UUID()
        pendingOwnershipSockets[id] = socket
        defer { pendingOwnershipSockets[id] = nil }
        do {
            try await socket.connectAndAuthenticate(perHostTimeout: timeout)
            try assertNativeSocketLocallyOwned(generation: generation)
        } catch {
            await socket.close()
            throw error
        }
    }
    #endif

    public func registerSingleThread(uid: Int64) {
        guard uid > 0, uid != session.uid, !knownGroupIds().contains(uid) else { return }
        watermarks.registerSingles([uid])
        if let url = watermarkFileURL {
            try? ZolaFileSessionStore.saveWatermark(watermarks, to: url)
        }
    }

    public func clearExpiredState() {
        session.expiredCode = nil
        session.expiredReason = nil
    }

    internal func assertSessionAlive() throws {
        if session.isExpired {
            throw ZolaError.sessionExpired(
                code: session.expiredCode ?? ZolaConstants.errorSessionExpired,
                endpoint: "circuit_breaker",
                message: session.expiredReason ?? "Session already marked expired"
            )
        }
    }

    internal func knownGroupIds() -> Set<Int64> {
        Set(session.groupIds).union(groupsCache.keys).union(watermarks.groupCursors.keys)
    }

    private func harvestGroup(_ group: ZolaGroup) {
        groupsCache[group.gid] = group
        watermarks.registerGroups([group.gid])
        if !session.groupIds.contains(group.gid) {
            session.groupIds.append(group.gid)
        }
        for m in group.members where m.uid > 0 {
            if m.uid != session.uid, watermarks.singleCursors.count < 60 {
                watermarks.registerSingles([m.uid])
            }
            if let existing = usersCache[m.uid], !existing.avatarUrl.isEmpty, m.avatarUrl.isEmpty {
                continue
            }
            usersCache[m.uid] = m
        }
    }

    private func harvestSender(_ msg: ZolaMessage) {
        if msg.senderId > 0, !msg.senderName.isEmpty, usersCache[msg.senderId] == nil {
            usersCache[msg.senderId] = ZolaUser(uid: msg.senderId, displayName: msg.senderName)
        }
        if !msg.isGroup {
            let peerUid = msg.isSelf ? msg.toId : msg.senderId
            if peerUid > 0, peerUid != session.uid {
                watermarks.registerSingles([peerUid])
            }
        }
    }

    private var reactionSnapshots: [String: [String]] = [:]

    /// Delivery deduplication must not suppress changed authoritative reaction metadata.
    internal func messageEvent(_ message: ZolaMessage, isUnseen: Bool, nowMs: Int64) -> ZolaEvent? {
        let key = Self.dedupeKey(for: message)
        var reactionChanged = false
        if message.hasReactionSnapshot {
            let canonical = message.reactions.sorted()
            reactionChanged = reactionSnapshots[key] != canonical
            if reactionSnapshots.count >= 20_000, reactionSnapshots[key] == nil { reactionSnapshots.removeAll(keepingCapacity: true) }
            reactionSnapshots[key] = canonical
        }
        guard isUnseen || reactionChanged else { return nil }
        return ZolaEvent(type: isUnseen ? "message.new" : "message.updated",
                         tsMs: message.tsMs > 0 ? message.tsMs : nowMs, message: message)
    }

    private func nativeReactionEvents(_ raw: [String: Any], knownGroupIds: Set<Int64>) -> [ZolaEvent] {
        let updates = ZolaReactionUpdate.fromRawItem(raw, selfUid: session.uid, knownGroupIds: knownGroupIds)
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        return updates.map { ZolaEvent(type: "message.reaction", tsMs: nowMs, reaction: $0) }
    }

    private static func dedupeKey(for msg: ZolaMessage) -> String {
        "\(msg.isGroup ? "g" : "u"):\(msg.threadId):\(msg.id):\(msg.cliMsgId):\(msg.senderId)"
    }

    /// Returns `true` only when `msg.id` came from a server `globalMsgId` rather than `fromRawItem`
    /// falling back to `cliMsgId` or `tsMs` (`1.7e12` ms timestamps must never pollute `glbMsgId` cursors).
    private static func hasRealServerGlobalId(_ msg: ZolaMessage) -> Bool {
        msg.hasRealServerGlobalId
    }

    /// Selects up to `maxCount` 1-1 peer UIDs without starving contacts beyond the first 60 sorted UIDs:
    /// pins explicit `pinnedUids` first, then keeps recently active threads (highest `glbMsgId > 1`),
    /// and rotates across the remaining registered contacts in deterministic round-robin slices.
    private func selectPreloadSingleUids(
        from sCursors: [Int64: Int64],
        fallbackPool: [Int64] = [],
        pinnedUids: [Int64] = [],
        maxCount: Int = 60
    ) -> [Int64] {
        let gids = knownGroupIds()
        func isValidSingle(_ uid: Int64) -> Bool {
            uid > 0 && uid != session.uid && !gids.contains(uid)
        }

        var allSet: Set<Int64> = []
        for uid in pinnedUids where isValidSingle(uid) { allSet.insert(uid) }
        for uid in sCursors.keys where isValidSingle(uid) { allSet.insert(uid) }
        for uid in fallbackPool where isValidSingle(uid) { allSet.insert(uid) }

        if allSet.count <= maxCount {
            return allSet.sorted()
        }

        var selected: [Int64] = []
        var selectedSet: Set<Int64> = []
        func appendUnique(_ uid: Int64) {
            guard selected.count < maxCount, isValidSingle(uid), selectedSet.insert(uid).inserted else { return }
            selected.append(uid)
        }

        // Reserve at least `minRotationReserve` slots whenever total peers exceed `maxCount`,
        // so a large `pinnedUids` list (e.g., Cloud + >=59 FEMC peers) can never starve round-robin rotation.
        let minRotationReserve = max(1, min(15, maxCount / 4))
        let pinnedCap = max(1, maxCount - minRotationReserve * 2)
        if session.sendToMeId > 0 && pinnedUids.contains(session.sendToMeId) {
            appendUnique(session.sendToMeId)
        }
        for uid in pinnedUids {
            if selected.count >= pinnedCap { break }
            appendUnique(uid)
        }
        let activeSorted = allSet
            .filter { !selectedSet.contains($0) && (sCursors[$0] ?? 1) > 1 }
            .sorted { lhs, rhs in
                let lg = sCursors[lhs] ?? 1
                let rg = sCursors[rhs] ?? 1
                return lg != rg ? lg > rg : lhs < rhs
            }
        let maxBeforeRotation = max(1, maxCount - minRotationReserve)
        let activeQuota = min(activeSorted.count, max(0, min(20, maxBeforeRotation - selected.count)))
        for uid in activeSorted.prefix(activeQuota) {
            appendUnique(uid)
        }

        let remainingTail = allSet.filter { !selectedSet.contains($0) }.sorted()
        let slotsLeft = maxCount - selected.count
        if slotsLeft > 0, !remainingTail.isEmpty {
            let start = preloadRotationOffset % remainingTail.count
            let takeCount = min(slotsLeft, remainingTail.count)
            for offset in 0..<takeCount {
                let idx = (start + offset) % remainingTail.count
                appendUnique(remainingTail[idx])
            }
            preloadRotationOffset = (start + takeCount) % remainingTail.count
        }
        return selected
    }

    // MARK: - 1. Directory, Groups & User Profiles

    public func listJoinedGroups(
        page: Int = 1,
        lastGroupId: Int64 = 0,
        avatarSize: Int = 120,
        publicKey: Int64? = nil
    ) async throws -> [ZolaGroup] {
        try assertSessionAlive()
        let pubKey = publicKey ?? Int64.random(in: 100_000_000...999_999_999)
        let req = try ZolaRequestBuilder.buildPlaintextSignedGET(
            baseURL: "\(session.groupApiHost)/group/list?",
            params: [
                "publicKey": String(pubKey),
                "avatar_size": String(avatarSize),
                "page": String(page),
                "last_group_id": String(lastGroupId),
                "tip": "0",
                "reddot": "0",
            ],
            session: session
        )
        let (_, raw) = try await executeSessionRequest(req)
        let env = try ZolaRequestBuilder.parseEnvelope(
            raw,
            session: &session,
            endpoint: "group/list",
            noisedPublicKey: pubKey
        )
        let data = env["data"] as? [String: Any] ?? [:]
        let rawList = (data["data"] ?? data["groups"] ?? data["list"] ?? data["groupList"] ?? env["data"]) as? [[String: Any]] ?? []
        var groups: [ZolaGroup] = []
        for item in rawList {
            let grp = ZolaGroup.fromServerDict(item)
            if grp.gid > 0 {
                harvestGroup(grp)
                groups.append(grp)
            }
        }
        return groups
    }

    public func getGroupInfo(
        gid: Int64,
        avatarSize: Int = 120,
        filterType: Int = 0,
        checkStatus: Int = 0,
        publicKey: Int64? = nil
    ) async throws -> ZolaGroup {
        try assertSessionAlive()
        guard gid > 0 else { throw ZolaError.invalidArgument("Invalid gid \(gid)") }
        let pubKey = publicKey ?? Int64.random(in: 100_000_000...999_999_999)
        let req = try ZolaRequestBuilder.buildPlaintextSignedGET(
            baseURL: "\(session.groupApiHost)/group/info?",
            params: [
                "group_id": String(gid),
                "publicKey": String(pubKey),
                "avatar_size": String(avatarSize),
                "filterType": String(filterType),
                "checkStatus": String(checkStatus),
            ],
            session: session
        )
        let (_, raw) = try await executeSessionRequest(req)
        let env = try ZolaRequestBuilder.parseEnvelope(
            raw,
            session: &session,
            endpoint: "group/info",
            noisedPublicKey: pubKey,
            noisedGid: gid
        )
        let data = env["data"] as? [String: Any] ?? [:]
        let grpDict = (data["group"] as? [String: Any]) ?? data
        let grp = ZolaGroup.fromServerDict(grpDict)
        if grp.gid > 0 { harvestGroup(grp) }
        return grp
    }

    public func getUserProfile(
        uid targetUid: Int64,
        avatarSize: Int = 120,
        fromProfilePage: Bool = false
    ) async throws -> ZolaUser {
        try assertSessionAlive()
        guard targetUid > 0 else { throw ZolaError.invalidArgument("Invalid uid \(targetUid)") }
        var params: [String: String] = [
            "id": String(targetUid),
            "avatarSize": String(avatarSize),
            "method": "getProfile",
        ]
        if fromProfilePage { params["fromProfilePage"] = "1" }
        let req = try ZolaRequestBuilder.buildPlaintextSignedGET(
            baseURL: "\(session.tapiHost)/api/contact/getProfile?",
            params: params,
            session: session
        )
        let (_, raw) = try await executeSessionRequest(req)
        let env = try ZolaRequestBuilder.parseEnvelope(raw, session: &session, endpoint: "api/contact/getProfile")
        let data = env["data"] as? [String: Any] ?? [:]
        var profDict = (data["profile"] as? [String: Any]) ?? data
        Self.noteProfileShape(profDict)
        if profDict["userId"] == nil && profDict["id"] == nil {
            profDict["userId"] = targetUid
        }
        let user = ZolaUser.fromServerDict(profDict)
        if user.uid > 0, !user.isLockedAccount {
            usersCache[user.uid] = user
        }
        return user
    }

    /// Generic sanitized diagnostics sink (key names / codes / counts only — never values or ids).
    nonisolated(unsafe) public static var diagnosticHandler: (@Sendable (String) -> Void)?
    nonisolated(unsafe) private static var profileShapeNotes = 0

    /// Records which fields a native `getProfile` response carries (names only) for the first few
    /// calls, so profile-page fields (cover / bio / birthday) are mapped from evidence, not guesses.
    private static func noteProfileShape(_ dict: [String: Any]) {
        guard let handler = diagnosticHandler, profileShapeNotes < 3 else { return }
        profileShapeNotes += 1
        func has(_ key: String) -> Int { ZolaJSON.string(dict[key]).isEmpty ? 0 : 1 }
        handler("profile keys=\(dict.keys.sorted().joined(separator: ",")) bgavatar=\(has("bgavatar")) cover=\(has("cover")) status=\(has("status")) sdob=\(has("sdob")) dob=\(has("dob"))")
    }

    /// `api/friend/profile/get` answers 216 when no Zalo account is registered (or searchable) for the phone.
    static let phoneNotFoundCode = 216
    /// `api/friend/requested/list` answers 112 when there is no sent request.
    static let noSentRequestsCode = 112
    /// `api/friend/sendreq`: 222 = they already invited you (sending accepts it), 225 = already friends.
    static let sendReqAcceptedCode = 222
    static let sendReqAlreadyFriendsCode = 225

    /// `0901234567` / `901234567` / `+84 901…` → `84901234567` (format `api/friend/profile/get` expects).
    static func internationalPhone(_ raw: String, countryCode: String = "84") -> String {
        let cc = countryCode.filter(\.isNumber)
        let digits = raw.filter(\.isNumber)
        if raw.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("+") { return digits }
        if digits.hasPrefix("0") { return cc + digits.dropFirst() }
        if !cc.isEmpty, digits.hasPrefix(cc), digits.count >= cc.count + 9 { return digits }
        return cc + digits
    }

    /// One friend-service (`friendHost`) call on a registered session; returns `error_code` and the decrypted `data`.
    /// Any non-zero code not in `allowedCodes` throws `.server` — including 102/-96, which are reported but do NOT
    /// latch the session: these are one-shot user actions, and a friend-host refusal must not log a live nick out.
    internal func friendServiceCall(
        _ path: String,
        params: [String: Any],
        method: String,
        allowedCodes: Set<Int> = []
    ) async throws -> (code: Int, data: [String: Any]) {
        try assertSessionAlive()
        guard session.zcidIsNative else {
            throw ZolaError.safetyGate(
                "Nick này được nạp từ máy tính nên chưa dùng được chức năng bạn bè. Hãy đăng nhập trực tiếp nick này bằng đăng nhập native (ZolaLoginClient)."
            )
        }
        var inner = params
        if inner["imei"] == nil {
            inner["imei"] = ZolaCrypto.extractZCIDIdentity(zcid: session.zcid).imei
        }
        let endpoint = "api/friend/\(path)"
        let friendBase = ZolaSession.normalizeFriendHost(
            resolvedServiceBaseURL(session.friendHost, serviceKey: "friend")
        )
        let req = try ZolaRequestBuilder.buildEncryptedRequest(
            url: "\(friendBase)/\(endpoint)",
            innerParams: inner,
            session: session,
            method: method
        )
        let (status, raw) = try await executeSessionRequest(req)
        let body = ZolaRequestBuilder.gunzipDecompress(raw) ?? raw
        guard let env = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
            // The native friend host only serves `loginfriend`; unsupported web paths answer an nginx 404 or HTML error page.
            if status == 404 || Self.isHTMLErrorBody(body) {
                throw ZolaError.safetyGate("Máy chủ Zalo cho app iOS không có chức năng này (\(endpoint)).")
            }
            throw ZolaError.transport("Non-JSON response on \(endpoint) (HTTP \(status))")
        }
        var code = env["error_code"] != nil ? ZolaJSON.int(env["error_code"]) : 0
        var message = ZolaJSON.string(env["error_message"] ?? env["errMessage"])
        var data: [String: Any] = [:]
        if code == 0 {
            if let hex = env["data"] as? String, !hex.isEmpty {
                let decrypted = try ZolaCrypto.decryptZCIDAny(hex, zcid: session.zcid)
                if let dict = decrypted as? [String: Any] {
                    data = dict
                } else if let arr = decrypted as? [Any] {
                    data = ["items": arr]
                }
            } else if let dict = env["data"] as? [String: Any] {
                data = dict
            } else if let arr = env["data"] as? [Any] {
                data = ["items": arr]
            }
            // Some friend endpoints wrap a second {error_code, data} envelope inside the encrypted payload.
            if data["error_code"] != nil, data.count <= 3 {
                code = ZolaJSON.int(data["error_code"])
                message = ZolaJSON.string(data["error_message"] ?? data["errMessage"])
                data = data["data"] as? [String: Any] ?? [:]
            }
        }
        if code != 0 && !allowedCodes.contains(code) {
            throw ZolaError.server(code: code, message: message)
        }
        return (code, data)
    }

    /// Finds the Zalo account registered to a phone number via `api/friend/profile/get`
    /// or native iOS contact discovery (`api/contact/discoverContact?` / `submitContact?` + `getProfile?`).
    public func findUserByPhone(_ rawPhone: String, countryCode: String = "84") async throws -> ZolaPhoneLookupResult {
        try assertSessionAlive()
        let phone = Self.internationalPhone(rawPhone, countryCode: countryCode)
        guard phone.count >= 8 else {
            throw ZolaError.invalidArgument("Số điện thoại không hợp lệ.")
        }
        let typedPhone: String = {
            let cc = countryCode.filter(\.isNumber)
            if cc == "84", phone.hasPrefix("84") { return "0" + phone.dropFirst(2) }
            return "+" + phone
        }()

        // 1. Check cached contacts first by 9-digit national suffix
        let suffix9 = String(phone.suffix(9))
        if suffix9.count >= 8,
           let cached = usersCache.values.first(where: { user in
               let digits = user.phone.filter(\.isNumber)
               return digits.count >= 8 && String(digits.suffix(9)) == suffix9 && user.uid > 0 && !user.isLockedAccount
           }) {
            return .found(
                ZolaUser(
                    uid: cached.uid,
                    displayName: cached.displayName,
                    zaloName: cached.zaloName,
                    avatarUrl: cached.avatarUrl,
                    fullAvatarUrl: cached.fullAvatarUrl,
                    phone: cached.phone.isEmpty ? typedPhone : cached.phone,
                    gender: cached.gender,
                    statusText: cached.statusText,
                    globalId: cached.globalId,
                    isFriend: cached.isFriend
                )
            )
        }

        // 2. Try friend service profile/get when native zcid is available
        if session.zcidIsNative {
            do {
                let data = try await friendServiceCall(
                    "profile/get",
                    params: [
                        "phone": phone,
                        "avatar_size": 240,
                        "language": "vi",
                        "reqSrc": 40,
                    ],
                    method: "GET"
                ).data
                let profDict = (data["profile"] as? [String: Any]) ?? data
                let user = ZolaUser.fromServerDict(profDict)
                if user.uid > 0, !user.isLockedAccount {
                    let resolved = ZolaUser(
                        uid: user.uid,
                        displayName: user.displayName,
                        zaloName: user.zaloName,
                        avatarUrl: user.avatarUrl,
                        fullAvatarUrl: user.fullAvatarUrl,
                        phone: user.phone.isEmpty ? typedPhone : user.phone,
                        gender: user.gender,
                        statusText: user.statusText,
                        globalId: user.globalId,
                        isFriend: user.isFriend
                    )
                    usersCache[resolved.uid] = resolved
                    return .found(resolved)
                }
                return .notFound
            } catch let ZolaError.server(code, message) {
                if code == Self.phoneNotFoundCode {
                    return .notFound
                }
                // If friend.api.zaloapp.com returned a real server refusal, report it unless it's unmocked (-1)
                if code != -1 {
                    return .failed(code: code, message: message)
                }
            } catch ZolaError.safetyGate, ZolaError.transport {
                // Fall through to native iOS Mode 1 contact discovery on tapi.api.zaloapp.com
            }
        }

        // 3. Native iOS Mode 1 phone discovery (`api/contact/discoverContact?` -> `submitContact?` -> `getProfile?`)
        if let discoveredUid = try await discoverUidByPhoneOnTapi(phone: phone, typedPhone: typedPhone),
           discoveredUid > 0 {
            let prof = try await getUserProfile(uid: discoveredUid, avatarSize: 240, fromProfilePage: true)
            guard prof.uid > 0, !prof.isLockedAccount else { return .notFound }
            let resolved = ZolaUser(
                uid: prof.uid,
                displayName: prof.displayName,
                zaloName: prof.zaloName,
                avatarUrl: prof.avatarUrl,
                fullAvatarUrl: prof.fullAvatarUrl,
                phone: prof.phone.isEmpty ? typedPhone : prof.phone,
                gender: prof.gender,
                statusText: prof.statusText,
                globalId: prof.globalId,
                isFriend: prof.isFriend
            )
            usersCache[resolved.uid] = resolved
            return .found(resolved)
        }

        if !session.zcidIsNative {
            throw ZolaError.safetyGate(
                "Refusing api/friend/profile/get without a registered session zcid. Sign in natively (ZolaLoginClient) first."
            )
        }
        return .notFound
    }

    /// Resolves a phone number to a Zalo UID via native iOS `tapi.api.zaloapp.com/api/contact/discoverContact?`
    /// and `submitContact?` / `submitPhones?` endpoints.
    private func discoverUidByPhoneOnTapi(phone: String, typedPhone: String) async throws -> Int64? {
        let phoneVariants = Array(Set([typedPhone, phone, "+" + phone])).sorted()
        let ts = String(Int64(Date().timeIntervalSince1970))

        // Step A: POST /api/contact/discoverContact?
        let discoverPayload: [String: Any] = ["data": phoneVariants]
        if let jsonData = try? JSONSerialization.data(withJSONObject: discoverPayload),
           let gzData = ZolaRequestBuilder.gzipCompress(jsonData) {
            let checksum = ZolaCrypto.md5Hex(jsonData)
            if let req = try? ZolaRequestBuilder.buildPlaintextSignedMultipartPOST(
                baseURL: "\(session.tapiHost)/api/contact/discoverContact?",
                params: [
                    "c": "2",
                    "check_sum": checksum,
                    "phone_book_timestamp": ts,
                    "source_type": "1",
                    "flag": "all",
                ],
                fileFieldName: "file",
                fileName: "file",
                fileData: gzData,
                session: session
            ),
            let (_, raw) = try? await executeSessionRequest(req),
            let env = ZolaRequestBuilder.parseEnvelopeNonLatching(raw, session: session) {
                let code = ZolaJSON.int(env["error_code"])
                if code == -1 && !session.zcidIsNative {
                    // Unmocked transport in synthetic-zcid unit test
                    return nil
                }
                if code == 0, let uid = Self.extractUidFromContactDiscoveryData(env["data"], phoneVariants: phoneVariants) {
                    return uid
                }
            }
        }

        // Step B: POST /api/contact/submitContact? and /api/contact/submitPhones?
        let updateItems = phoneVariants.map { ["n": "Zalo \($0)", "p": $0] }
        let submitPayload: [String: Any] = ["update": updateItems, "delete": [] as [Any]]
        if let jsonData = try? JSONSerialization.data(withJSONObject: submitPayload),
           let gzData = ZolaRequestBuilder.gzipCompress(jsonData) {
            let checksum = ZolaCrypto.md5Hex(jsonData)
            for endpoint in ["submitContact?", "submitPhones?"] {
                if let req = try? ZolaRequestBuilder.buildPlaintextSignedMultipartPOST(
                    baseURL: "\(session.tapiHost)/api/contact/\(endpoint)",
                    params: [
                        "c": "2",
                        "check_sum": checksum,
                        "phone_book_timestamp": ts,
                        "source_type": "1",
                        "flag": "all",
                    ],
                    fileFieldName: "file",
                    fileName: "file",
                    fileData: gzData,
                    session: session
                ),
                let (_, raw) = try? await executeSessionRequest(req),
                let env = ZolaRequestBuilder.parseEnvelopeNonLatching(raw, session: session),
                ZolaJSON.int(env["error_code"]) == 0,
                let uid = Self.extractUidFromContactDiscoveryData(env["data"], phoneVariants: phoneVariants) {
                    return uid
                }
            }
        }

        return nil
    }

    private static func extractUidFromContactDiscoveryData(_ rawData: Any?, phoneVariants: [String]) -> Int64? {
        guard let dataDict = rawData as? [String: Any] else { return nil }
        let rawList = dataDict["list"] ?? dataDict["contacts"] ?? dataDict["data"]
        if let arr = rawList as? [[String: Any]] {
            for item in arr {
                let uid = ZolaJSON.int64(item["uid"] ?? item["userId"] ?? item["zalo_id"] ?? item["id"])
                if uid > 0 { return uid }
            }
        } else if let str = rawList as? String, !str.isEmpty,
                  let innerData = str.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: innerData) {
            if let map = parsed as? [String: Any] {
                for variant in phoneVariants {
                    let uid = ZolaJSON.int64(map[variant])
                    if uid > 0 { return uid }
                }
                for (_, val) in map {
                    if let dict = val as? [String: Any] {
                        let uid = ZolaJSON.int64(dict["uid"] ?? dict["userId"] ?? dict["id"])
                        if uid > 0 { return uid }
                    } else {
                        let uid = ZolaJSON.int64(val)
                        if uid > 0 { return uid }
                    }
                }
            } else if let arr = parsed as? [[String: Any]] {
                for item in arr {
                    let uid = ZolaJSON.int64(item["uid"] ?? item["userId"] ?? item["zalo_id"] ?? item["id"])
                    if uid > 0 { return uid }
                }
            }
        } else if let map = rawList as? [String: Any] {
            for (_, val) in map {
                let uid = ZolaJSON.int64(val)
                if uid > 0 { return uid }
            }
        }
        return nil
    }

    // MARK: - 1B. Friend Requests (`Lời mời kết bạn` & `Gợi ý kết bạn`)

    /// True when the active session has `UXChatSocket` (`0x7d0`) endpoints (real Zalo iOS sessions or loopback socket tests).
    internal var hasChatSocketEndpoints: Bool {
        #if canImport(Network)
        if !session.encryptedSocketEndpoints.isEmpty { return true }
        if let safe = voipLoopbackEndpoints, !safe.isEmpty { return true }
        return false
        #else
        return false
        #endif
    }

    #if canImport(Network)
    /// Multiplexes `UXChatSocket` (`0x7d0`) commands onto the active/shared persistent socket when
    /// available (matching Zalo iOS `UXChatSocket`, where opening a second `0x7d0` connection for
    /// the same UID causes Zalo's server to `TCP FIN`-kick the existing call/listener socket),
    /// falling back to a short-lived socket only when no listener or call socket is active.
    internal func withAuthenticatedChatSocket<T>(
        timeoutPerHost: Double = 3.5,
        _ body: (ZolaVoipSocketSession) async throws -> T
    ) async throws -> T {
        try assertSessionAlive()
        try assertNativeSocketLocallyOwned()
        let ownershipGeneration = nativeSocketOwnershipGeneration
        guard session.zcidIsNative else {
            throw ZolaError.safetyGate(
                "Nick này chưa có khoá zcid gốc của iOS Native. Hãy đăng nhập trực tiếp nick này bằng đăng nhập native (ZolaLoginClient)."
            )
        }
        try assertSocketKeySetUsable()
        guard !session.sessionKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ZolaError.invalidArgument("Thiếu sessionKey để kết nối UXChatSocket Zalo")
        }

        if let existing = activeVoipSocket, await existing.isSocketAlive() {
            try assertNativeSocketLocallyOwned(generation: ownershipGeneration)
            return try await body(existing)
        }
        if voipListenerActive || pendingSharedSocketTask != nil {
            let shared = try await ensureSharedVoipSocket(
                heartbeatIntervalSeconds: 20.0,
                keepAliveAfterCallEnd: true
            )
            try assertNativeSocketLocallyOwned(generation: ownershipGeneration)
            return try await body(shared)
        }

        let srcId = Int32(truncatingIfNeeded: session.uid)
        // Same merged endpoint list as VoIP: session `socketServers` + the two live-verified
        // `defaultVerifiedEncryptedEndpoints`, so legacy sessions saved before `socketServers`
        // existed still satisfy the `EncryptProtocolVer2` gate (never plaintext).
        let encryptedEndpoints = resolvedLiveVoipEndpoints()

        let sock: ZolaVoipSocketSession
        if !encryptedEndpoints.isEmpty {
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
                encryptedEndpoints: encryptedEndpoints,
                socketCrypto: initialCrypto,
                onEvent: nil
            )
            do {
                try await connectLocallyOwnedSocket(candidateSock, generation: ownershipGeneration, timeout: timeoutPerHost)
            } catch let ZolaError.sessionExpired(code, ep, msg) {
                session.markExpired(code: code, reason: msg)
                throw ZolaError.sessionExpired(code: code, endpoint: ep, message: msg)
            } catch let ZolaError.server(code, _) where code == ZolaConstants.errorInvalidSessionKey {
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
                    encryptedEndpoints: encryptedEndpoints,
                    socketCrypto: refreshedCrypto,
                    onEvent: nil
                )
                do {
                    try await connectLocallyOwnedSocket(candidateSock, generation: ownershipGeneration, timeout: timeoutPerHost)
                } catch let ZolaError.sessionExpired(expCode, expEp, expMsg) {
                    session.markExpired(code: expCode, reason: expMsg)
                    throw ZolaError.sessionExpired(code: expCode, endpoint: expEp, message: expMsg)
                }
            }
            sock = candidateSock
        } else if let safeEndpoints = voipLoopbackEndpoints,
                  !safeEndpoints.isEmpty,
                  safeEndpoints.allSatisfy({ ZolaVoipProtocol.isLoopbackHost($0.host) }) {
            let loopbackSock = ZolaVoipSocketSession(
                selfUid: session.uid,
                authenPayload: makeVoipAuthenPayload(srcId: srcId),
                endpoints: safeEndpoints,
                onEvent: nil
            )
            try await connectLocallyOwnedSocket(loopbackSock, generation: ownershipGeneration, timeout: timeoutPerHost)
            sock = loopbackSock
        } else {
            throw ZolaError.safetyGate(
                "Đã khoá kết nối UXChatSocket tới máy chủ Zalo (thiếu SocketEntity.pubKey) để bảo vệ session_key."
            )
        }

        let operationSocketID = UUID()
        pendingOwnershipSockets[operationSocketID] = sock
        defer { pendingOwnershipSockets[operationSocketID] = nil }
        do {
            try assertNativeSocketLocallyOwned(generation: ownershipGeneration)
            let result = try await body(sock)
            await sock.close()
            return result
        } catch {
            await sock.close()
            throw error
        }
    }

    internal func parseChatSocketResponse(
        _ element: ZolaUnpackedChatElement,
        allowedCodes: Set<Int> = []
    ) throws -> (code: Int, data: [String: Any], message: String) {
        var code = Int(element.retCode)
        var message = ""
        var data: [String: Any] = [:]

        if !element.decodedBodyData.isEmpty,
           let parsed = try? JSONSerialization.jsonObject(with: element.decodedBodyData) {
            if let dict = parsed as? [String: Any] {
                if dict["error_code"] != nil {
                    let bodyCode = ZolaJSON.int(dict["error_code"])
                    if code == 0 || bodyCode != 0 {
                        code = bodyCode
                    }
                    message = ZolaJSON.string(dict["error_message"] ?? dict["errMessage"] ?? dict["message"])
                    if let subDict = dict["data"] as? [String: Any] {
                        data = subDict
                    } else if let subArr = dict["data"] as? [Any] {
                        data = ["items": subArr]
                    } else if let str = dict["data"] as? String, !str.isEmpty {
                        if let dec = (try? ZolaCrypto.decryptZCIDAny(str, zcid: session.zcid)) as? [String: Any] {
                            data = dec
                        } else if let jd = str.data(using: .utf8),
                                  let jDict = (try? JSONSerialization.jsonObject(with: jd)) as? [String: Any] {
                            data = jDict
                        }
                    } else {
                        data = dict
                    }
                } else {
                    data = dict
                    message = ZolaJSON.string(dict["error_message"] ?? dict["errMessage"] ?? dict["message"])
                }
            } else if let arr = parsed as? [Any] {
                data = ["items": arr]
            }
        }

        if code == 102 || code == -96 {
            let reason = message.isEmpty ? "Phiên Zalo đã hết hạn trên UXChatSocket (code=\(code))" : message
            session.markExpired(code: code, reason: reason)
            throw ZolaError.sessionExpired(code: code, endpoint: "UXChatSocket:\(element.cmd)/\(element.subCmd)", message: reason)
        }
        if code != 0 && !allowedCodes.contains(code) {
            throw ZolaError.server(code: code, message: message)
        }
        return (code, data, message)
    }
    #endif

    /// Received requests + Zalo suggestions (`cmd = 1584/2`), sent requests (`cmd = 1582/0`)
    /// and strangers who interacted (`page/getListNoneFriend`). Throws when Zalo refuses a friend-service call.
    public func fetchFriendRequests() async throws -> [ZolaFriendRequest] {
        try assertSessionAlive()
        var resultsByKey: [String: ZolaFriendRequest] = [:]
        var anyNetworkSucceeded = false
        var lastTransportError: ZolaError? = nil

        // 1. Safe Mode 1 endpoint on getpage.api.zaloapp.com & tapiHost (`/api/page/getListNoneFriend?`)
        let noneFriendHosts = Array(Set([ZolaConstants.defaultGetPageHost, session.tapiHost]))
        for host in noneFriendHosts {
            guard let req = try? ZolaRequestBuilder.buildPlaintextSignedGET(
                baseURL: "\(host)/api/page/getListNoneFriend?",
                params: [:],
                session: session
            ) else { continue }
            do {
                let (_, raw) = try await executeSessionRequest(req)
                anyNetworkSucceeded = true
                if let env = ZolaRequestBuilder.parseEnvelopeNonLatching(raw, session: session),
                   ZolaJSON.int(env["error_code"]) == 0
                {
                    let dataDict = (env["data"] as? [String: Any]) ?? [:]
                    let rawNoneFriends = Self.decodeNoneFriendsList(
                        dataDict["list_none_friends"] ?? dataDict["list"],
                        uid: session.uid,
                        declaredFrameSize: ZolaJSON.int(dataDict["frame_size"])
                    )
                    for entry in rawNoneFriends {
                        if let dict = entry as? [String: Any],
                           let fr = ZolaFriendRequest.fromServerDict(dict, accountUid: session.uid, defaultDirection: .suggestion)
                        {
                            resultsByKey[fr.id] = fr
                        } else if let uidNum = entry as? NSNumber {
                            let uid = uidNum.int64Value
                            if uid > 0, uid != session.uid {
                                let fr = ZolaFriendRequest(
                                    accountUid: session.uid,
                                    uid: uid,
                                    displayName: usersCache[uid]?.displayName ?? "UID \(uid)",
                                    avatarUrl: usersCache[uid]?.avatarUrl ?? "",
                                    sourceLabel: "Người lạ từng tương tác",
                                    direction: .suggestion
                                )
                                resultsByKey[fr.id] = fr
                            }
                        } else if let uidStr = entry as? String, let uid = Int64(uidStr), uid > 0, uid != session.uid {
                            let fr = ZolaFriendRequest(
                                accountUid: session.uid,
                                uid: uid,
                                displayName: usersCache[uid]?.displayName ?? "UID \(uid)",
                                avatarUrl: usersCache[uid]?.avatarUrl ?? "",
                                sourceLabel: "Người lạ từng tương tác",
                                direction: .suggestion
                            )
                            resultsByKey[fr.id] = fr
                        }
                    }
                }
            } catch let err as ZolaError {
                if case .transport = err { lastTransportError = err }
            } catch {
                lastTransportError = .transport(error.localizedDescription)
            }
        }

        // 2. Native `FriendRequestManager` over `UXChatSocket` (`0x7d0` `cmd=1584/2` & `cmd=396/4`),
        // falling back to `friendServiceCall` only in synthetic mock-HTTP tests without socket endpoints.
        if session.zcidIsNative {
            #if canImport(Network)
            if hasChatSocketEndpoints {
                let srcId = Int32(truncatingIfNeeded: session.uid)
                let (incomingAndSuggest, sentItems): ([ZolaFriendRequest], [ZolaFriendRequest]) = try await withAuthenticatedChatSocket { sock in
                    let seq1 = await sock.nextSeqId()
                    let req1584 = ZolaCrypto.packFriendListRequestsFrame(srcId: srcId, seqId: seq1)
                    let resp1584 = try await sock.sendAndWait(
                        rawPayload: req1584.payload,
                        expectedCmd: ZolaConstants.cmdFriendListRequests,
                        timeoutSeconds: 6.0
                    )
                    let parsed1584 = try self.parseChatSocketResponse(resp1584, allowedCodes: [Self.noSentRequestsCode])
                    let listA = ZolaFriendRequest.parseSocketRequestAndSuggest(parsed1584.data, accountUid: self.session.uid)

                    let seq2 = await sock.nextSeqId()
                    let req396 = ZolaCrypto.packFriendListSentFrame(srcId: srcId, seqId: seq2)
                    let resp396 = try await sock.sendAndWait(
                        rawPayload: req396.payload,
                        expectedCmd: ZolaConstants.cmdFriendListSent,
                        timeoutSeconds: 6.0
                    )
                    let parsed396 = try self.parseChatSocketResponse(resp396, allowedCodes: [Self.noSentRequestsCode])
                    let listB = parsed396.code == 0
                        ? ZolaFriendRequest.parseSocketSentRequests(parsed396.data, accountUid: self.session.uid)
                        : []
                    return (listA, listB)
                }
                anyNetworkSucceeded = true
                for fr in incomingAndSuggest {
                    // Remove any lower-priority suggestion placeholder for the same UID
                    if fr.direction == .incoming {
                        resultsByKey.removeValue(forKey: "\(session.uid)_suggestion_\(fr.uid)")
                    }
                    resultsByKey[fr.id] = fr
                }
                for fr in sentItems {
                    resultsByKey.removeValue(forKey: "\(session.uid)_suggestion_\(fr.uid)")
                    resultsByKey[fr.id] = fr
                }
            } else {
                try await populateFriendRequestsViaHttpMockFallback(&resultsByKey, anyNetworkSucceeded: &anyNetworkSucceeded, lastTransportError: &lastTransportError)
            }
            #else
            try await populateFriendRequestsViaHttpMockFallback(&resultsByKey, anyNetworkSucceeded: &anyNetworkSucceeded, lastTransportError: &lastTransportError)
            #endif
        }

        if !anyNetworkSucceeded, resultsByKey.isEmpty, let err = lastTransportError {
            throw err
        }

        // 3. Also include non-friend 1-1 contacts cached on this session (strangers who messaged this nick)
        for (uid, user) in usersCache where uid > 10_000 && uid != session.uid && uid != session.sendToMeId && !user.isFriend {
            let incomingId = "\(session.uid)_incoming_\(uid)"
            let suggestionId = "\(session.uid)_suggestion_\(uid)"
            let outgoingId = "\(session.uid)_outgoing_\(uid)"
            if resultsByKey[incomingId] == nil && resultsByKey[suggestionId] == nil && resultsByKey[outgoingId] == nil {
                let fr = ZolaFriendRequest(
                    accountUid: session.uid,
                    uid: uid,
                    displayName: user.displayName,
                    avatarUrl: user.avatarUrl,
                    phone: user.phone,
                    message: user.statusText,
                    sourceLabel: "Người lạ từng nhắn tin",
                    direction: .suggestion
                )
                resultsByKey[fr.id] = fr
            }
        }

        // Enrich any placeholder display names via getUserProfile
        var enrichedList: [ZolaFriendRequest] = []
        for var fr in resultsByKey.values {
            if fr.displayName == "UID \(fr.uid)" || fr.avatarUrl.isEmpty {
                if let cached = usersCache[fr.uid], !cached.displayName.isEmpty {
                    fr.displayName = cached.displayName
                    if fr.avatarUrl.isEmpty { fr.avatarUrl = cached.avatarUrl }
                    if fr.phone.isEmpty { fr.phone = cached.phone }
                } else if let prof = try? await getUserProfile(uid: fr.uid, avatarSize: 120) {
                    fr.displayName = prof.displayName
                    fr.avatarUrl = prof.avatarUrl
                    fr.phone = prof.phone
                }
            }
            enrichedList.append(fr)
        }
        return enrichedList.sorted { $0.timestampMs > $1.timestampMs }
    }

    private func populateFriendRequestsViaHttpMockFallback(
        _ resultsByKey: inout [String: ZolaFriendRequest],
        anyNetworkSucceeded: inout Bool,
        lastTransportError: inout ZolaError?
    ) async throws {
        do {
            let recomm = try await friendServiceCall("recommendsv2/list", params: [:], method: "GET").data
            anyNetworkSucceeded = true
            for fr in ZolaFriendRequest.parseRecommendations(recomm, accountUid: session.uid) {
                resultsByKey[fr.id] = fr
            }
        } catch ZolaError.safetyGate {
            // Optional endpoint unavailable; continue with other sources
        } catch let err as ZolaError {
            if case .transport = err {
                lastTransportError = err
            } else {
                throw err
            }
        }
        do {
            let sent = try await friendServiceCall(
                "requested/list",
                params: [:],
                method: "GET",
                allowedCodes: [Self.noSentRequestsCode]
            ).data
            anyNetworkSucceeded = true
            for fr in ZolaFriendRequest.parseSentRequests(sent, accountUid: session.uid) {
                resultsByKey[fr.id] = fr
            }
        } catch ZolaError.safetyGate {
            // Optional endpoint unavailable; continue with other sources
        } catch let err as ZolaError {
            if case .transport = err {
                lastTransportError = err
            } else {
                throw err
            }
        }
    }

    internal static func isHTMLErrorBody(_ body: Data) -> Bool {
        let prefix = String(decoding: body.prefix(256), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return prefix.hasPrefix("<!doctype html") || prefix.hasPrefix("<html")
    }

    private static func decodeNoneFriendsList(_ rawValue: Any?, uid: Int64, declaredFrameSize: Int = 0) -> [Any] {
        if let arr = rawValue as? [Any] {
            return arr
        }
        guard let str = rawValue as? String, !str.isEmpty else {
            return []
        }
        if let directData = str.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: directData) as? [Any] {
            return parsed
        }
        guard let b64 = Data(base64Encoded: str), !b64.isEmpty else {
            return []
        }
        if let ungz = ZolaRequestBuilder.gunzipDecompress(b64),
           let parsed = try? JSONSerialization.jsonObject(with: ungz) as? [Any] {
            return parsed
        }
        var candidateFrameSizes: [UInt32] = []
        if declaredFrameSize > 0 {
            candidateFrameSizes.append(UInt32(truncatingIfNeeded: declaredFrameSize))
        }
        let byteLen32 = UInt32(truncatingIfNeeded: b64.count)
        if !candidateFrameSizes.contains(byteLen32) {
            candidateFrameSizes.append(byteLen32)
        }
        for frameSize in candidateFrameSizes {
            let decrypted = ZolaCrypto.encryptHTTPData(
                b64,
                srcId: Int32(truncatingIfNeeded: uid),
                frameSize: frameSize,
                keyData: ZolaConstants.noneFriendKeyData
            )
            let plain = ZolaRequestBuilder.gunzipDecompress(decrypted) ?? decrypted
            if let parsed = try? JSONSerialization.jsonObject(with: plain) as? [Any] {
                return parsed
            }
            if let dict = try? JSONSerialization.jsonObject(with: plain) as? [String: Any],
               let list = (dict["list"] ?? dict["data"] ?? dict["items"]) as? [Any] {
                return list
            }
        }
        return []
    }

    public enum FriendRequestSendOutcome: Sendable, Equatable {
        /// Request delivered (or dry-run).
        case sent
        /// Zalo answered 222/225: the other side had already invited you, or you are already friends.
        case becameFriends
    }

    @discardableResult
    public func sendFriendRequest(
        toUid: Int64,
        message: String = "Xin chào, kết bạn với mình nhé!",
        dryRun: Bool = false
    ) async throws -> FriendRequestSendOutcome {
        try assertSessionAlive()
        guard toUid > 0, toUid != session.uid else {
            throw ZolaError.invalidArgument("Invalid target UID \(toUid)")
        }
        if dryRun { return .sent }

        #if canImport(Network)
        if hasChatSocketEndpoints {
            let srcId = Int32(truncatingIfNeeded: session.uid)
            let toUid32 = Int32(truncatingIfNeeded: toUid)
            let (code, data) = try await withAuthenticatedChatSocket { sock in
                let seq = await sock.nextSeqId()
                let frame = ZolaCrypto.packFriendSendRequestFrame(
                    srcId: srcId,
                    toUid: toUid32,
                    message: message,
                    sourceType: -1,
                    srcParams: "",
                    seqId: seq
                )
                let resp = try await sock.sendAndWait(
                    rawPayload: frame.payload,
                    expectedCmd: ZolaConstants.cmdFriendSendRequest,
                    timeoutSeconds: 6.0
                )
                let parsed = try self.parseChatSocketResponse(
                    resp,
                    allowedCodes: [Self.sendReqAcceptedCode, Self.sendReqAlreadyFriendsCode]
                )
                return (parsed.code, parsed.data)
            }
            let innerCode = ZolaJSON.int(data["code"] ?? data["status"])
            let becameFriends = code == Self.sendReqAcceptedCode
                || code == Self.sendReqAlreadyFriendsCode
                || innerCode == Self.sendReqAcceptedCode
                || innerCode == Self.sendReqAlreadyFriendsCode
                || ZolaJSON.int(data["isFriend"]) == 1
            if becameFriends {
                markCachedUserAsFriend(toUid)
                return .becameFriends
            }
            return .sent
        }
        #endif

        let srcParams = #"{"uidTo":"\#(toUid)"}"#
        let code = try await friendServiceCall(
            "sendreq",
            params: [
                "toid": String(toUid),
                "msg": message,
                "reqsrc": 30,
                "language": "vi",
                "srcParams": srcParams,
            ],
            method: "POST",
            allowedCodes: [Self.sendReqAcceptedCode, Self.sendReqAlreadyFriendsCode]
        ).code
        if code == Self.sendReqAcceptedCode || code == Self.sendReqAlreadyFriendsCode {
            markCachedUserAsFriend(toUid)
            return .becameFriends
        }
        return .sent
    }

    @discardableResult
    public func acceptFriendRequest(fromUid: Int64, dryRun: Bool = false) async throws -> Bool {
        try assertSessionAlive()
        guard fromUid > 0 else {
            throw ZolaError.invalidArgument("Invalid sender UID \(fromUid)")
        }
        if dryRun { return true }

        #if canImport(Network)
        if hasChatSocketEndpoints {
            let srcId = Int32(truncatingIfNeeded: session.uid)
            let fromUid32 = Int32(truncatingIfNeeded: fromUid)
            _ = try await withAuthenticatedChatSocket { sock in
                let seq = await sock.nextSeqId()
                let frame = ZolaCrypto.packFriendAcceptRequestFrame(
                    srcId: srcId,
                    fromUid: fromUid32,
                    seqId: seq
                )
                let resp = try await sock.sendAndWait(
                    rawPayload: frame.payload,
                    expectedCmd: ZolaConstants.cmdFriendAcceptRequest,
                    timeoutSeconds: 6.0
                )
                return try self.parseChatSocketResponse(
                    resp,
                    allowedCodes: [Self.sendReqAcceptedCode, Self.sendReqAlreadyFriendsCode]
                )
            }
            markCachedUserAsFriend(fromUid)
            return true
        }
        #endif

        _ = try await friendServiceCall(
            "accept",
            params: ["fid": String(fromUid), "language": "vi"],
            method: "POST"
        )
        markCachedUserAsFriend(fromUid)
        return true
    }

    @discardableResult
    public func rejectFriendRequest(fromUid: Int64, dryRun: Bool = false) async throws -> Bool {
        try assertSessionAlive()
        guard fromUid > 0 else {
            throw ZolaError.invalidArgument("Invalid sender UID \(fromUid)")
        }
        if dryRun { return true }

        #if canImport(Network)
        if hasChatSocketEndpoints {
            let srcId = Int32(truncatingIfNeeded: session.uid)
            let fromUid32 = Int32(truncatingIfNeeded: fromUid)
            _ = try await withAuthenticatedChatSocket { sock in
                let seq = await sock.nextSeqId()
                let frame = ZolaCrypto.packFriendRejectRequestFrame(
                    srcId: srcId,
                    fromUid: fromUid32,
                    seqId: seq
                )
                let resp = try await sock.sendAndWait(
                    rawPayload: frame.payload,
                    expectedCmd: ZolaConstants.cmdFriendRejectRequest,
                    timeoutSeconds: 6.0
                )
                return try self.parseChatSocketResponse(resp)
            }
            return true
        }
        #endif

        _ = try await friendServiceCall("reject", params: ["fid": String(fromUid)], method: "POST")
        return true
    }

    @discardableResult
    public func undoFriendRequest(toUid: Int64, dryRun: Bool = false) async throws -> Bool {
        try assertSessionAlive()
        guard toUid > 0 else {
            throw ZolaError.invalidArgument("Invalid target UID \(toUid)")
        }
        if dryRun { return true }

        #if canImport(Network)
        if hasChatSocketEndpoints {
            let srcId = Int32(truncatingIfNeeded: session.uid)
            let toUid32 = Int32(truncatingIfNeeded: toUid)
            let parsed = try await withAuthenticatedChatSocket { sock in
                let seq = await sock.nextSeqId()
                let frame = ZolaCrypto.packFriendUndoRequestFrame(
                    srcId: srcId,
                    toUid: toUid32,
                    seqId: seq
                )
                let resp = try await sock.sendAndWait(
                    rawPayload: frame.payload,
                    expectedCmd: ZolaConstants.cmdFriendUndoRequest,
                    timeoutSeconds: 6.0
                )
                return try self.parseChatSocketResponse(resp, allowedCodes: [Self.noSentRequestsCode])
            }
            if let items = parsed.data["items"] as? [[String: Any]] {
                for item in items {
                    let itemCode = ZolaJSON.int(item["errorCode"] ?? item["error_code"])
                    if itemCode != 0 && itemCode != Self.noSentRequestsCode {
                        let msg = ZolaJSON.string(item["Message"] ?? item["message"] ?? parsed.message)
                        throw ZolaError.server(code: itemCode, message: msg)
                    }
                }
            }
            return true
        }
        #endif

        _ = try await friendServiceCall("undo", params: ["fid": String(toUid)], method: "POST")
        return true
    }

    private func markCachedUserAsFriend(_ uid: Int64) {
        guard let existing = usersCache[uid] else { return }
        usersCache[uid] = ZolaUser(
            uid: existing.uid,
            displayName: existing.displayName,
            zaloName: existing.zaloName,
            avatarUrl: existing.avatarUrl,
            fullAvatarUrl: existing.fullAvatarUrl,
            phone: existing.phone,
            gender: existing.gender,
            statusText: existing.statusText,
            globalId: existing.globalId,
            isFriend: true
        )
    }

    public func listFriends(
        allowSyntheticZCID: Bool = false,
        avatarSize: Int = 120
    ) async throws -> [ZolaUser] {
        try assertSessionAlive()
        if !session.zcidIsNative && !allowSyntheticZCID {
            throw ZolaError.safetyGate(
                "Refusing api/friend/loginfriend without a registered session zcid. Use cachedContacts() or sign in with a registered session."
            )
        }
        let friendBase = ZolaSession.normalizeFriendHost(
            resolvedServiceBaseURL(session.friendHost, serviceKey: "friend")
        )
        let req = try ZolaRequestBuilder.buildEncryptedRequest(
            url: "\(friendBase)/api/friend/loginfriend?",
            innerParams: [
                "avtSize": avatarSize,
                "avatarSize": avatarSize,
                "actiontime": 1,
                "type": ZolaConstants.clientTypeIOS,
                "isSorted": 1,
            ],
            session: session,
            method: "GET"
        )
        let (_, raw) = try await executeSessionRequest(req)
        let env = try ZolaRequestBuilder.parseEnvelope(
            raw,
            session: &session,
            endpoint: "api/friend/loginfriend",
            decryptZCID: true
        )
        let rawFriends: [[String: Any]]
        if let topArray = env["data"] as? [[String: Any]] {
            rawFriends = topArray
        } else if let anyArray = env["data"] as? [Any] {
            rawFriends = anyArray.compactMap { $0 as? [String: Any] }
        } else {
            let data = env["data"] as? [String: Any] ?? [:]
            rawFriends = ((data["friends"] ?? data["data"] ?? data["list"] ?? data["items"]) as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
        }
        var friends: [ZolaUser] = []
        for item in rawFriends {
            let u = ZolaUser.fromServerDict(item, isFriend: true)
            if u.uid > 0 {
                usersCache[u.uid] = u
                friends.append(u)
            }
        }
        return friends
    }

    public func cachedContacts() -> [ZolaUser] {
        usersCache.keys.sorted().compactMap { usersCache[$0] }
    }

    public func cachedUser(uid: Int64) -> ZolaUser? {
        usersCache[uid]
    }

    public func cachedGroup(gid: Int64) -> ZolaGroup? {
        groupsCache[gid]
    }

    public func cachedGroups() -> [ZolaGroup] {
        groupsCache.keys.sorted().compactMap { groupsCache[$0] }
    }

    // MARK: - 2. Message History & Unified Inbox Sync

    public func fetchFemc(
        lastClientMsgId: Int64 = 0,
        lastGlobalMsgId: Int64 = 0
    ) async throws -> ZolaFemcResponse {
        try assertSessionAlive()
        let inner = try ZolaRequestBuilder.buildChatRestInner(
            dataObject: [
                "lastClientMsgId": lastClientMsgId,
                "lastGlobalMsgId": lastGlobalMsgId,
            ],
            session: session
        )
        let req = try ZolaRequestBuilder.buildEncryptedRequest(
            url: "\(session.femcHost)/api/cm/femc",
            innerParams: inner,
            session: session,
            method: "POST"
        )
        let (_, raw) = try await executeSessionRequest(req)
        let env = try ZolaRequestBuilder.parseEnvelope(raw, session: &session, endpoint: "api/cm/femc", decryptZCID: true)
        let data = env["data"] as? [String: Any] ?? [:]
        let rawMsgs = data["msg"] as? [[String: Any]] ?? []
        let gids = knownGroupIds()

        var messages: [ZolaMessage] = []
        var reactionEvents: [ZolaEvent] = []
        var maxCli = lastClientMsgId
        var maxGlb = lastGlobalMsgId
        for m in rawMsgs {
            let zm = ZolaMessage.fromRawItem(
                m,
                selfUid: session.uid,
                sendToMeId: session.sendToMeId,
                knownGroupIds: gids,
                cryptKey: session.cryptKey,
                defaultSource: "femc"
            )
            if zm.cliMsgId > maxCli { maxCli = zm.cliMsgId }
            if Self.hasRealServerGlobalId(zm), zm.id > maxGlb { maxGlb = zm.id }
            let reactions = nativeReactionEvents(m, knownGroupIds: gids)
            if !reactions.isEmpty { reactionEvents.append(contentsOf: reactions); continue }
            harvestSender(zm)
            messages.append(zm)
        }
        return ZolaFemcResponse(
            e: ZolaJSON.int(env["e"]),
            hasMore: (data["hasMore"] as? Bool) ?? false,
            maxCliMsgId: maxCli,
            maxGlbMsgId: maxGlb,
            messages: messages,
            reactionEvents: reactionEvents
        )
    }

    public func fetchPreload(
        groupCursors: [Int64: ZolaGroupCursor]? = nil,
        singleCursors: [Int64: Int64]? = nil,
        loadType: Int = 0
    ) async throws -> ZolaPreloadResponse {
        try assertSessionAlive()
        let cursors = groupCursors ?? watermarks.groupCursors
        let groupsPayload: [[String: Any]] = cursors.keys.sorted().compactMap { gid in
            guard let meta = cursors[gid] else { return nil }
            return [
                "gid": gid,
                "glbMsgId": max(1, meta.glbMsgId),
                "tsJoinGroup": max(1, meta.tsJoinGroup),
            ]
        }
        let sCursors = singleCursors ?? watermarks.singleCursors
        let selectedSingleUids = selectPreloadSingleUids(from: sCursors, maxCount: 60)
        let singlesPayload: [[String: Any]] = selectedSingleUids.compactMap { uid in
            guard let gmi = sCursors[uid] else { return nil }
            return [
                "uid": uid,
                "glbMsgId": max(1, gmi),
            ]
        }
        var inner = try ZolaRequestBuilder.buildChatRestInner(
            dataObject: [
                "group": groupsPayload,
                "single": singlesPayload,
                "loadType": loadType,
            ],
            session: session
        )
        inner["encryptParams"] = 1
        let req = try ZolaRequestBuilder.buildEncryptedRequest(
            url: "\(session.mfetchHost)/api/preload",
            innerParams: inner,
            session: session,
            method: "POST"
        )
        let (_, raw) = try await executeSessionRequest(req)
        let env = try ZolaRequestBuilder.parseEnvelope(raw, session: &session, endpoint: "api/preload", decryptZCID: true)
        let data = env["data"] as? [String: Any] ?? [:]

        var joined: [Int64: ZolaGroupCursor] = [:]
        if let infoArr = data["infoJoinGroup"] as? [[String: Any]] {
            for g in infoArr {
                let gid = ZolaJSON.int64(g["gid"])
                if gid > 0 {
                    joined[gid] = ZolaGroupCursor(
                        glbMsgId: ZolaJSON.int64(g["glbMsgId"]),
                        tsJoinGroup: ZolaJSON.int64(g["tsJoinGroup"])
                    )
                }
            }
        }

        let gids = knownGroupIds().union(joined.keys)
        let rawLast = data["lastMsgs"] as? [[String: Any]] ?? []
        let rawLastSeen = data["lastSeenMsgs"] as? [[String: Any]] ?? []
        var messages: [ZolaMessage] = []
        var reactionEvents: [ZolaEvent] = []
        var seenMsgKeys = Set<String>()
        for m in rawLast + rawLastSeen {
            let reactions = nativeReactionEvents(m, knownGroupIds: gids)
            if !reactions.isEmpty { reactionEvents.append(contentsOf: reactions); continue }
            let zm = ZolaMessage.fromRawItem(
                m,
                selfUid: session.uid,
                sendToMeId: session.sendToMeId,
                knownGroupIds: gids,
                cryptKey: session.cryptKey,
                defaultSource: "preload"
            )
            let mk = "\(zm.threadId):\(zm.id):\(zm.cliMsgId)"
            guard seenMsgKeys.insert(mk).inserted else { continue }
            harvestSender(zm)
            messages.append(zm)
            if var cur = joined[zm.toId], zm.id > cur.glbMsgId {
                cur.glbMsgId = zm.id
                joined[zm.toId] = cur
            }
        }
        return ZolaPreloadResponse(
            e: ZolaJSON.int(env["e"]),
            joinedGroups: joined,
            messages: messages,
            reactionEvents: reactionEvents
        )
    }

    /// Fetches queued incoming 1-1 offline messages via `POST {failoverUrl}/api/message` (`cmd = 115, subCmd = 1`).
    public func fetchOfflineMessages() async throws -> [ZolaMessage] {
        try await fetchOfflineBatch().messages
    }

    private func fetchOfflineBatch() async throws -> (messages: [ZolaMessage], reactionEvents: [ZolaEvent]) {
        try assertSessionAlive()
        let (req, _, _) = try ZolaRequestBuilder.buildFailoverGetOfflinePOST(session: session)
        let (_, raw) = try await executeSessionRequest(req)
        let env = try ZolaRequestBuilder.parseEnvelope(
            raw,
            session: &session,
            endpoint: "api/message(cmd=115)"
        )
        let dataDict = env["data"] as? [String: Any] ?? [:]
        let offlineNode = dataDict["offline"] ?? dataDict
        let rawItems = Self.extractRawMessageDicts(from: offlineNode)
        let gids = knownGroupIds()
        var messages: [ZolaMessage] = []
        var reactionEvents: [ZolaEvent] = []
        for item in rawItems {
            let reactions = nativeReactionEvents(item, knownGroupIds: gids)
            if !reactions.isEmpty { reactionEvents.append(contentsOf: reactions); continue }
            let zm = ZolaMessage.fromRawItem(
                item,
                selfUid: session.uid,
                sendToMeId: session.sendToMeId,
                knownGroupIds: gids,
                cryptKey: session.cryptKey,
                defaultSource: "offline"
            )
            if zm.threadId > 0 {
                harvestSender(zm)
                messages.append(zm)
            }
        }
        return (messages, reactionEvents)
    }

    /// Loads group message history by range via `POST {mfetchHost}/api/cm/mfetch`.
    public func fetchGroupRange(
        gid: Int64,
        fromGlobalId: Int64 = 0,
        toGlobalId: Int64 = 0,
        fromClientId: Int64 = 0,
        toClientId: Int64 = 0,
        load: Int = 1
    ) async throws -> [ZolaMessage] {
        try assertSessionAlive()
        guard gid > 0 else { throw ZolaError.invalidArgument("Invalid group gid \(gid)") }
        let rangeItem: [String: Any] = [
            "gId": gid,
            "fGmi": fromGlobalId,
            "fCmi": fromClientId,
            "tGmi": toGlobalId,
            "tCmi": toClientId,
            "load": load,
        ]
        let inner = try ZolaRequestBuilder.buildChatRestInner(
            dataObject: ["gIds": [rangeItem]],
            session: session
        )
        let req = try ZolaRequestBuilder.buildEncryptedRequest(
            url: "\(session.mfetchHost)/api/cm/mfetch",
            innerParams: inner,
            session: session,
            method: "POST"
        )
        let (_, raw) = try await executeSessionRequest(req)
        let env = try ZolaRequestBuilder.parseEnvelope(
            raw,
            session: &session,
            endpoint: "api/cm/mfetch",
            decryptZCID: true
        )
        let gids = knownGroupIds().union([gid])
        let rawItems = Self.extractRawMessageDicts(from: env["data"])
        var messages: [ZolaMessage] = []
        for item in rawItems {
            if !ZolaReactionUpdate.fromRawItem(item, selfUid: session.uid, knownGroupIds: gids, isGroup: true).isEmpty { continue }
            let zm = ZolaMessage.fromRawItem(
                item,
                selfUid: session.uid,
                sendToMeId: session.sendToMeId,
                knownGroupIds: gids,
                cryptKey: session.cryptKey,
                defaultSource: "mfetch"
            )
            let resolved: ZolaMessage
            if zm.threadId <= 0 || !zm.isGroup {
                resolved = ZolaMessage(
                    id: zm.id,
                    cliMsgId: zm.cliMsgId,
                    threadId: gid,
                    isGroup: true,
                    senderId: zm.senderId,
                    senderName: zm.senderName,
                    toId: gid,
                    tsMs: zm.tsMs,
                    msgType: zm.msgType,
                    kind: zm.kind,
                    text: zm.text,
                    attachments: zm.attachments,
                    quote: zm.quote,
                    isSelf: zm.isSelf,
                    isCloud: false,
                    mcrypt: zm.mcrypt,
                    source: zm.source,
                    reactions: zm.reactions,
                    hasReactionSnapshot: zm.hasReactionSnapshot,
                    mentions: zm.mentions,
                    webContent: zm.webContent,
                    rawDebugJson: zm.rawDebugJson,
                    groupEvent: zm.groupEvent,
                    boardCard: zm.boardCard
                )
            } else {
                resolved = zm
            }
            harvestSender(resolved)
            messages.append(resolved)
        }
        return messages.sorted { ($0.tsMs, $0.id) < ($1.tsMs, $1.id) }
    }

    /// Returns `true` once backward `mfetch` paging has drained this group's server-held history.
    public func isGroupHistoryExhausted(_ gid: Int64) -> Bool {
        historyExhaustedGids.contains(gid)
    }

    /// Loops `api/cm/mfetch` BACKWARD (`tGmi = oldest - 1`) to load group history older than
    /// `beforeGlobalMsgId`, up to `pageLimit` pages. Read-only, rate-limited (`pageDelayNs` between
    /// pages, default 400ms = ≤1 request/400ms), and stops on an empty page, a cursor that stops
    /// moving back, or a tripped circuit breaker (`102` / `-96` propagate as `sessionExpired`).
    /// Never mutates live `watermarks` — this only reads older messages for persistence by the caller.
    /// Latches `historyExhaustedGids` when the server returns no further older history.
    public func fetchOlderGroupHistory(
        gid: Int64,
        beforeGlobalMsgId: Int64,
        pageLimit: Int = 20,
        pageDelayNs: UInt64 = 400_000_000,
        shouldCancel: (@Sendable () -> Bool)? = nil
    ) async throws -> (messages: [ZolaMessage], oldestGlobalMsgId: Int64, exhausted: Bool) {
        try assertSessionAlive()
        guard gid > 0 else { throw ZolaError.invalidArgument("Invalid group gid \(gid)") }
        if historyExhaustedGids.contains(gid) {
            return ([], max(0, beforeGlobalMsgId), true)
        }

        var cursor = max(0, beforeGlobalMsgId)
        var collected: [ZolaMessage] = []
        var seenGlb = Set<Int64>()
        var exhausted = false
        let pages = max(1, pageLimit)
        func cancelled() -> Bool { Task.isCancelled || (shouldCancel?() ?? false) }

        for pageIndex in 0..<pages {
            // Stop between pages without latching `exhausted` — history is not truly drained.
            if cancelled() { break }
            // Window ends just below the oldest glb we already hold; from 0 so the server
            // returns the newest slice inside [0, toGlb] and we walk backward page by page.
            let toGlb = cursor > 0 ? cursor - 1 : 0
            if cursor > 0 && toGlb <= 0 {
                exhausted = true
                break
            }
            if pageIndex > 0 {
                try? await Task.sleep(nanoseconds: pageDelayNs)
                try assertSessionAlive()
                if cancelled() { break }
            }
            let batch = try await fetchGroupRange(
                gid: gid,
                fromGlobalId: 0,
                toGlobalId: toGlb,
                fromClientId: 0,
                toClientId: 0,
                load: 1
            )
            var addedNew = false
            var minGlbThisPage: Int64 = 0
            for m in batch {
                if Self.hasRealServerGlobalId(m) {
                    if minGlbThisPage == 0 || m.id < minGlbThisPage { minGlbThisPage = m.id }
                    if seenGlb.insert(m.id).inserted {
                        collected.append(m)
                        addedNew = true
                    }
                } else {
                    collected.append(m)
                    addedNew = true
                }
            }
            // Stop if the server gave nothing older, or the cursor can no longer move backward.
            if batch.isEmpty || minGlbThisPage <= 0 || !addedNew || (cursor > 0 && minGlbThisPage >= cursor) {
                exhausted = true
                break
            }
            cursor = minGlbThisPage
        }

        if exhausted {
            historyExhaustedGids.insert(gid)
        }
        let oldest = seenGlb.min() ?? max(0, cursor)
        let sorted = collected.sorted { ($0.tsMs, $0.id) < ($1.tsMs, $1.id) }
        return (sorted, oldest, exhausted)
    }

    /// On-demand "deep" history sync (the "đồng bộ toàn bộ tin nhắn" / new-device flow):
    /// 1) Re-arms and (if a live `UXChatSocket` is connected) re-fires the native GetOffline
    ///    drain so the socket re-pulls the full server-held queue forward.
    /// 2) Pages `fe-mc.chat.zalo.me/api/cm/femc` forward (1-1 + Cloud) up to `maxPages`,
    ///    rate-limited to one request per `pageDelayNs` (default 400ms).
    /// Read-only; respects the circuit breaker (throws `sessionExpired` on `102` / `-96`).
    /// Returns the fetched 1-1/Cloud messages for the caller to persist (dedup is by SQLite `msg_key`).
    @discardableResult
    public func drainOfflineHistory(
        maxPages: Int = 200,
        pageDelayNs: UInt64 = 400_000_000,
        shouldCancel: (@Sendable () -> Bool)? = nil
    ) async throws -> [ZolaMessage] {
        try assertSessionAlive()
        #if canImport(Network)
        rearmSocketOfflineDrain()
        if let sock = activeVoipSocket, await sock.isSocketAlive() {
            await requestInitialSocketOfflineDrainIfNeeded(on: sock)
        }
        #endif
        let resp = try await fetchAllFemcPages(
            maxPages: max(1, maxPages),
            pageDelayNs: pageDelayNs,
            shouldCancel: shouldCancel
        )
        return resp.messages
    }

    #if canImport(Network)
    /// Clears the one-shot socket-drain guards so the next live socket re-pulls the offline queue.
    private func rearmSocketOfflineDrain() {
        lastDrainedSocketObjectId = nil
        socketOfflineSinglePagesDrained = 0
        socketOfflineGroupPagesDrained = 0
    }
    #endif

    internal static func extractRawMessageDicts(from anyData: Any?) -> [[String: Any]] {
        guard let anyData else { return [] }
        if let array = anyData as? [Any] { return array.flatMap { extractRawMessageDicts(from: $0) } }
        guard let dict = anyData as? [String: Any] else { return [] }
        // A `msg` ARRAY is a batch container, never a message. The previous array fast path
        // returned these containers as empty messages and discarded their real children.
        if isSingleSocketMessageDict(dict), !(dict["msg"] is [Any]), !(dict["msgs"] is [Any]) {
            return [dict]
        }
        var out: [[String: Any]] = []
        for key in ["msg", "msgs", "lastMsgs", "data", "gIds", "groups", "list"] {
            if let child = dict[key] { out.append(contentsOf: extractRawMessageDicts(from: child)) }
        }
        if out.isEmpty {
            for child in dict.values where child is [String: Any] || child is [Any] {
                out.append(contentsOf: extractRawMessageDicts(from: child))
            }
        }
        return out
    }

    private func fetchAllFemcPages(
        maxPages: Int = 5,
        pageDelayNs: UInt64 = 0,
        shouldCancel: (@Sendable () -> Bool)? = nil
    ) async throws -> ZolaFemcResponse {
        var curCli: Int64 = 0
        var curGlb: Int64 = 0
        var allMessages: [ZolaMessage] = []
        var reactionEvents: [ZolaEvent] = []
        var lastE = 0
        var hasMore = false
        func cancelled() -> Bool { Task.isCancelled || (shouldCancel?() ?? false) }
        for pageIndex in 0..<max(1, maxPages) {
            if cancelled() { break }
            if pageIndex > 0, pageDelayNs > 0 {
                try? await Task.sleep(nanoseconds: pageDelayNs)
                try assertSessionAlive()
                if cancelled() { break }
            }
            let page = try await fetchFemc(lastClientMsgId: curCli, lastGlobalMsgId: curGlb)
            lastE = page.e
            allMessages.append(contentsOf: page.messages)
            reactionEvents.append(contentsOf: page.reactionEvents)
            hasMore = page.hasMore
            if !page.hasMore || (page.messages.isEmpty && page.reactionEvents.isEmpty) || (page.maxCliMsgId <= curCli && page.maxGlbMsgId <= curGlb) {
                curCli = max(curCli, page.maxCliMsgId)
                curGlb = max(curGlb, page.maxGlbMsgId)
                break
            }
            curCli = max(curCli, page.maxCliMsgId)
            curGlb = max(curGlb, page.maxGlbMsgId)
        }
        return ZolaFemcResponse(
            e: lastE,
            hasMore: hasMore,
            maxCliMsgId: curCli,
            maxGlbMsgId: curGlb,
            messages: allMessages,
            reactionEvents: reactionEvents
        )
    }

    public func primeWatermarks(from conversations: [ZolaConversation]) {
        watermarks.reserveSeenCapacity(forMessages: conversations.reduce(0) { $0 + $1.messages.count })
        for conv in conversations {
            if !conv.isGroup && conv.threadId > 0 && conv.threadId != session.uid {
                watermarks.registerSingles([conv.threadId])
            }
            for m in conv.messages {
                _ = watermarks.markSeen(Self.dedupeKey(for: m))
                if Self.hasRealServerGlobalId(m) {
                    _ = watermarks.markSeen("glb:\(m.id)")
                }
                if !conv.isGroup {
                    if m.cliMsgId > watermarks.femcLastCliId {
                        watermarks.femcLastCliId = m.cliMsgId
                    }
                    if Self.hasRealServerGlobalId(m) {
                        if m.id > watermarks.femcLastGlbId {
                            watermarks.femcLastGlbId = m.id
                        }
                        let curSingle = watermarks.singleCursors[conv.threadId] ?? 1
                        watermarks.singleCursors[conv.threadId] = max(curSingle, m.id)
                    }
                } else if Self.hasRealServerGlobalId(m) {
                    var cur = watermarks.groupCursors[conv.threadId] ?? ZolaGroupCursor(glbMsgId: 1, tsJoinGroup: 1)
                    if m.id > cur.glbMsgId {
                        cur.glbMsgId = m.id
                        watermarks.groupCursors[conv.threadId] = cur
                    }
                }
            }
        }
        watermarks.initialized = true
        if let url = watermarkFileURL {
            try? ZolaFileSessionStore.saveWatermark(watermarks, to: url)
        }
    }

    private func buildSnapshotSingleCursors(extraMessages: [ZolaMessage] = []) -> [Int64: Int64] {
        let gids = knownGroupIds()
        var pinned: [Int64] = []
        if session.sendToMeId > 0 {
            pinned.append(session.sendToMeId)
        }
        for m in extraMessages where !m.isGroup && m.threadId > 0 && m.threadId != session.uid && !gids.contains(m.threadId) {
            pinned.append(m.threadId)
        }
        let chosen = selectPreloadSingleUids(
            from: watermarks.singleCursors,
            fallbackPool: Array(usersCache.keys),
            pinnedUids: pinned,
            maxCount: 60
        )
        var singles: [Int64: Int64] = [:]
        if session.sendToMeId > 0 {
            singles[session.sendToMeId] = 1
        }
        for uid in chosen {
            singles[uid] = 1
        }
        return singles
    }

    public func syncInbox(discoverGroups: Bool = true) async throws -> [ZolaConversation] {
        try assertSessionAlive()
        if discoverGroups {
            _ = try await listJoinedGroups()
            if session.zcidIsNative {
                do {
                    _ = try await listFriends()
                } catch let zolaErr as ZolaError {
                    if case .sessionExpired = zolaErr { throw zolaErr }
                } catch {
                    // Optional contact preload failure does not abort inbox sync
                }
            }
        }
        async let offlineTask: [ZolaMessage] = {
            do {
                return try await self.fetchOfflineMessages()
            } catch let zolaErr as ZolaError {
                if case .sessionExpired = zolaErr { throw zolaErr }
                return []
            } catch {
                return []
            }
        }()
        async let femcTask: Result<ZolaFemcResponse, Error> = {
            do {
                return .success(try await self.fetchAllFemcPages(maxPages: 3))
            } catch {
                return .failure(error)
            }
        }()

        let offlineMsgs = try await offlineTask
        let femcResult = await femcTask
        let femcMessages: [ZolaMessage]
        var femcFailure: Error?
        switch femcResult {
        case .success(let resp):
            femcMessages = resp.messages
        case .failure(let err):
            if let zErr = err as? ZolaError, case .sessionExpired = zErr {
                throw zErr
            }
            femcMessages = []
            femcFailure = err
        }

        var snapshotCursors: [Int64: ZolaGroupCursor] = [:]
        for gid in knownGroupIds() where gid > 0 {
            let existingTs = watermarks.groupCursors[gid]?.tsJoinGroup ?? 1
            snapshotCursors[gid] = ZolaGroupCursor(glbMsgId: 1, tsJoinGroup: max(1, existingTs))
        }
        let snapshotSingles = buildSnapshotSingleCursors(extraMessages: femcMessages + offlineMsgs)
        let preloadMessages: [ZolaMessage]
        do {
            let preload = try await fetchPreload(groupCursors: snapshotCursors, singleCursors: snapshotSingles)
            preloadMessages = preload.messages
        } catch let zErr as ZolaError {
            if case .sessionExpired = zErr { throw zErr }
            if let femcFailure, offlineMsgs.isEmpty {
                throw femcFailure
            }
            preloadMessages = []
        } catch {
            if let femcFailure, offlineMsgs.isEmpty {
                throw femcFailure
            }
            preloadMessages = []
        }

        var byThread: [Int64: [Int64: ZolaMessage]] = [:]
        for m in femcMessages + offlineMsgs + preloadMessages where m.threadId > 0 {
            let key = m.id > 0 ? m.id : m.cliMsgId
            byThread[m.threadId, default: [:]][key] = m
        }
        for gid in groupsCache.keys where byThread[gid] == nil {
            byThread[gid] = [:]
        }

        // Resolve unknown 1-1 UIDs concurrently via Mode 1 getProfile
        var unknownUids: [Int64] = []
        for (tid, msgMap) in byThread where tid > 0 && tid != session.sendToMeId && groupsCache[tid] == nil {
            let sorted = msgMap.values.sorted { ($0.tsMs, $0.id) < ($1.tsMs, $1.id) }
            let isGrp = sorted.last?.isGroup ?? false
            guard !isGrp else { continue }
            let cached = usersCache[tid]
            let senderFallback = sorted.last.flatMap { !$0.isSelf && !$0.senderName.isEmpty ? $0.senderName : nil }
            if cached == nil && senderFallback == nil && unknownUids.count < 20 {
                unknownUids.append(tid)
            }
        }
        if !unknownUids.isEmpty {
            await withTaskGroup(of: Void.self) { group in
                for uid in unknownUids {
                    group.addTask {
                        _ = try? await self.getUserProfile(uid: uid)
                    }
                }
            }
        }

        var convs: [ZolaConversation] = []
        for (tid, msgMap) in byThread {
            let sortedMsgs = msgMap.values.sorted { ($0.tsMs, $0.id) < ($1.tsMs, $1.id) }
            let lastMsg = sortedMsgs.last
            let grp = groupsCache[tid]
            let isGroup = grp != nil || (lastMsg?.isGroup ?? false)
            let isCloud = tid == session.sendToMeId

            let title: String
            let avatar: String
            let memberCount: Int
            if isCloud {
                title = "Cloud của tôi"
                avatar = ""
                memberCount = 1
            } else if let grp {
                title = grp.name
                avatar = grp.avatarUrl
                memberCount = grp.totalMembers
            } else if let usr = usersCache[tid] {
                title = usr.displayName
                avatar = usr.avatarUrl
                memberCount = 2
            } else if let lm = lastMsg, !lm.isSelf, !lm.senderName.isEmpty {
                title = lm.senderName
                avatar = usersCache[lm.senderId]?.avatarUrl ?? ""
                memberCount = 2
            } else {
                title = "UID \(tid)"
                avatar = ""
                memberCount = 2
            }

            let needsReply = (lastMsg != nil) && !(lastMsg?.isSelf ?? true) && !isCloud
            var trailingUnread = 0
            if needsReply {
                for m in sortedMsgs.reversed() {
                    if m.isSelf { break }
                    trailingUnread += 1
                }
            }
            convs.append(
                ZolaConversation(
                    threadId: tid,
                    isGroup: isGroup,
                    isCloud: isCloud,
                    title: title,
                    avatarUrl: avatar,
                    lastMessage: lastMsg,
                    unreadCount: needsReply ? max(1, trailingUnread) : 0,
                    needsReply: needsReply,
                    memberCount: memberCount,
                    messages: sortedMsgs
                )
            )
        }

        convs.sort { a, b in
            let tsA = a.lastMessage?.tsMs ?? (groupsCache[a.threadId]?.versionTs ?? 0)
            let tsB = b.lastMessage?.tsMs ?? (groupsCache[b.threadId]?.versionTs ?? 0)
            return tsA != tsB ? tsA > tsB : a.threadId > b.threadId
        }
        return convs
    }

    // MARK: - 3. Incremental Poller & AsyncThrowingStream

    public func pollOnce(
        includePreload: Bool = true,
        includeOffline: Bool = true,
        emitInitialSnapshot: Bool = false
    ) async throws -> [ZolaEvent] {
        try assertSessionAlive()
        let nowUptime = ProcessInfo.processInfo.systemUptime
        let elapsed = nowUptime - lastPollUptime
        if lastPollUptime > 0, elapsed < minPollIntervalSeconds {
            let ns = UInt64((minPollIntervalSeconds - elapsed) * 1_000_000_000)
            try await Task.sleep(nanoseconds: ns)
        }
        lastPollUptime = ProcessInfo.processInfo.systemUptime

        let wasInitialized = watermarks.initialized
        var events: [ZolaEvent] = []
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)

        async let offlineTask: (messages: [ZolaMessage], reactionEvents: [ZolaEvent]) = {
            guard includeOffline else { return ([], []) }
            do {
                return try await self.fetchOfflineBatch()
            } catch let zolaErr as ZolaError {
                if case .sessionExpired = zolaErr { throw zolaErr }
                return ([], [])
            } catch {
                return ([], [])
            }
        }()
        async let femcTask: Result<ZolaFemcResponse, Error> = {
            do {
                return .success(try await self.fetchAllFemcPages(maxPages: 2))
            } catch {
                return .failure(error)
            }
        }()

        let offlineBatch = try await offlineTask
        let offlineMsgs = offlineBatch.messages
        var pendingReactionEvents = offlineBatch.reactionEvents
        let femcResult = await femcTask

        var femcMessages: [ZolaMessage] = []
        var femcError: Error?
        switch femcResult {
        case .success(let femc):
            if femc.e == 0 {
                femcMessages = femc.messages
                pendingReactionEvents.append(contentsOf: femc.reactionEvents)
                watermarks.femcLastCliId = max(watermarks.femcLastCliId, femc.maxCliMsgId)
                watermarks.femcLastGlbId = max(watermarks.femcLastGlbId, femc.maxGlbMsgId)
            } else {
                femcError = ZolaError.transport("femc returned non-zero e=\(femc.e)")
            }
        case .failure(let err):
            if let zErr = err as? ZolaError, case .sessionExpired = zErr {
                throw zErr
            }
            femcError = err
        }

        watermarks.reserveSeenCapacity(forMessages: offlineMsgs.count + femcMessages.count)

        if includeOffline {
            for m in offlineMsgs {
                let kUnseen = watermarks.markSeen(Self.dedupeKey(for: m))
                let gUnseen = Self.hasRealServerGlobalId(m) ? watermarks.markSeen("glb:\(m.id)") : true
                let isUnseen = kUnseen && gUnseen
                if !m.isGroup, m.threadId > 0, Self.hasRealServerGlobalId(m) {
                    let curSingle = watermarks.singleCursors[m.threadId] ?? 1
                    watermarks.singleCursors[m.threadId] = max(curSingle, m.id)
                }
                if wasInitialized || emitInitialSnapshot {
                    if let event = messageEvent(m, isUnseen: isUnseen, nowMs: nowMs) { events.append(event) }
                }
            }
        }

        for m in femcMessages {
            let kUnseen = watermarks.markSeen(Self.dedupeKey(for: m))
            let gUnseen = Self.hasRealServerGlobalId(m) ? watermarks.markSeen("glb:\(m.id)") : true
            let isUnseen = kUnseen && gUnseen
            if !m.isGroup, m.threadId > 0, Self.hasRealServerGlobalId(m) {
                let curSingle = watermarks.singleCursors[m.threadId] ?? 1
                watermarks.singleCursors[m.threadId] = max(curSingle, m.id)
            }
            if wasInitialized {
                if let event = messageEvent(m, isUnseen: isUnseen, nowMs: nowMs) { events.append(event) }
            } else if emitInitialSnapshot && isUnseen {
                if let event = messageEvent(m, isUnseen: true, nowMs: nowMs) { events.append(event) }
            }
        }

        var preloadError: Error?
        if includePreload {
            var snapshotGroupCursors: [Int64: ZolaGroupCursor] = [:]
            for gid in knownGroupIds() where gid > 0 {
                let existingTs = watermarks.groupCursors[gid]?.tsJoinGroup ?? 1
                snapshotGroupCursors[gid] = ZolaGroupCursor(glbMsgId: 1, tsJoinGroup: max(1, existingTs))
            }
            let snapshotSingleCursors = buildSnapshotSingleCursors(extraMessages: femcMessages + offlineMsgs)
            do {
                let preload = try await fetchPreload(
                    groupCursors: snapshotGroupCursors,
                    singleCursors: snapshotSingleCursors
                )
                if preload.e == 0 {
                    pendingReactionEvents.append(contentsOf: preload.reactionEvents)
                    for (gid, gmeta) in preload.joinedGroups {
                        let cur = watermarks.groupCursors[gid] ?? ZolaGroupCursor(glbMsgId: 0, tsJoinGroup: 0)
                        watermarks.groupCursors[gid] = ZolaGroupCursor(
                            glbMsgId: max(cur.glbMsgId, gmeta.glbMsgId),
                            tsJoinGroup: gmeta.tsJoinGroup > 0 ? gmeta.tsJoinGroup : cur.tsJoinGroup
                        )
                    }
                    watermarks.reserveSeenCapacity(forMessages: offlineMsgs.count + femcMessages.count + preload.messages.count)
                    for m in preload.messages {
                        let kUnseen = watermarks.markSeen(Self.dedupeKey(for: m))
                        let gUnseen = Self.hasRealServerGlobalId(m) ? watermarks.markSeen("glb:\(m.id)") : true
                        let isUnseen = kUnseen && gUnseen
                        if var cur = watermarks.groupCursors[m.toId], Self.hasRealServerGlobalId(m), m.id > cur.glbMsgId {
                            cur.glbMsgId = m.id
                            watermarks.groupCursors[m.toId] = cur
                        } else if !m.isGroup, m.threadId > 0, Self.hasRealServerGlobalId(m) {
                            let curSingle = watermarks.singleCursors[m.threadId] ?? 1
                            watermarks.singleCursors[m.threadId] = max(curSingle, m.id)
                        }
                        if wasInitialized {
                            if let event = messageEvent(m, isUnseen: isUnseen, nowMs: nowMs) { events.append(event) }
                        } else if emitInitialSnapshot && isUnseen {
                            if let event = messageEvent(m, isUnseen: true, nowMs: nowMs) { events.append(event) }
                        }
                    }
                } else {
                    preloadError = ZolaError.transport("preload returned non-zero e=\(preload.e)")
                }
            } catch let zErr as ZolaError {
                if case .sessionExpired = zErr {
                    throw zErr
                }
                preloadError = zErr
            } catch {
                preloadError = error
            }
        }

        if events.isEmpty, pendingReactionEvents.isEmpty, offlineMsgs.isEmpty, let femcError, (!includePreload || preloadError != nil) {
            throw femcError
        }
        if events.isEmpty, pendingReactionEvents.isEmpty, offlineMsgs.isEmpty, femcError != nil || !wasInitialized, let preloadError, femcError != nil {
            throw preloadError
        }

        watermarks.initialized = true
        if let url = watermarkFileURL {
            try ZolaFileSessionStore.saveWatermark(watermarks, to: url)
        }
        events.append(contentsOf: pendingReactionEvents)
        return events
    }

    public nonisolated func eventStream(
        intervalSeconds: Double = 2.0,
        includePreload: Bool = true
    ) -> AsyncThrowingStream<ZolaEvent, Error> {
        let waitNs = UInt64(max(intervalSeconds, ZolaConstants.minPollIntervalSeconds) * 1_000_000_000)
        return AsyncThrowingStream { continuation in
            let task = Task {
                while !Task.isCancelled {
                    do {
                        let batch = try await self.pollOnce(
                            includePreload: includePreload,
                            includeOffline: true,
                            emitInitialSnapshot: true
                        )
                        for ev in batch {
                            continuation.yield(ev)
                        }
                        try await Task.sleep(nanoseconds: waitNs)
                    } catch let zolaErr as ZolaError {
                        if case .sessionExpired = zolaErr {
                            continuation.finish(throwing: zolaErr)
                            return
                        }
                        try? await Task.sleep(nanoseconds: waitNs)
                    } catch is CancellationError {
                        continuation.finish()
                        return
                    } catch {
                        if Task.isCancelled {
                            continuation.finish()
                            return
                        }
                        try? await Task.sleep(nanoseconds: waitNs)
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    // MARK: - 4. Session-Safe Writes (`dryRun: Bool = true` Default!)

    public func sendText1To1(
        to toId: Int64,
        text: String,
        quote: ZolaQuote? = nil,
        ttlMs: Int64 = 0,
        dryRun: Bool = true,
        isGroup: Bool = false,
        requireCryptKey: Bool = true,
        clientIdMs: Int64? = nil,
        iv16: Data? = nil,
        trackingIdHex: String? = nil
    ) async throws -> ZolaSendReceipt {
        try assertSessionAlive()
        if isGroup || knownGroupIds().contains(toId) {
            throw ZolaError.groupSendNotSupportedOverHttp
        }
        guard !text.isEmpty else {
            throw ZolaError.invalidArgument("Message text must not be empty")
        }
        if requireCryptKey && session.cryptKey.isEmpty {
            throw ZolaError.safetyGate("Refusing unencrypted send: missing 16-byte CrypKey")
        }

        let cid = clientIdMs ?? Int64(Date().timeIntervalSince1970 * 1000)
        let desId64 = (toId == session.uid) ? session.sendToMeId : toId
        let hasCk = !session.cryptKey.isEmpty

        let built = try ZolaCrypto.buildTextMsgBodyData(
            text: text,
            isGroup: false,
            includeIOSProps: hasCk,
            trackingIdHex: trackingIdHex,
            clientIdMs: cid,
            ttlMs: ttlMs,
            quote: quote,
            cryptKey: hasCk ? session.cryptKey : nil,
            iv16: iv16,
            legacyCmd101: !hasCk && quote == nil && ttlMs <= 0
        )
        let (req, frame, endpointBase) = try ZolaRequestBuilder.buildFailoverOctetPOST(
            session: session,
            desId: Int32(truncatingIfNeeded: desId64),
            globalMsgId: cid,
            subCmd: built.subCmd,
            bodyData: built.bodyData,
            e2ee: false,
            callIdMs: cid
        )

        if dryRun {
            return ZolaSendReceipt(
                ok: true,
                dryRun: true,
                sent: false,
                endpoint: endpointBase,
                uid: session.uid,
                desId: desId64,
                cmd: frame.cmd,
                innerSocketCmd: built.innerCmd,
                subCmd: built.subCmd,
                clientIdMs: cid,
                frameSize: frame.frameSize,
                cryptKeySha256_8: session.cryptKeySha256_8,
                serverErrorCode: nil
            )
        }

        let (status, ackData) = try await executeSessionRequest(req)
        let decodedAckData = ZolaCrypto.gunzipOrInflate(ackData) ?? ackData
        if let ackJson = try? JSONSerialization.jsonObject(with: decodedAckData) as? [String: Any],
           ackJson["error_code"] != nil
        {
            let code = ZolaJSON.int(ackJson["error_code"])
            if code == ZolaConstants.errorSessionExpired || code == ZolaConstants.errorFemcInvalidSession {
                let rawMsg = ZolaJSON.string(ackJson["error_message"])
                let msg = ZolaRequestBuilder.friendlySessionExpiredReason(rawMsg, code: code)
                session.markExpired(code: code, reason: msg)
                throw ZolaError.sessionExpired(code: code, endpoint: "failover/api/message", message: msg)
            }
        }
        let evaluated = Self.evaluateFailoverAck(
            httpStatus: status,
            decodedAckData: decodedAckData,
            clientIdMs: cid
        )
        if status == 200, !session.isExpired, let handler = realtimeEventHandler {
            let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
            for update in ZolaNativeChatSignals.httpDeliveries(decodedAckData, accountUid: session.uid) {
                handler(ZolaEvent(type: "message.delivery", tsMs: nowMs, delivery: update))
            }
        }

        return ZolaSendReceipt(
            ok: evaluated.ok,
            dryRun: false,
            sent: true,
            endpoint: endpointBase,
            uid: session.uid,
            desId: desId64,
            cmd: frame.cmd,
            innerSocketCmd: built.innerCmd,
            subCmd: built.subCmd,
            clientIdMs: cid,
            frameSize: frame.frameSize,
            cryptKeySha256_8: session.cryptKeySha256_8,
            serverErrorCode: evaluated.serverErrorCode,
            serverGlobalMsgId: evaluated.serverGlobalMsgId
        )
    }

    public func sendToMe(
        text: String,
        dryRun: Bool = true,
        clientIdMs: Int64? = nil
    ) async throws -> ZolaSendReceipt {
        try await sendText1To1(to: session.sendToMeId, text: text, dryRun: dryRun, clientIdMs: clientIdMs)
    }

    /// Sends a native 1-1 sticker frame (`cmd = 130, innerCmd = 113, subCmd = 36`) over HTTP/2 failover.
    public func sendSticker1To1(
        to toId: Int64,
        stickerId: Int32,
        cateId: Int32 = 10425,
        stickerType: Int8 = 7,
        quote: ZolaQuote? = nil,
        dryRun: Bool = true,
        clientIdMs: Int64? = nil,
        trackingIdHex: String? = nil
    ) async throws -> ZolaSendReceipt {
        try assertSessionAlive()
        if knownGroupIds().contains(toId) {
            throw ZolaError.groupSendNotSupportedOverHttp
        }
        guard stickerId > 0 else {
            throw ZolaError.invalidArgument("stickerId must be positive")
        }
        let cid = clientIdMs ?? Int64(Date().timeIntervalSince1970 * 1000)
        let desId64 = (toId == session.uid) ? session.sendToMeId : toId
        let hasCk = !session.cryptKey.isEmpty
        let built = ZolaCrypto.buildStickerMsgBodyData(
            stickerId: stickerId,
            cateId: cateId,
            stickerType: stickerType,
            quote: quote,
            includeIOSProps: hasCk,
            trackingIdHex: trackingIdHex,
            clientIdMs: cid
        )
        return try await executeFailoverSend(
            desId64: desId64,
            cid: cid,
            innerCmd: built.innerCmd,
            subCmd: built.subCmd,
            bodyData: built.bodyData,
            dryRun: dryRun
        )
    }

    /// Sends a native 1-1 media / voice / reaction / call-bubble frame (`cmd = 130, innerCmd = 113, subCmd = 31|32|36|37|38|44|46|49|55`) over HTTP/2 failover.
    public func sendMedia1To1(
        to toId: Int64,
        subCmd: Int8,
        href: String = "",
        thumb: String = "",
        title: String = "",
        description: String = "",
        action: String = "",
        param: String = "",
        caption: String = "",
        childnum: Int16 = 0,
        quote: ZolaQuote? = nil,
        includeIOSPropsOverride: Bool? = nil,
        dryRun: Bool = true,
        clientIdMs: Int64? = nil,
        trackingIdHex: String? = nil,
        extraDataJSON: String? = nil
    ) async throws -> ZolaSendReceipt {
        try assertSessionAlive()
        if knownGroupIds().contains(toId) {
            throw ZolaError.groupSendNotSupportedOverHttp
        }
        let cid = clientIdMs ?? Int64(Date().timeIntervalSince1970 * 1000)
        let desId64 = (toId == session.uid) ? session.sendToMeId : toId
        let includeProps = includeIOSPropsOverride ?? !session.cryptKey.isEmpty
        // `ZALinkSendModel` (`0x100b7e1e0`) always passes `message = @""` into `createMediaChatEntity:`;
        // media captions belong in `description` so `createMesageData:` (`0x103b8fd20`) length-prefixes every field.
        let resolvedDescription = description.isEmpty ? caption : description
        let built = ZolaCrypto.buildMediaMsgBodyData(
            subCmd: subCmd,
            message: "",
            title: title,
            description: resolvedDescription,
            href: href,
            thumb: thumb,
            childnum: childnum,
            action: action,
            param: param,
            quote: quote,
            includeIOSProps: includeProps,
            trackingIdHex: trackingIdHex,
            clientIdMs: cid,
            extraDataJSON: extraDataJSON
        )
        return try await executeFailoverSend(
            desId64: desId64,
            cid: cid,
            innerCmd: built.innerCmd,
            subCmd: built.subCmd,
            bodyData: built.bodyData,
            dryRun: dryRun
        )
    }

    /// Appends `/<fileName>` onto extensionless Zalo Multimedia CDN (`*.dlmd.me`) URLs so
    /// official Zalo iOS/macOS (`AVURLAsset` / `FigAssetCreateWithURL`) recognizes the ADTS `.aac`
    /// container and never fails with `AVErrorFileFormatNotRecognized` (`-11828` / `err=-12847`).
    public static func ensureAudioPathExtension(_ rawUrl: String, fileName: String = "voice.aac") -> String {
        let trimmed = rawUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var comps = URLComponents(string: trimmed) else {
            return trimmed
        }
        let host = (comps.host ?? "").lowercased()
        // Voice CDN hosts that may serve extensionless paths: `*.dlmd.me` and `voice-*.zadn.vn`.
        let isVoiceCdn = host == "dlmd.me" || host.hasSuffix(".dlmd.me")
            || (host.hasPrefix("voice-") && (host == "zadn.vn" || host.hasSuffix(".zadn.vn")))
        guard isVoiceCdn else {
            return trimmed
        }
        let currentPath = comps.path
        let lastSegment = (currentPath as NSString).lastPathComponent
        if !(lastSegment as NSString).pathExtension.isEmpty {
            return trimmed
        }
        let rawLeaf = (fileName.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).lastPathComponent
        let sanitizedLeaf = rawLeaf
            .replacingOccurrences(of: "/", with: "")
            .replacingOccurrences(of: "?", with: "")
            .replacingOccurrences(of: "#", with: "")
        let finalLeaf: String
        if sanitizedLeaf.isEmpty {
            finalLeaf = "voice.aac"
        } else if (sanitizedLeaf as NSString).pathExtension.isEmpty {
            finalLeaf = "\(sanitizedLeaf).aac"
        } else {
            finalLeaf = sanitizedLeaf
        }
        let basePath = currentPath.hasSuffix("/") ? String(currentPath.dropLast()) : currentPath
        comps.path = "\(basePath)/\(finalLeaf)"
        return comps.string ?? "\(trimmed)/\(finalLeaf)"
    }

    /// Sends a native 1-1 voice message (`cmd = 130, innerCmd = 113, subCmd = 31` `chat.voice`)
    /// matching Zalo iOS `261002` `+[ChatSocketCmdHelper getSubCmdType:]` (`0x100c8c384`) and
    /// `-[RichMessageContent _getParamForAudio]` (`0x100d9608c`).
    public func sendVoice1To1(
        to toId: Int64,
        voiceUrl: String,
        durationMs: Int,
        fileSize: Int = 0,
        fileExt: String = "aac",
        m4aUrl: String = "",
        waveformSamples: [Int]? = nil,
        quote: ZolaQuote? = nil,
        dryRun: Bool = true,
        clientIdMs: Int64? = nil,
        trackingIdHex: String? = nil
    ) async throws -> ZolaSendReceipt {
        let rawTrimmedUrl = voiceUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawTrimmedUrl.isEmpty else {
            throw ZolaError.invalidArgument("voiceUrl must not be empty")
        }
        let cleanExt = fileExt.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        let fallbackLeaf = "voice.\(cleanExt.isEmpty ? "aac" : cleanExt)"
        let trimmedUrl = Self.ensureAudioPathExtension(rawTrimmedUrl, fileName: fallbackLeaf)
        let safeDuration = max(1_000, durationMs)
        let rawM4a = m4aUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedM4a = rawM4a.isEmpty
            ? trimmedUrl
            : Self.ensureAudioPathExtension(rawM4a, fileName: fallbackLeaf)
        var paramObj: [String: Any] = [
            "duration": safeDuration,
            "m4a": resolvedM4a,
        ]
        if fileSize > 0 {
            paramObj["fileSize"] = fileSize
        }
        if let waveformSamples, !waveformSamples.isEmpty {
            paramObj["waveformSamples"] = waveformSamples
        }
        let paramData = (try? JSONSerialization.data(withJSONObject: paramObj, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        let paramJson = String(decoding: paramData, as: UTF8.self)
        return try await sendMedia1To1(
            to: toId,
            subCmd: ZolaConstants.subCmdSendVoice,
            href: trimmedUrl,
            thumb: "",
            title: "",
            description: "",
            action: "chat.voice",
            param: paramJson,
            caption: "",
            quote: quote,
            dryRun: dryRun,
            clientIdMs: clientIdMs,
            trackingIdHex: trackingIdHex
        )
    }

    /// Longer than `sendAndWait`'s default: this is the only proof of delivery for the message.
    private static let groupTextAckTimeoutSeconds: Double = 8.0
    /// Group chat send commands the app's `checkValidResult:` accepts a confirmation for.
    static let groupTextAckCmds: Set<Int16> = [201, 204, 205, 207]

    /// Sends native group text over the authenticated `UXChatSocket` (`0x7d0`): `cmd = 207` when the body
    /// carries TLV properties (`mentions` tag 11, `quote` tag 2), plain `cmd = 201` otherwise (`0x100b7aeac`,
    /// `0x100c87208`). `mentions` use UTF-16 offsets. Success requires the `msgType = 4` confirmation for this
    /// `seqId` (`checkValidResult:` `0x100b86a6c`); a timeout throws and the delivery state stays unknown.
    public func sendGroupText(
        gid: Int64,
        text: String,
        mentions: [ZolaMention] = [],
        quote: ZolaQuote? = nil,
        dryRun: Bool = true,
        clientIdMs: Int64? = nil
    ) async throws -> ZolaSendReceipt {
        try assertSessionAlive()
        let cid = clientIdMs ?? Int64(Date().timeIntervalSince1970 * 1000)
        let preview = try buildGroupSendSocketFrame(gid: gid, text: text, mentions: mentions, quote: quote, clientIdMs: cid)
        let built = try ZolaCrypto.buildTextMsgBodyData(text: text, isGroup: true, quote: quote, mentions: mentions)
        let cmd = built.innerCmd
        let subCmd = built.subCmd
        let endpoint = "UXChatSocket:\(cmd)"

        guard !dryRun else {
            return ZolaSendReceipt(
                ok: true,
                dryRun: true,
                sent: false,
                endpoint: endpoint,
                uid: session.uid,
                desId: gid,
                cmd: cmd,
                innerSocketCmd: cmd,
                subCmd: subCmd,
                clientIdMs: cid,
                frameSize: preview.frameSize,
                cryptKeySha256_8: session.cryptKeySha256_8
            )
        }

        #if canImport(Network)
        let handedOff = ZolaHandOffFlag()
        let ack: ZolaUnpackedChatElement
        do {
            ack = try await withAuthenticatedChatSocket { sock in
                let seq = await sock.nextSeqId()
                let frame = try buildGroupSendSocketFrame(
                    gid: gid,
                    text: text,
                    mentions: mentions,
                    quote: quote,
                    seqId: seq,
                    clientIdMs: cid
                )
                return try await sock.sendAndWait(
                    rawPayload: frame.payload,
                    expectedCmd: cmd,
                    timeoutSeconds: Self.groupTextAckTimeoutSeconds,
                    ackSeqId: seq,
                    ackCmds: Self.groupTextAckCmds,
                    onHandedToNetwork: { handedOff.set() }
                )
            }
        } catch {
            throw Self.groupSendFailure(error, handedOff: handedOff.isSet)
        }

        let evaluated = try evaluateGroupTextAck(ack)
        return ZolaSendReceipt(
            ok: evaluated.ok,
            dryRun: false,
            sent: true,
            endpoint: endpoint,
            uid: session.uid,
            desId: gid,
            cmd: cmd,
            innerSocketCmd: cmd,
            subCmd: subCmd,
            clientIdMs: cid,
            frameSize: preview.frameSize,
            cryptKeySha256_8: session.cryptKeySha256_8,
            serverErrorCode: evaluated.serverErrorCode
        )
        #else
        throw ZolaError.transport("Nền tảng hiện tại không hỗ trợ Network.framework cho gửi tin nhóm qua UXChatSocket")
        #endif
    }

    /// Session expiry keeps its own type so the circuit breaker still runs; anything else says whether the frame
    /// had reached `conn.send` (delivery unknown) or not (nothing left the phone).
    static func groupSendFailure(_ error: Error, handedOff: Bool) -> Error {
        if let zolaErr = error as? ZolaError, case .sessionExpired = zolaErr {
            return zolaErr
        }
        let underlying = (error as? ZolaError) ?? .transport(error.localizedDescription)
        return ZolaGroupSendError(delivery: handedOff ? .unconfirmed : .notSent, underlying: underlying)
    }

    #if canImport(Network)
    /// Only `msgType = 4` counts as delivered (`checkValidResult:` `0x100b86a6c`). The app ignores `retCode` here;
    /// we fail closed on it, and `102`/`-96` latch the circuit breaker before rethrowing `sessionExpired`.
    internal func evaluateGroupTextAck(_ ack: ZolaUnpackedChatElement) throws -> (ok: Bool, serverErrorCode: Int?) {
        do {
            _ = try parseChatSocketResponse(ack)
        } catch let ZolaError.server(code, _) {
            return (false, code)
        }
        return (ack.msgType == 4, nil)
    }
    #endif

    /// Compatibility entry point; routes through the verified native201/207 group-media path.
    public func sendVoiceGroup(
        gid: Int64,
        voiceUrl: String,
        durationMs: Int,
        fileSize: Int = 0,
        m4aUrl: String = "",
        waveformSamples: [Int]? = nil,
        quote: ZolaQuote? = nil,
        dryRun: Bool = true,
        groupSendEnabled: Bool = false,
        clientIdMs: Int64? = nil
    ) async throws -> ZolaSendReceipt {
        try await sendGroupVoice(gid: gid, voiceUrl: voiceUrl, durationMs: durationMs,
            fileSize: fileSize, m4aUrl: m4aUrl, waveformSamples: waveformSamples,
            quote: quote, dryRun: dryRun, groupSendEnabled: groupSendEnabled, clientIdMs: clientIdMs)
    }

    /// Pure-HTTP Zalo iOS Native pre-upload + `ZaloUploadHTTPBackground` upload (`0x103aa8ed0` + `0x103b6a9c8` + `0x103b640fc` + `0x103b65764`).
    /// Never opens `UXSocket` (`2001` or `1`). Ordinary upload errors preserve the session;
    /// native expiry codes 102/-96 latch the session circuit breaker before any fallback.
    public func uploadMediaNativeHTTP(
        fileData: Data,
        fileName: String,
        toId: Int64,
        isGroup: Bool = false,
        uploadFeature: Int? = nil,
        cliFileId: Int32? = nil,
        width: Int = 0,
        height: Int = 0
    ) async throws -> [String: Any] {
        try assertSessionAlive()
        guard !fileData.isEmpty else {
            throw ZolaError.invalidArgument("fileData must not be empty")
        }
        guard !session.sessionKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ZolaError.invalidArgument("sessionKey must not be empty")
        }

        let resolvedDestId = (!isGroup && toId == session.uid) ? session.sendToMeId : toId
        let destId32 = Int32(truncatingIfNeeded: resolvedDestId)
        // ZAUploadModel → UploadItem+0x250 → HTTP formatter preserves native recipient types.
        let destType = isGroup ? 6 : 3
        let ext = (fileName as NSString).pathExtension.lowercased()
        let feature: Int
        if let uploadFeature {
            feature = uploadFeature
        } else if ["jpg", "jpeg", "png", "webp", "heic", "gif"].contains(ext) {
            feature = isGroup ? 4 : 0
        } else {
            // URL-based chat assets use feature 2 for audio, video and documents.
            // Native video 752/sub9 maps 2 for both recipient kinds; feature 3/cmd1600
            // belongs to Feed uploads and returns media_id instead of a chat URL.
            feature = 2
        }

        let rawFileId = cliFileId ?? Int32(truncatingIfNeeded: (Int64(Date().timeIntervalSince1970 * 1000) & 0x7FFF_FFFF))
        let safeCliFileId = rawFileId > 0 ? rawFileId : 1_000_001
        let safeExt = ext.isEmpty ? "dat" : ext
        let canonicalName = fileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "\(ZolaCrypto.md5Hex(fileData)).\(safeExt)"
            : fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        let encodedName = ZolaRequestBuilder.urlEncode(canonicalName)

        let configBase: String = {
            if let overrideUrl = session.serviceHosts?["upload_config"],
               !overrideUrl.isEmpty,
               !Self.isForbiddenWebWpaURL(overrideUrl) {
                return overrideUrl
            }
            if let cached = cachedUploadConfigURL, !cached.isEmpty {
                return cached
            }
            return ZolaConstants.defaultUploadConfigURL
        }()

        let sep = configBase.contains("?") ? "&" : "?"
        let preUploadURLStr = "\(configBase)\(sep)clientType=\(ZolaConstants.clientTypeIOS)&clientVersion=\(ZolaConstants.clientVersionIOS)&uploadFeature=\(feature)&numOfFiles=0&subCmd=10&key=\(safeCliFileId)&httpVer=1&destId=\(destId32)&destType=\(destType)&fileSize=\(Int64(fileData.count))&cliFileId=\(safeCliFileId)&fileName=\(encodedName)&width=\(width)&height=\(height)"
        guard let preUploadURL = URL(string: preUploadURLStr) else {
            throw ZolaError.invalidArgument("Invalid native pre-upload URL")
        }

        var preReq = URLRequest(url: preUploadURL)
        preReq.httpMethod = "GET"
        preReq.setValue("*/*", forHTTPHeaderField: "Accept")
        preReq.setValue(ZolaConstants.userAgentUXHttp, forHTTPHeaderField: "User-Agent")
        preReq.setValue(session.sessionKey, forHTTPHeaderField: "session_key")
        ZolaRequestBuilder.applySessionBoxHeaders(&preReq, session: session, urlString: preUploadURLStr)

        let (preStatus, preRaw) = try await executeNativeUploadRequest(preReq, stage: "upload/config")
        let preParsed = Self.unwrapUploadEnvelope(preRaw, zcid: session.zcid)
        let preCode = preParsed["error_code"] != nil ? ZolaJSON.int(preParsed["error_code"]) : (preStatus == 200 ? 0 : preStatus)
        if preCode != 0 {
            let msg = ZolaJSON.string(preParsed["error_message"] ?? preParsed["errMessage"])
            throw ZolaError.server(code: preCode, message: msg.isEmpty ? "Pre-upload config failed (HTTP \(preStatus))" : msg)
        }

        let targetUrls = Self.extractPreUploadUrls(from: preParsed).filter {
            !$0.isEmpty && !Self.isForbiddenWebWpaURL($0)
        }
        guard !targetUrls.isEmpty else {
            throw ZolaError.transport("Máy chủ Zalo không trả về đường dẫn tải lên (listUrls rỗng)")
        }

        let crcVal = ZolaCrypto.crc32(fileData)
        let strippedZcid = session.zcid.hasPrefix("1_") ? String(session.zcid.dropFirst(2)) : session.zcid
        let useRawPrimary = fileData.count < 2 * 1024 * 1024

        var lastError: Error?
        for toHost in targetUrls {
            if useRawPrimary, let hostURL = URL(string: toHost) {
                var rawReq = URLRequest(url: hostURL)
                rawReq.httpMethod = "POST"
                rawReq.httpBody = fileData
                rawReq.setValue("raw", forHTTPHeaderField: "Content-Type")
                rawReq.setValue(String(fileData.count), forHTTPHeaderField: "Content-Length")
                rawReq.setValue("close", forHTTPHeaderField: "Connection")
                rawReq.setValue(session.sessionKey, forHTTPHeaderField: "session_key")
                if !strippedZcid.isEmpty {
                    rawReq.setValue(strippedZcid, forHTTPHeaderField: "zcid")
                }
                rawReq.setValue("v2", forHTTPHeaderField: "v")
                rawReq.setValue(ZolaConstants.userAgentUXHttp, forHTTPHeaderField: "User-Agent")
                // `-[ZaloUploadHTTPBackground uploadFile:...]` (`0x103b6ac04`–`0x103b6ad20`) always sends `x-md-hv: f=1; v=<crc32>`
                rawReq.setValue("f=1; v=\(crcVal)", forHTTPHeaderField: "x-md-hv")
                ZolaRequestBuilder.applySessionBoxHeaders(&rawReq, session: session, urlString: toHost)

                do {
                    let (upStatus, upRaw) = try await executeNativeUploadRequest(rawReq, stage: "upload/raw")
                    if let normalized = Self.normalizeCompletedUploadPayload(
                        rawData: upRaw,
                        httpStatus: upStatus,
                        zcid: session.zcid,
                        cliFileId: safeCliFileId
                    ) {
                        return normalized
                    }
                } catch {
                    if case ZolaError.sessionExpired = error { throw error }
                    lastError = error
                }
            }

            // `UploadChunk` (`0x103b65764` + `0x103b60a74`, boundary `ZiNgMeMoBiLe`). Native `uploadFile:`
            // (`0x103b6ab60`) splits files into 2 MB chunks (`0x200000`, overridable per upload item):
            // `total_chunk = ceil(size / chunkSize)`, `chunk_id = offset / chunkSize + 1` (`0x103b65a3c`–`0x103b65a44`),
            // `crc` = CRC32 of that chunk, while the cached `x-md-hv` header keeps the whole-file CRC.
            // Sending the whole video as one chunk made Zalo answer HTTP 413.
            let chunkRanges = Self.nativeUploadChunkRanges(fileSize: fileData.count,
                                                           chunkSize: Self.nativeUploadChunkSize(from: preParsed))
            do {
                var finished: [String: Any]?
                for (index, range) in chunkRanges.enumerated() {
                    let chunk = fileData.subdata(in: range)
                    let chunkReq = try Self.buildNativeUploadChunkRequest(
                        toHost: toHost,
                        chunkData: chunk,
                        fileName: canonicalName,
                        cliFileId: safeCliFileId,
                        chunkId: index + 1,
                        totalChunk: chunkRanges.count,
                        chunkCrc: ZolaCrypto.crc32(chunk),
                        fileCrc: crcVal,
                        session: session
                    )
                    let (chunkStatus, chunkRaw) = try await executeNativeUploadRequest(chunkReq, stage: "upload/chunk")
                    if let normalized = Self.normalizeCompletedUploadPayload(
                        rawData: chunkRaw,
                        httpStatus: chunkStatus,
                        zcid: session.zcid,
                        cliFileId: safeCliFileId
                    ) {
                        finished = normalized
                        break
                    }
                    let env = Self.unwrapUploadEnvelope(chunkRaw, zcid: session.zcid)
                    let cCode = ZolaJSON.int(env["error_code"], default: (200..<300).contains(chunkStatus) ? 0 : chunkStatus)
                    if cCode != 0 || !(200..<300).contains(chunkStatus) {
                        let cMsg = ZolaJSON.string(env["error_message"] ?? env["errMessage"])
                        throw ZolaError.server(code: cCode != 0 ? cCode : chunkStatus,
                                               message: cMsg.isEmpty ? "Upload failed (HTTP \(chunkStatus))" : cMsg)
                    }
                }
                if let finished { return finished }
                lastError = ZolaError.transport("Đã tải hết \(chunkRanges.count) phần nhưng Zalo chưa trả đường dẫn tệp")
            } catch {
                if case ZolaError.sessionExpired = error { throw error }
                lastError = error
            }
        }

        if let lastError { throw lastError }
        throw ZolaError.transport("Không tải được tệp lên máy chủ Zalo iOS Native")
    }

    /// Upload fallback may change encoding/host only for ordinary transport errors.
    /// Session rejection must latch before another raw/chunk request can be issued.
    internal func executeNativeUploadRequest(_ request: URLRequest, stage: String) async throws -> (Int, Data) {
        // Another actor operation/socket callback can expire this session while an upload awaits.
        // Recheck at every request boundary and before consuming a resumed success response.
        try assertSessionAlive()
        do {
            let response = try await executeSessionRequest(request)
            try assertSessionAlive()
            let envelope = Self.unwrapUploadEnvelope(response.1, zcid: session.zcid)
            // unwrapUploadEnvelope also places a bare encrypted response under data. Inspect
            // only these two recognized envelope levels, never arbitrary file/user metadata.
            let codes = [ZolaJSON.int(envelope["error_code"]),
                         ZolaJSON.int((envelope["data"] as? [String: Any])?["error_code"])]
            if let code = codes.first(where: { $0 == 102 || $0 == -96 }) {
                throw ZolaError.sessionExpired(code: code, endpoint: stage, message: "Native upload session rejected")
            }
            return response
        } catch {
            let expiredCode: Int?
            switch error {
            case let ZolaError.sessionExpired(code, _, _): expiredCode = code
            case let ZolaError.server(code, _), let ZolaError.apiError(code, _, _):
                expiredCode = (code == 102 || code == -96) ? code : nil
            default: expiredCode = nil
            }
            if let code = expiredCode {
                let reason = "Native upload session rejected"
                session.markExpired(code: code, reason: reason)
                throw ZolaError.sessionExpired(code: code, endpoint: stage, message: reason)
            }
            throw error
        }
    }

    /// Native default chunk size (`uploadFile:` `0x103b6ab60`: `mov w8, #0x200000`), unless the pre-upload
    /// config names one. Clamped so a bad value can neither explode the request count nor hit HTTP 413 again.
    internal static let nativeDefaultUploadChunkSize = 2 * 1024 * 1024

    internal static func nativeUploadChunkSize(from preUpload: [String: Any]) -> Int {
        let sources: [[String: Any]] = [preUpload, (preUpload["data"] as? [String: Any]) ?? [:]]
        for source in sources {
            for key in ["chunkSize", "chunk_size", "uploadChunkSize", "upload_chunk_size"] {
                let value = ZolaJSON.int(source[key])
                if value > 0 { return min(max(value, 256 * 1024), 8 * 1024 * 1024) }
            }
        }
        return nativeDefaultUploadChunkSize
    }

    /// Byte ranges for chunk ids 1...N (`total_chunk = ceil(size / chunkSize)`).
    internal static func nativeUploadChunkRanges(fileSize: Int, chunkSize: Int) -> [Range<Int>] {
        guard fileSize > 0 else { return [] }
        let size = max(1, chunkSize)
        return stride(from: 0, to: fileSize, by: size).map { $0..<min($0 + size, fileSize) }
    }

    internal static func buildNativeUploadChunkRequest(
        toHost: String,
        chunkData fileData: Data,
        fileName: String,
        cliFileId: Int32,
        chunkId: Int,
        totalChunk: Int,
        chunkCrc: UInt32,
        fileCrc crc: UInt32,
        session: ZolaSession
    ) throws -> URLRequest {
        guard totalChunk >= 1, (1...totalChunk).contains(chunkId) else {
            throw ZolaError.invalidArgument("Invalid UploadChunk id \(chunkId)/\(totalChunk)")
        }
        let inner: [String: Any] = [
            "api_key": session.apiKey,
            "session_key": session.sessionKey,
            "client_type": ZolaConstants.clientTypeIOS,
            "client_version": ZolaConstants.clientVersionIOS,
            "client_file_id": Int(cliFileId),
            "total_chunk": totalChunk,
            "chunk_id": chunkId,
            "crc": Int64(chunkCrc),
        ]
        let encHex = try ZolaCrypto.encryptZCIDParams(inner, zcid: session.zcid)
        var outer: [String: String] = [
            "api_key": session.apiKey,
            "data": encHex,
            "encryptParams": "1",
        ]
        outer["sig"] = ZolaCrypto.makeSignature(params: outer, apiSecret: session.apiSecret)
        let qs = ZolaRequestBuilder.formEncode(outer)
        let sep = toHost.contains("?") ? "&" : "?"
        let fullURLStr = "\(toHost)\(sep)\(qs)"
        guard let url = URL(string: fullURLStr) else {
            throw ZolaError.invalidArgument("Invalid UploadChunk URL")
        }

        let boundary = "ZiNgMeMoBiLe"
        var body = Data(capacity: fileData.count + 256)
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n".utf8))
        body.append(Data("Content-Type: application/octet-stream\r\n".utf8))
        body.append(Data("Content-Length: \(fileData.count)\r\n\r\n".utf8))
        body.append(fileData)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        let strippedZcid = session.zcid.hasPrefix("1_") ? String(session.zcid.dropFirst(2)) : session.zcid
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = body
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.setValue(String(body.count), forHTTPHeaderField: "Content-Length")
        req.setValue("2", forHTTPHeaderField: "ApiVer")
        req.setValue(session.sessionKey, forHTTPHeaderField: "session_key")
        req.setValue(strippedZcid, forHTTPHeaderField: "zcid")
        req.setValue("v2", forHTTPHeaderField: "v")
        req.setValue(ZolaConstants.userAgentUXHttp, forHTTPHeaderField: "User-Agent")
        req.setValue("f=1; v=\(crc)", forHTTPHeaderField: "x-md-hv")
        ZolaRequestBuilder.applySessionBoxHeaders(&req, session: session, urlString: fullURLStr)
        return req
    }

    internal static func unwrapUploadEnvelope(_ rawData: Data, zcid: String) -> [String: Any] {
        let unzipped = ZolaRequestBuilder.gunzipDecompress(rawData) ?? rawData
        guard var env = (try? JSONSerialization.jsonObject(with: unzipped)) as? [String: Any] else {
            let plainStr = String(decoding: unzipped, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if !plainStr.isEmpty {
                if let dec = decryptUploadDataString(plainStr, zcid: zcid) {
                    return ["error_code": 0, "data": dec]
                }
                if plainStr.hasPrefix("https://") {
                    return ["error_code": 0, "data": ["url": plainStr]]
                }
            }
            return [:]
        }
        if let dataStr = env["data"] as? String {
            let trimmed = dataStr.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("https://") {
                env["data"] = ["url": trimmed]
            } else if let dec = decryptUploadDataString(trimmed, zcid: zcid) {
                env["data"] = dec
            } else if trimmed.hasPrefix("{"),
                      let jd = trimmed.data(using: .utf8),
                      let parsed = (try? JSONSerialization.jsonObject(with: jd)) as? [String: Any] {
                env["data"] = parsed
            }
        }
        return env
    }

    private static func decryptUploadDataString(_ str: String, zcid: String) -> [String: Any]? {
        guard !str.isEmpty, !zcid.isEmpty else { return nil }
        if let dec = try? ZolaCrypto.decryptZCIDParams(str, zcid: zcid) {
            return dec
        }
        if let ct = Data(base64Encoded: str) {
            if let unz = ZolaRequestBuilder.gunzipDecompress(ct),
               let obj = (try? JSONSerialization.jsonObject(with: unz)) as? [String: Any] {
                return obj
            }
            if ct.count >= 16, ct.count % 16 == 0,
               let key = try? ZolaCrypto.paramKey(zcid: zcid),
               let pt = try? ZolaCrypto.aesCBC(ct, key: key, iv: ZolaCrypto.zeroIV16, decrypt: true, pkcs7Padding: true) {
                if let obj = (try? JSONSerialization.jsonObject(with: pt)) as? [String: Any] {
                    return obj
                }
                let urlText = String(decoding: pt, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                if urlText.hasPrefix("https://") {
                    return ["url": urlText]
                }
            }
        }
        return nil
    }

    internal static func extractPreUploadUrls(from env: [String: Any]) -> [String] {
        var urls: [String] = []
        let candidates: [Any?] = [
            (env["data"] as? [String: Any])?["listUrls"],
            env["listUrls"],
            (env["data"] as? [String: Any])?["urls"],
            ((env["data"] as? [String: Any])?["data"] as? [String: Any])?["listUrls"],
        ]
        for cand in candidates {
            if let arr = cand as? [Any] {
                for item in arr {
                    if let s = item as? String, s.hasPrefix("http") {
                        urls.append(ZolaAttachment.normalizeMediaUrl(s))
                    } else if let d = item as? [String: Any] {
                        let u = ZolaAttachment.normalizeMediaUrl(ZolaJSON.string(d["url"] ?? d["host"] ?? d["uploadUrl"]))
                        if u.hasPrefix("http") { urls.append(u) }
                    }
                }
            }
        }
        if urls.isEmpty, let dataDict = env["data"] as? [String: Any] {
            for k in ["url", "uploadUrl", "host"] {
                let u = ZolaAttachment.normalizeMediaUrl(ZolaJSON.string(dataDict[k]))
                if u.hasPrefix("http") { urls.append(u) }
            }
        }
        return urls
    }

    private static func normalizeCompletedUploadPayload(
        rawData: Data,
        httpStatus: Int,
        zcid: String,
        cliFileId: Int32
    ) -> [String: Any]? {
        guard (200..<300).contains(httpStatus) else { return nil }
        let env = unwrapUploadEnvelope(rawData, zcid: zcid)
        if env["error_code"] != nil && ZolaJSON.int(env["error_code"]) != 0 {
            return nil
        }
        let dataDict = (env["data"] as? [String: Any]) ?? env
        if let innerErr = dataDict["error_code"], ZolaJSON.int(innerErr) != 0 {
            return nil
        }
        // Native parseLinkInfo uses url → normal → org; retain normalized app/audio keys first.
        let normalKeys = ["normalUrl", "aac", "voiceUrl", "url", "normal", "org", "hdUrl", "hd", "fileUrl", "href"]
        let m4aKeys = ["m4a", "m4aUrl", "aac", "voiceUrl"]
        let thumbKeys = ["thumbUrl", "thumb", "smallUrl"]
        var resolvedNormalUrl = ""
        var resolvedM4aUrl = ""
        var resolvedThumbUrl = ""

        func scanDict(_ source: [String: Any]) {
            if resolvedNormalUrl.isEmpty {
                for k in normalKeys {
                    let v = ZolaAttachment.normalizeMediaUrl(ZolaJSON.string(source[k]))
                    if v.hasPrefix("https://") {
                        resolvedNormalUrl = v
                        break
                    }
                }
            }
            if resolvedM4aUrl.isEmpty {
                for k in m4aKeys {
                    let v = ZolaAttachment.normalizeMediaUrl(ZolaJSON.string(source[k]))
                    if v.hasPrefix("https://") {
                        resolvedM4aUrl = v
                        break
                    }
                }
            }
            if resolvedThumbUrl.isEmpty {
                for k in thumbKeys {
                    let v = ZolaAttachment.normalizeMediaUrl(ZolaJSON.string(source[k]))
                    if v.hasPrefix("https://") {
                        resolvedThumbUrl = v
                        break
                    }
                }
            }
        }

        scanDict(dataDict)
        scanDict(env)
        if let nested = dataDict["data"] as? [String: Any] {
            scanDict(nested)
        }
        if resolvedM4aUrl.isEmpty && (resolvedNormalUrl.lowercased().contains(".m4a") || resolvedNormalUrl.lowercased().contains(".aac")) {
            resolvedM4aUrl = resolvedNormalUrl
        }
        let primaryUrl = !resolvedNormalUrl.isEmpty ? resolvedNormalUrl : resolvedM4aUrl
        guard !primaryUrl.isEmpty else { return nil }
        var out = dataDict
        out["fileUrl"] = primaryUrl
        out["url"] = primaryUrl
        if !resolvedNormalUrl.isEmpty {
            out["normalUrl"] = resolvedNormalUrl
        }
        if !resolvedM4aUrl.isEmpty {
            out["m4aUrl"] = resolvedM4aUrl
        }
        if !resolvedThumbUrl.isEmpty {
            out["thumbUrl"] = resolvedThumbUrl
        }
        if out["fileId"] == nil {
            out["fileId"] = dataDict["fileId"] ?? dataDict["clientFileId"] ?? String(cliFileId)
        }
        if out["clientFileId"] == nil {
            out["clientFileId"] = dataDict["clientFileId"] ?? Int(cliFileId)
        }
        return out
    }

    /// Sends a native 1-1 call summary / missed call bubble (`cmd = 130, innerCmd = 113, subCmd = 38`, `action = "recommened.calltime"`).
    public func sendCallBubble1To1(
        to toId: Int64,
        callId: Int32,
        isVideo: Bool = false,
        durationSeconds: Int32 = 0,
        isCaller: Bool = false,
        dryRun: Bool = true,
        clientIdMs: Int64? = nil,
        trackingIdHex: String? = nil
    ) async throws -> ZolaSendReceipt {
        let safeDuration = max(0, durationSeconds)
        let errCode = safeDuration > 0 ? 160 : 162
        let paramJson = #"{"duration":\#(safeDuration),"calltype":\#(isVideo ? 1 : 0),"isCaller":\#(isCaller ? 1 : 0),"errorCode":\#(errCode),"callId":\#(callId)}"#
        return try await sendMedia1To1(
            to: toId,
            subCmd: 38,
            href: "",
            thumb: "",
            title: "sendBubbleMessage",
            description: "",
            action: "recommened.calltime",
            param: paramJson,
            caption: "",
            dryRun: dryRun,
            clientIdMs: clientIdMs,
            trackingIdHex: trackingIdHex
        )
    }

    /// Sends a native 1-1 Zalo Contact Card (`cmd = 130, innerCmd = 113, subCmd = 38`, `action = "recommened.user"`).
    /// Any optional `caption` is embedded directly into the card's `description` + `params.msg` so the recipient always receives it.
    public func sendContactCard1To1(
        to toId: Int64,
        contactUid: Int64,
        contactName: String,
        avatarUrl: String = "",
        phone: String = "",
        caption: String = "",
        quote: ZolaQuote? = nil,
        dryRun: Bool = true,
        clientIdMs: Int64? = nil,
        trackingIdHex: String? = nil
    ) async throws -> ZolaSendReceipt {
        guard contactUid > 0 else {
            throw ZolaError.invalidArgument("contactUid must be positive (\(contactUid))")
        }
        let cleanName = String(contactName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        let resolvedName = cleanName.isEmpty ? "UID \(contactUid)" : cleanName
        let cleanAvatar = ZolaAttachment.normalizeMediaUrl(avatarUrl)
        let cleanPhone = String(phone.trimmingCharacters(in: .whitespacesAndNewlines).prefix(64))
        let cleanCaption = String(caption.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500))
        let resolvedDesc: String
        if !cleanPhone.isEmpty && !cleanCaption.isEmpty {
            resolvedDesc = "\(cleanPhone) · \(cleanCaption)"
        } else if !cleanCaption.isEmpty {
            resolvedDesc = cleanCaption
        } else if !cleanPhone.isEmpty {
            resolvedDesc = cleanPhone
        } else {
            resolvedDesc = "Danh thiếp liên hệ Zalo"
        }
        var paramObj: [String: Any] = [
            "type": 0,
            "uid": String(contactUid),
        ]
        if !cleanPhone.isEmpty {
            paramObj["phone"] = cleanPhone
        }
        if !cleanAvatar.isEmpty {
            paramObj["avatar"] = cleanAvatar
        }
        if !cleanCaption.isEmpty {
            paramObj["msg"] = cleanCaption
        }
        let paramData = (try? JSONSerialization.data(withJSONObject: paramObj, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        let paramJson = String(decoding: paramData, as: UTF8.self)
        return try await sendMedia1To1(
            to: toId,
            subCmd: ZolaConstants.subCmdSendLinkBubble,
            href: String(contactUid),
            thumb: cleanAvatar,
            title: resolvedName,
            description: resolvedDesc,
            action: "recommened.user",
            param: paramJson,
            caption: cleanCaption,
            quote: quote,
            dryRun: dryRun,
            clientIdMs: clientIdMs,
            trackingIdHex: trackingIdHex
        )
    }

    /// Sends a 1-1 Location card over the live-verified `subCmd = 38` (`recommened.link`) channel so official Zalo
    /// clients render a clickable map card with zero risk of unverified `subCmd` `102` session revocation.
    public func sendLocation1To1(
        to toId: Int64,
        latitude: Double,
        longitude: Double,
        title: String = "",
        address: String = "",
        quote: ZolaQuote? = nil,
        dryRun: Bool = true,
        clientIdMs: Int64? = nil,
        trackingIdHex: String? = nil
    ) async throws -> ZolaSendReceipt {
        guard latitude.isFinite, longitude.isFinite, (-90.0...90.0).contains(latitude), (-180.0...180.0).contains(longitude) else {
            throw ZolaError.invalidArgument("Tọa độ vị trí không hợp lệ (\(latitude), \(longitude))")
        }
        let cleanTitle = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        let resolvedTitle = cleanTitle.isEmpty ? "Vị trí hiện tại" : cleanTitle
        let displayCardTitle = resolvedTitle.hasPrefix("📍") ? resolvedTitle : "📍 \(resolvedTitle)"
        let cleanAddress = String(address.trimmingCharacters(in: .whitespacesAndNewlines).prefix(400))
        let resolvedDesc = cleanAddress.isEmpty ? String(format: "%.5f, %.5f", latitude, longitude) : cleanAddress
        let encodedQuery = resolvedTitle.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "Vi+tri"
        let mapsHref = String(format: "https://maps.apple.com/?ll=%.6f,%.6f&q=%@", latitude, longitude, encodedQuery)
        let paramObj: [String: Any] = [
            "lat": latitude,
            "linkTitle": displayCardTitle,
            "lon": longitude,
            "mediaTitle": displayCardTitle,
            "src": "maps.apple.com",
            "type": 0,
        ]
        let paramData = (try? JSONSerialization.data(withJSONObject: paramObj, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        let paramJson = String(decoding: paramData, as: UTF8.self)
        return try await sendMedia1To1(
            to: toId,
            subCmd: ZolaConstants.subCmdSendLinkBubble,
            href: mapsHref,
            thumb: "",
            title: displayCardTitle,
            description: resolvedDesc,
            action: "recommened.link",
            param: paramJson,
            caption: "",
            quote: quote,
            dryRun: dryRun,
            clientIdMs: clientIdMs,
            trackingIdHex: trackingIdHex
        )
    }

    /// Uploads binary media (`.aac` voice note, `.jpg` photo, `.mp4` video) to Zalo's own file
    /// service (`upload-config` + `ZaloUploadHTTPBackground`) to obtain a Zalo-CDN HTTPS URL for native
    /// `subCmd = 31` (`chat.voice`), `subCmd = 32` (`chat.photo`), or `subCmd = 44` (`chat.video.msg`).
    /// External hosting (tmpfiles/catbox) is rejected by Zalo — removed.
    public func uploadMediaForPublicURL(
        data: Data,
        fileName: String,
        mimeType: String,
        threadId: Int64 = 0
    ) async -> String? {
        guard !data.isEmpty else { return nil }
        let toid = threadId > 0 ? threadId : session.sendToMeId
        guard toid > 0 else { return nil }
        do {
            let uploaded = try await uploadAttachment(
                fileName: fileName,
                fileData: data,
                threadId: toid,
                type: .user
            )
            let candidateKeys = ["normalUrl", "hdUrl", "org", "hd", "fileUrl", "url"]
            for key in candidateKeys {
                if let raw = uploaded[key] as? String {
                    let normalized = ZolaAttachment.normalizeMediaUrl(raw)
                    if normalized.hasPrefix("https://") { return normalized }
                }
            }
            if let nested = uploaded["data"] as? [String: Any] {
                for key in candidateKeys {
                    if let raw = nested[key] as? String {
                        let normalized = ZolaAttachment.normalizeMediaUrl(raw)
                        if normalized.hasPrefix("https://") { return normalized }
                    }
                }
            }
            if let extracted = Self.extractUploadedFileURL(uploaded) {
                let normalized = ZolaAttachment.normalizeMediaUrl(extracted)
                if normalized.hasPrefix("https://") { return normalized }
            }
            return nil
        } catch {
            return nil
        }
    }

    private func executeFailoverSend(
        desId64: Int64,
        cid: Int64,
        innerCmd: Int16,
        subCmd: Int8,
        bodyData: Data,
        dryRun: Bool
    ) async throws -> ZolaSendReceipt {
        let (req, frame, endpointBase) = try ZolaRequestBuilder.buildFailoverOctetPOST(
            session: session,
            desId: Int32(truncatingIfNeeded: desId64),
            globalMsgId: cid,
            subCmd: subCmd,
            bodyData: bodyData,
            e2ee: false,
            callIdMs: cid
        )

        if dryRun {
            return ZolaSendReceipt(
                ok: true,
                dryRun: dryRun,
                sent: !dryRun,
                endpoint: endpointBase,
                uid: session.uid,
                desId: desId64,
                cmd: frame.cmd,
                innerSocketCmd: innerCmd,
                subCmd: subCmd,
                clientIdMs: cid,
                frameSize: frame.frameSize,
                cryptKeySha256_8: session.cryptKeySha256_8,
                serverErrorCode: nil
            )
        }

        let (status, ackData) = try await executeSessionRequest(req)
        let decodedAckData = ZolaCrypto.gunzipOrInflate(ackData) ?? ackData
        if let ackJson = try? JSONSerialization.jsonObject(with: decodedAckData) as? [String: Any],
           ackJson["error_code"] != nil
        {
            let code = ZolaJSON.int(ackJson["error_code"])
            if code == ZolaConstants.errorFemcInvalidSession
                || (code == ZolaConstants.errorSessionExpired && subCmd == ZolaConstants.subCmdMcrypt)
            {
                let rawMsg = ZolaJSON.string(ackJson["error_message"])
                let msg = ZolaRequestBuilder.friendlySessionExpiredReason(rawMsg, code: code)
                session.markExpired(code: code, reason: msg)
                throw ZolaError.sessionExpired(code: code, endpoint: "failover/api/message", message: msg)
            }
        }
        let evaluated = Self.evaluateFailoverAck(
            httpStatus: status,
            decodedAckData: decodedAckData,
            clientIdMs: cid
        )
        if status == 200, !session.isExpired, let handler = realtimeEventHandler {
            let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
            for update in ZolaNativeChatSignals.httpDeliveries(decodedAckData, accountUid: session.uid) {
                handler(ZolaEvent(type: "message.delivery", tsMs: nowMs, delivery: update))
            }
        }

        return ZolaSendReceipt(
            ok: evaluated.ok,
            dryRun: false,
            sent: true,
            endpoint: endpointBase,
            uid: session.uid,
            desId: desId64,
            cmd: frame.cmd,
            innerSocketCmd: innerCmd,
            subCmd: subCmd,
            clientIdMs: cid,
            frameSize: frame.frameSize,
            cryptKeySha256_8: session.cryptKeySha256_8,
            serverErrorCode: evaluated.serverErrorCode,
            serverGlobalMsgId: evaluated.serverGlobalMsgId
        )
    }

    /// Evaluates `POST failover.zingmp3.vn/api/message` ACK matching Zalo iOS `261002`
    /// `HttpSendMsgManager` (`0x103b94748`–`0x103b94f60`).
    ///
    /// On live Zalo production, synchronous `cmd = 130` responses return:
    /// `{"error_code": 0, "error_message": "Successful.", "data": {"offline": {"msg": [], "last": ..., "e": 0}, "deliver": {}}}`
    /// where `deliver` is `{}` synchronously (`HttpSendMsgManager` immediately marks `ChatElement` sent on `error_code == 0`).
    /// Conversely, an empty `data: {}` or a `deliver` item with `gmi <= 0` / `error_code != 0` indicates a dropped/rejected
    /// inner frame and yields `ok == false`.
    internal static func evaluateFailoverAck(
        httpStatus: Int,
        decodedAckData: Data,
        clientIdMs: Int64
    ) -> (ok: Bool, serverErrorCode: Int?, serverGlobalMsgId: Int64?) {
        if let ackJson = try? JSONSerialization.jsonObject(with: decodedAckData) as? [String: Any] {
            let rawOuterErr = ackJson["error_code"]
            let hasOuterErr = rawOuterErr != nil && !(rawOuterErr is NSNull) && !Self.isExactZeroErrorValue(rawOuterErr)
            let serverErrCode: Int? = (rawOuterErr != nil && !(rawOuterErr is NSNull))
                ? ZolaJSON.int(rawOuterErr, default: hasOuterErr ? -1 : 0)
                : nil
            guard httpStatus == 200, !hasOuterErr else {
                return (false, serverErrCode, nil)
            }
            let dataDict: [String: Any]? = {
                if let dict = ackJson["data"] as? [String: Any] { return dict }
                if let str = ackJson["data"] as? String,
                   let raw = str.data(using: .utf8),
                   let dict = try? JSONSerialization.jsonObject(with: raw) as? [String: Any]
                {
                    return dict
                }
                return nil
            }()
            guard let dataDict, !dataDict.isEmpty else {
                return (false, serverErrCode, nil)
            }

            let offlineDict: [String: Any]? = {
                if let dict = dataDict["offline"] as? [String: Any] { return dict }
                if let str = dataDict["offline"] as? String,
                   let raw = str.data(using: .utf8),
                   let dict = try? JSONSerialization.jsonObject(with: raw) as? [String: Any]
                {
                    return dict
                }
                return nil
            }()
            if let offlineDict,
               let rawOffErr = offlineDict["e"],
               !(rawOffErr is NSNull),
               !Self.isExactZeroErrorValue(rawOffErr)
            {
                return (false, serverErrCode, nil)
            }

            let deliverDict: [String: Any]? = {
                if let dict = dataDict["deliver"] as? [String: Any] { return dict }
                if let str = dataDict["deliver"] as? String,
                   let raw = str.data(using: .utf8),
                   let dict = try? JSONSerialization.jsonObject(with: raw) as? [String: Any]
                {
                    return dict
                }
                return nil
            }()
            guard let deliverDict else {
                return (offlineDict != nil, serverErrCode, nil)
            }
            if (deliverDict["error_code"] != nil && !(deliverDict["error_code"] is NSNull) && !Self.isExactZeroErrorValue(deliverDict["error_code"]))
                || (deliverDict["e"] != nil && !(deliverDict["e"] is NSNull) && !Self.isExactZeroErrorValue(deliverDict["e"]))
            {
                return (false, serverErrCode, nil)
            }

            let entries: [[String: Any]] = {
                if let arr = deliverDict["data"] as? [[String: Any]] { return arr }
                if let single = deliverDict["data"] as? [String: Any] { return [single] }
                if let arr = deliverDict["msg"] as? [[String: Any]] { return [["msg": arr]] }
                if let single = deliverDict["msg"] as? [String: Any] { return [["msg": [single]]] }
                return []
            }()

            var totalMsgItems = 0
            var hasMatchingCmi = false
            var hasMatchingExplicitZeroErr = false
            var hasMatchingItemErr = false
            for entry in entries {
                let msgList: [[String: Any]]
                if let arr = entry["msg"] as? [[String: Any]] {
                    msgList = arr
                } else if let single = entry["msg"] as? [String: Any] {
                    msgList = [single]
                } else {
                    continue
                }
                for msgItem in msgList {
                    totalMsgItems += 1
                    let cmi = ZolaJSON.int64(msgItem["cmi"] ?? msgItem["cliMsgId"])
                    let itemErr = Self.hasNonZeroItemError(msgItem)
                    if clientIdMs > 0 && cmi == clientIdMs {
                        hasMatchingCmi = true
                        if itemErr {
                            hasMatchingItemErr = true
                        } else if Self.hasExplicitZeroErr(msgItem) {
                            hasMatchingExplicitZeroErr = true
                        }
                    }
                }
            }
            if totalMsgItems == 0 {
                return (offlineDict != nil, serverErrCode, nil)
            }

            // Piggybacked `cmd = 117` delivery queue in `data.deliver` often carries receipts for
            // earlier messages (`cmi != clientIdMs`) in an active chat while our newly sent frame's
            // delivery receipt arrives asynchronously later. Never reject a valid `error_code == 0`
            // + `offline` response or steal another message's `gmi` when `deliver` does not contain
            // `clientIdMs`.
            if clientIdMs > 0 && !hasMatchingCmi {
                return (offlineDict != nil, serverErrCode, nil)
            }
            if hasMatchingItemErr {
                return (false, serverErrCode, nil)
            }

            let deliveredGmi = extractFailoverDeliveredGlobalMsgId(from: ackJson, clientIdMs: clientIdMs)
            if let deliveredGmi {
                return (true, serverErrCode, deliveredGmi)
            }
            // Live `cmd = 117` delivery receipts often report `{"cmi": <cid>, "gmi": null, "sid": <peer>, "err": 0}`
            // while assigning the final positive `gmi` in `femc` / `GetOffline`.
            if clientIdMs > 0 && hasMatchingExplicitZeroErr {
                return (true, serverErrCode, nil)
            }
            return (false, serverErrCode, nil)
        }

        if httpStatus == 200,
           let unpackedAck = try? ZolaCrypto.unpackHttpFailoverFrame(decodedAckData),
           unpackedAck.globalMsgId > 0
        {
            return (true, nil, unpackedAck.globalMsgId)
        }
        return (false, nil, nil)
    }

    /// Parses `data.deliver.data[].msg[]` (`cmi` -> `gmi > 0`) from `POST failover.zingmp3.vn/api/message`
    /// matching Zalo iOS `261002` `HttpSendMsgManager` (`0x103b94ce0`–`0x103b94f60`).
    /// Returns `nil` when Zalo accepts the outer HTTP envelope (`error_code = 0`) without assigning a positive `gmi`
    /// (e.g., dropped/malformed inner `ChatElement`), preventing false-positive `receipt.ok == true`.
    internal static func extractFailoverDeliveredGlobalMsgId(
        from ackJson: [String: Any],
        clientIdMs: Int64
    ) -> Int64? {
        let dataDict: [String: Any]? = {
            if let dict = ackJson["data"] as? [String: Any] { return dict }
            if let str = ackJson["data"] as? String,
               let raw = str.data(using: .utf8),
               let dict = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] {
                return dict
            }
            return nil
        }()
        guard let dataDict else { return nil }

        let deliverDict: [String: Any]? = {
            if let dict = dataDict["deliver"] as? [String: Any] { return dict }
            if let str = dataDict["deliver"] as? String,
               let raw = str.data(using: .utf8),
               let dict = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] {
                return dict
            }
            return nil
        }()
        guard let deliverDict else { return nil }
        if (deliverDict["error_code"] != nil && !(deliverDict["error_code"] is NSNull) && !Self.isExactZeroErrorValue(deliverDict["error_code"]))
            || (deliverDict["e"] != nil && !(deliverDict["e"] is NSNull) && !Self.isExactZeroErrorValue(deliverDict["e"]))
        {
            return nil
        }

        let entries: [[String: Any]] = {
            if let arr = deliverDict["data"] as? [[String: Any]] { return arr }
            if let single = deliverDict["data"] as? [String: Any] { return [single] }
            if let arr = deliverDict["msg"] as? [[String: Any]] { return [["msg": arr]] }
            if let single = deliverDict["msg"] as? [String: Any] { return [["msg": [single]]] }
            return []
        }()
        guard !entries.isEmpty else { return nil }

        var fallbackPositiveGmi: Int64?
        for entry in entries {
            let msgList: [[String: Any]]
            if let arr = entry["msg"] as? [[String: Any]] {
                msgList = arr
            } else if let single = entry["msg"] as? [String: Any] {
                msgList = [single]
            } else {
                continue
            }
            for msgItem in msgList {
                let cmi = ZolaJSON.int64(msgItem["cmi"] ?? msgItem["cliMsgId"])
                let gmi = ZolaJSON.int64(msgItem["gmi"] ?? msgItem["globalMsgId"] ?? msgItem["msgId"])
                let hasItemErr = Self.hasNonZeroItemError(msgItem)
                if clientIdMs > 0 && cmi == clientIdMs {
                    return (!hasItemErr && gmi > 0) ? gmi : nil
                }
                if hasItemErr {
                    continue
                }
                if clientIdMs <= 0, gmi > 0, fallbackPositiveGmi == nil {
                    fallbackPositiveGmi = gmi
                }
            }
        }
        return fallbackPositiveGmi
    }

    private static func isExactZeroErrorValue(_ raw: Any?) -> Bool {
        guard let raw, !(raw is NSNull) else { return false }
        if let n = raw as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return false }
            return n.doubleValue == 0
        }
        if let i = raw as? Int { return i == 0 }
        if let i64 = raw as? Int64 { return i64 == 0 }
        if let s = raw as? String { return s.trimmingCharacters(in: .whitespacesAndNewlines) == "0" }
        return false
    }

    private static func hasNonZeroItemError(_ msgItem: [String: Any]) -> Bool {
        for key in ["error_code", "e", "err"] {
            if let raw = msgItem[key], !(raw is NSNull), !Self.isExactZeroErrorValue(raw) {
                return true
            }
        }
        return false
    }

    private static func hasExplicitZeroErr(_ msgItem: [String: Any]) -> Bool {
        return Self.isExactZeroErrorValue(msgItem["err"])
    }

    public func buildGroupSendSocketFrame(
        gid: Int64,
        text: String,
        mentions: [ZolaMention] = [],
        quote: ZolaQuote? = nil,
        seqId: Int32 = 1,
        clientIdMs: Int64? = nil
    ) throws -> ZolaChatElementFrame {
        guard gid > 0 else {
            throw ZolaError.invalidArgument("gid must be positive")
        }
        guard !text.isEmpty else {
            throw ZolaError.invalidArgument("Group message text must not be empty")
        }
        let cid = clientIdMs ?? Int64(Date().timeIntervalSince1970 * 1000)
        let built = try ZolaCrypto.buildTextMsgBodyData(text: text, isGroup: true, quote: quote, mentions: mentions)
        return ZolaCrypto.packChatElementFrame(
            bodyData: built.bodyData,
            srcId: Int32(truncatingIfNeeded: session.uid),
            srcType: 3,
            msgType: 2,
            cmd: built.innerCmd,
            subCmd: built.subCmd,
            seqId: seqId,
            needAck: 1,
            desId: Int32(truncatingIfNeeded: gid),
            desType: 4,
            globalMsgId: cid
        )
    }

    // MARK: - 4B. `EncryptProtocolVer2` KeySet Refresh (`GET /api/helper/getKeySet?`)

    /// Refreshes `keySetId`/`keySetValue` (+ `aesPublicId`/`aesPrivateId` when returned) consumed by the
    /// socket-channel `EncryptProtocolVer2` layer. Mirrors `StartupFlowManager checkToGetKeySetWithLoginUid:`
    /// (`0x100ebdef8`), which the app invokes when a socket frame returns `retCode = -67`
    /// (`ZolaConstants.errorInvalidSessionKey`). Updates `session` in place — callers persist
    /// Refreshes `EncryptProtocolVer2` key material via Mode 2 `POST <registerHost>/api/helper/getKeySet?`
    /// (`StartupFlowManager getKeySetWithLoginUid:success:failure:` @ `0x1013857e0`, `logQOSRequestId = 10141`).
    /// Concurrent callers share a single in-flight task, and non-latching envelope parsing guarantees
    /// helper errors never poison `session.isExpired` on an active chat session.
    public func fetchKeySet(registerHost: String = ZolaConstants.defaultRegisterHost) async throws -> ZolaKeySet {
        guard !terminalHandoffStarted else {
            throw ZolaError.safetyGate("Phiên đã bàn giao, không được làm mới khoá trên phiên cũ.")
        }
        if let inFlight = pendingKeySetRefreshTask {
            return try await inFlight.value
        }
        let refreshId = UUID()
        let task = Task<ZolaKeySet, Error> {
            try await self.performFetchKeySetWithSingleRetry(registerHost: registerHost)
        }
        pendingKeySetRefreshId = refreshId
        pendingKeySetRefreshTask = task
        defer {
            if pendingKeySetRefreshId == refreshId {
                pendingKeySetRefreshId = nil
                pendingKeySetRefreshTask = nil
            }
        }
        return try await task.value
    }

    private func performFetchKeySetWithSingleRetry(registerHost: String) async throws -> ZolaKeySet {
        do {
            return try await fetchKeySetOnce(registerHost: registerHost)
        } catch {
            if error is CancellationError || Task.isCancelled { throw error }
            if case .safetyGate = error as? ZolaError { throw error }
            if case .invalidArgument = error as? ZolaError { throw error }
            guard !session.isExpired, session.canRefreshKeySet else { throw error }
            return try await fetchKeySetOnce(registerHost: registerHost)
        }
    }

    private func fetchKeySetOnce(registerHost: String) async throws -> ZolaKeySet {
        try assertSessionAlive()
        guard let rawToken = session.accessToken?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawToken.isEmpty,
              let rawPhone = session.loginPhone?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawPhone.isEmpty
        else {
            throw ZolaError.safetyGate(Self.legacyMissingVoipKeySetMessage)
        }
        let phone = (try? ZolaLoginClient.normalizePhone(rawPhone)) ?? rawPhone
        let encryptedToken = try ZolaLoginClient.encryptPhoneBoundValue(rawToken, phone: phone)
        let startingUid = session.uid
        let startingSk = session.sessionKey
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let (imei, platformModel) = ZolaCrypto.extractZCIDIdentity(zcid: session.zcid)
        var ckeysetBytes = [UInt8](repeating: 0, count: 8)
        for i in 0..<4 { ckeysetBytes[i] = UInt8.random(in: 0...255) }

        let inner: [String: Any] = [
            "type": ZolaConstants.clientTypeIOS,
            "client_type": ZolaConstants.clientTypeIOS,
            "client_version": ZolaConstants.clientVersionIOS,
            "distributor": "iAPP",
            "time_zone": "+07:00",
            "language": "vi",
            "user_language": "vi",
            "iso_country_code": "VN",
            "local_time": "\(nowMs).000000",
            "network": 1,
            "operator": "",
            "imei": imei,
            "advertising_id": imei,
            "jailbroken": "0",
            "model": platformModel,
            "zcid": session.zcid,
            "phone_num": phone,
            "token": encryptedToken,
            "ckeyset": Data(ckeysetBytes).base64EncodedString(),
            "protover": "1",
            "api_key": session.apiKey,
            "v": ZolaConstants.apiVersionV3,
            "error_code_fallback": "1",
            "call_id": String(nowMs),
            "encryptParams": true,
        ]
        let req = try ZolaRequestBuilder.buildEncryptedRequest(
            url: "\(registerHost)/api/helper/getKeySet?",
            innerParams: inner,
            session: session,
            method: "POST",
            callIdMs: nowMs
        )
        let (_, raw) = try await executeSessionRequest(req, completingKeyRefresh: true)
        guard session.uid == startingUid, session.sessionKey == startingSk else {
            throw ZolaError.transport("Session changed while refreshing getKeySet")
        }
        guard let env = ZolaRequestBuilder.parseEnvelopeNonLatching(raw, session: session, decryptZCID: true) else {
            throw ZolaError.transport("Non-JSON response on api/helper/getKeySet")
        }
        let errCode = env["error_code"].map { ZolaJSON.int($0) } ?? env["e"].map { ZolaJSON.int($0) } ?? 0
        if errCode == ZolaConstants.errorSessionExpired {
            // `register.zaloapp.com` returns 102 when the login `accessToken` is stale/invalid WITHOUT revoking `session_key`.
            // Clear `accessToken` so we never re-submit it, while keeping the live chat session untouched.
            session.accessToken = nil
            throw ZolaError.safetyGate(Self.legacyMissingVoipKeySetMessage)
        }
        guard errCode == 0 else {
            throw ZolaError.server(code: errCode, message: ZolaJSON.string(env["error_message"] ?? env["errMessage"]))
        }
        let data = env["data"] as? [String: Any] ?? [:]
        let keySetDict = data["keySet"] as? [String: Any] ?? data
        let ksId = ZolaJSON.string(keySetDict["keySetId"] ?? keySetDict["key_set_id"] ?? data["keySetId"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let ksValue = ZolaJSON.string(keySetDict["keySetValue"] ?? keySetDict["key_set_value"] ?? data["keySetValue"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ksId.isEmpty,
              ksId != "0",
              ksId.utf8.count <= 255,
              let decodedKey = Data(base64Encoded: ksValue),
              decodedKey.count == 32
        else {
            throw ZolaError.transport("getKeySet response missing valid 32-byte keySetId/keySetValue")
        }
        #if canImport(Network)
        _ = try ZolaSocketCrypto(keySetId: ksId, keySetValueBase64: ksValue)
        #endif
        session.keySetId = ksId
        session.keySetValue = ksValue
        let aesPub = ZolaJSON.int64(keySetDict["aesPublicId"] ?? data["aesPublicId"])
        let aesPriv = ZolaJSON.int64(keySetDict["aesPrivateId"] ?? data["aesPrivateId"])
        if aesPub >= 1 { session.aesPublicId = aesPub }
        if aesPriv >= 1 { session.aesPrivateId = aesPriv }
        return ZolaKeySet(keySetId: ksId, keySetValue: ksValue, aesPublicId: session.aesPublicId, aesPrivateId: session.aesPrivateId)
    }

    // MARK: - 5. Native Zalo VoIP Signaling → Call/ZolaClient+VoipCall.swift (CALL MODULE, khoá)
    // MARK: - 5B. Persistent VoIP Incoming Listener → Call/ZolaClient+IncomingCallListener.swift (CALL MODULE, khoá)

    // MARK: - 5C. Native `UXChatSocket 0x7d0` chat element processing (chat realtime — dùng chung socket với cuộc gọi đến)

    #if canImport(Network)
    /// Sends initial `UXChatSocket` `GetOffline` (`cmd = 121` 1-1 + `cmd = 224` group, `subCmd = 1`)
    /// once per authenticated `ZolaVoipSocketSession` when `realtimeEventHandler` is bound.
    func requestInitialSocketOfflineDrainIfNeeded(on sock: ZolaVoipSocketSession) async {
        guard realtimeEventHandler != nil, !session.isExpired, await sock.isSocketAlive() else { return }
        let sockObjId = ObjectIdentifier(sock)
        guard lastDrainedSocketObjectId != sockObjId else { return }
        lastDrainedSocketObjectId = sockObjId
        socketOfflineSinglePagesDrained = 0
        socketOfflineGroupPagesDrained = 0

        let srcId = Int32(truncatingIfNeeded: session.uid)
        let seq121 = await sock.nextSeqId()
        let singleFrame = ZolaCrypto.packSocketGetOfflineFrame(
            srcId: srcId,
            lastGlobalMsgId: max(0, watermarks.femcLastGlbId),
            counter: 50,
            isGroup: false,
            subCmd: 1,
            seqId: seq121
        )
        try? await sock.sendFrame(singleFrame)

        let maxGroupGlbId = watermarks.groupCursors.values.map(\.glbMsgId).max() ?? 0
        if maxGroupGlbId > 0 || !knownGroupIds().isEmpty || durableRealtimeMessageHandler != nil {
            let seq224 = await sock.nextSeqId()
            let groupFrame = ZolaCrypto.packSocketGetOfflineFrame(
                srcId: srcId,
                lastGlobalMsgId: max(0, maxGroupGlbId),
                counter: 50,
                isGroup: true,
                subCmd: 1,
                seqId: seq224
            )
            try? await sock.sendFrame(groupFrame)
        }
    }

    private static func isCompressedMagic(_ data: Data) -> Bool {
        guard data.count >= 2 else { return false }
        let b0 = data[data.startIndex]
        let b1 = data[data.index(after: data.startIndex)]
        if b0 == 0x1F && b1 == 0x8B { return true }
        if b0 == 0x78 && (b1 == 0x01 || b1 == 0x5E || b1 == 0x9C || b1 == 0xDA) { return true }
        return false
    }

    private static func isSingleSocketMessageDict(_ dict: [String: Any]) -> Bool {
        if dict["rIcon"] is String, dict["rMsg"] is [Any] { return true }
        if dict["cliMsgId"] != nil || dict["globalMsgId"] != nil || dict["msgId"] != nil || dict["cmi"] != nil || dict["gmi"] != nil {
            return true
        }
        if dict["msg"] is String || dict["content"] is String {
            return true
        }
        if let txt = dict["text"] as? [String: Any], txt["data"] is [String: Any] {
            return true
        }
        if dict["id"] != nil && dict["msgs"] == nil && dict["data"] == nil && dict["lastMsgs"] == nil && dict["list"] == nil {
            return true
        }
        return false
    }

    private static func extractSocketRawMessageDicts(from jsonObj: Any) -> [[String: Any]] {
        if let dict = jsonObj as? [String: Any], isSingleSocketMessageDict(dict) {
            return [dict]
        }
        return extractRawMessageDicts(from: jsonObj)
    }

    func triggerCoalescedSocketWakeupPoll() {
        guard pendingCloudWakeupTask == nil, realtimeEventHandler != nil, !session.isExpired else { return }
        pendingCloudWakeupTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled, let self else { return }
            await self.runCoalescedSocketWakeupPoll()
        }
    }

    private func runCoalescedSocketWakeupPoll() async {
        pendingCloudWakeupTask = nil
        guard let handler = realtimeEventHandler, !session.isExpired else { return }
        if durableRealtimeMessageHandler != nil {
            // HTTP polling commits its own cursors without the socket's durable barrier. A relay
            // therefore catches up through native offline frames, which traverse that barrier.
            if let sock = activeVoipSocket, await sock.isSocketAlive() {
                lastDrainedSocketObjectId = nil
                await requestInitialSocketOfflineDrainIfNeeded(on: sock)
            }
            return
        }
        if let events = try? await pollOnce(includePreload: true, includeOffline: true, emitInitialSnapshot: true) {
            for ev in events {
                handler(ev)
            }
        }
    }

    /// Processes `ChatProcessor` (`0x100a84174` / `0x100a84d48`) push and offline-batch frames on `0x7d0`:
    /// 1) Rejects truncated/corrupt compressed payloads without ACK so Zalo re-delivers cleanly.
    /// 2) Normalizes + deduplicates messages into `watermarks` and persists watermarks to disk.
    /// 3) Emits unseen `ZolaEvent(type: "message.new")` immediately to `realtimeEventHandler`.
    /// 4) Sends `UXChatSocket` Delivered ACK (`cmd = 102` 1-1 or `cmd = 202` group, `subCmd = 3`) so
    ///    the sender's Zalo status advances from `Đã gửi` to `Đã nhận` and offline queues advance.
    private func sendChatSignalPage(_ page: ZolaChatElementFrame, over sock: ZolaVoipSocketSession) async {
        guard !session.isExpired, realtimeEventHandler != nil, await sock.isSocketAlive() else { return }
        try? await sock.sendFrame(page)
    }

    private func persistDurableSocketEvents(_ events: [ZolaEvent], offline: Bool,
                                            socket: ZolaVoipSocketSession) async -> Bool {
        guard let durableHandler = durableRealtimeMessageHandler, !events.isEmpty else { return true }
        do { try await durableHandler(events, offline) } catch { return false }
        guard !Task.isCancelled, !session.isExpired, activeVoipSocket === socket else { return false }
        return await socket.isSocketAlive()
    }

    func handleIncomingChatSocketElement(
        _ element: ZolaUnpackedChatElement,
        fromSocket sock: ZolaVoipSocketSession
    ) async {
        guard !session.isExpired, let handler = self.realtimeEventHandler else { return }

        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let headerErr = Int(element.retCode)
        if headerErr == ZolaConstants.errorSessionExpired
            || headerErr == ZolaConstants.errorFemcInvalidSession
            || headerErr == ZolaConstants.errorInvalidSessionKey
        {
            session.markExpired(code: headerErr, reason: "Session expired on UXChatSocket cmd=\(element.cmd) retCode=\(headerErr)")
            handler(ZolaEvent(type: "session.expired", tsMs: nowMs, errorCode: headerErr))
            await stopVoipIncomingListener()
            return
        }
        guard element.msgType != 4 else { return }

        // Delivery/seen/typing metadata never enters normal-message staging or moves history watermarks.
        if ZolaNativeChatSignals.handles(element.cmd) {
            if let body = try? JSONSerialization.jsonObject(with: element.decodedBodyData) as? [String: Any] {
                let code = ZolaJSON.int(body["error_code"] ?? body["e"], default: 0)
                if [ZolaConstants.errorSessionExpired, ZolaConstants.errorFemcInvalidSession,
                    ZolaConstants.errorInvalidSessionKey].contains(code) {
                    session.markExpired(code: code, reason: "Session expired on native chat signal")
                    handler(ZolaEvent(type: "session.expired", tsMs: nowMs, errorCode: code))
                    await stopVoipIncomingListener()
                    return
                }
            }
            guard let batch = ZolaNativeChatSignals.parse(element, accountUid: session.uid) else { return }
            let deliveries = batch.deliveries.map { ZolaEvent(type: "message.delivery", tsMs: nowMs, delivery: $0) }
            guard await persistDurableSocketEvents(deliveries, offline: true, socket: sock) else { return }
            for event in deliveries { handler(event) }
            if let typing = batch.typing {
                handler(ZolaEvent(type: "conversation.typing", tsMs: nowMs, typing: typing))
            }
            if await sock.isSocketAlive(), !session.isExpired {
                let seq = await sock.nextSeqId()
                if let ack = batch.acknowledgement(srcId: Int32(truncatingIfNeeded: session.uid), seqId: seq) {
                    try? await sock.sendFrame(ack)
                }
                // Native requests the next status page one second later; no history cursor changes.
                if let page = batch.nextPage(srcId: Int32(truncatingIfNeeded: session.uid), seqId: await sock.nextSeqId()) {
                    Task { [weak self] in
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                        guard !Task.isCancelled, let self else { return }
                        await self.sendChatSignalPage(page, over: sock)
                    }
                }
            }
            return
        }

        switch element.cmd {
        case 1991:
            triggerCoalescedSocketWakeupPoll()
            return
        case 601:
            // Native notification ACK, not a group event; never ACK an ACK or wake a poll.
            return
        case 600, 602...605:
            if let body = try? JSONSerialization.jsonObject(with: element.decodedBodyData) as? [String: Any] {
                let code = ZolaJSON.int(body["error_code"] ?? body["e"], default: 0)
                // -67 is refreshable by the authenticated-socket wrapper; do not latch expiry here.
                if [ZolaConstants.errorSessionExpired, ZolaConstants.errorFemcInvalidSession].contains(code) {
                    session.markExpired(code: code, reason: "Session expired on native notification")
                    handler(ZolaEvent(type: "session.expired", tsMs: nowMs, errorCode: code))
                    await stopVoipIncomingListener()
                    return
                }
            }
            guard element.retCode == 0,
                  !(Self.isCompressedMagic(element.bodyData) && element.decodedBodyData == element.bodyData) else { return }
            // Only600/type188 is proven. Other schemas retain the existing catch-up sync.
            let updates = ZolaGroupSystemNotifications.decode(command: element.cmd, decodedBody: element.decodedBodyData)
                .filter { !seenGroupNotificationIDs.contains($0.deduplicationKey) }
            let groupEvents = updates.map { ZolaEvent(type: "group.info.changed", tsMs: nowMs, groupId: $0.groupId) }
            guard await persistDurableSocketEvents(groupEvents, offline: true, socket: sock) else { return }
            for update in updates {
                seenGroupNotificationIDs.append(update.deduplicationKey)
                if seenGroupNotificationIDs.count > 1024 { seenGroupNotificationIDs.removeFirst() }
                handler(ZolaEvent(type: "group.info.changed", tsMs: nowMs, groupId: update.groupId))
            }
            // Replays still need an ACK even when their invalidation was already emitted.
            if !Task.isCancelled, !session.isExpired, await sock.isSocketAlive(),
               let srcId = Int32(exactly: session.uid),
               let ack = ZolaNativeNotificationAcknowledgement.frame(command: element.cmd,
                   decodedBody: element.decodedBodyData, srcId: srcId, seqId: await sock.nextSeqId()) {
                guard !Task.isCancelled, !session.isExpired else { return }
                try? await sock.sendFrame(ack)
            }
            triggerCoalescedSocketWakeupPoll()
            return
        case 101, 113, 121, 201, 224, 1992, 10109, 10207, 10209, 1780, 1782, 1785, 1787:
            break
        default:
            return
        }

        // If `bodyData` carried gzip/zlib magic and `gunzipOrInflate` rejected it (`decodedBodyData == bodyData`),
        // drop without ACK or watermark mutation so Zalo's server re-sends intact data.
        if Self.isCompressedMagic(element.bodyData) && element.decodedBodyData == element.bodyData {
            return
        }
        guard !element.decodedBodyData.isEmpty,
              let jsonObj = try? JSONSerialization.jsonObject(with: element.decodedBodyData)
        else {
            return
        }

        if let topDict = jsonObj as? [String: Any] {
            let errCode = ZolaJSON.int(topDict["error_code"] ?? topDict["e"], default: 0)
            if errCode == ZolaConstants.errorSessionExpired
                || errCode == ZolaConstants.errorFemcInvalidSession
                || errCode == ZolaConstants.errorInvalidSessionKey
            {
                session.markExpired(code: errCode, reason: "Session expired on UXChatSocket cmd=\(element.cmd)")
                handler(ZolaEvent(type: "session.expired", tsMs: nowMs, errorCode: errCode))
                await stopVoipIncomingListener()
                return
            }
        }

        // Native ChatProcessor routes these four commands to processReactionData, not the
        // normal-message pipeline. Their envelope IDs belong to a separate delivery queue.
        if [Int16(1780), 1782, 1785, 1787].contains(element.cmd) {
            await handleIncomingReactionSocketElement(element, json: jsonObj, fromSocket: sock)
            return
        }

        let rawItems = Self.extractSocketRawMessageDicts(from: jsonObj)
        guard !rawItems.isEmpty else { return }

        let isGroupCmd: Bool = {
            switch element.cmd {
            case 201, 224, 1992, 10207, 10209:
                return true
            default:
                return false
            }
        }()
        let isOfflineBatch = (element.cmd == 121 || element.cmd == 224)
        let baseKnownGids = knownGroupIds()

        // Mutate a staging copy of `watermarks` so if disk persistence fails, in-memory `seenIds`
        // is NOT poisoned while UI still receives `emittedEvents` and `102/202` ACK is withheld for server retry.
        var stagedWatermarks = watermarks
        let priorReactionSnapshots = durableRealtimeMessageHandler == nil ? nil : reactionSnapshots
        var emittedEvents: [ZolaEvent] = []
        var ackItems: [[String: Any]] = []
        var maxBatchGlbId: Int64 = 0

        for item in rawItems {
            var enriched = item
            if rawItems.count == 1 {
                if enriched["id"] == nil && enriched["msgId"] == nil && enriched["globalMsgId"] == nil && enriched["gmi"] == nil && element.globalMsgId > 0 {
                    enriched["globalMsgId"] = element.globalMsgId
                }
                if element.msgType != 3 {
                    if enriched["fromU"] == nil && enriched["uidFrom"] == nil && enriched["src"] == nil && enriched["si"] == nil && element.srcId != 0 {
                        enriched["fromU"] = Int64(UInt32(bitPattern: element.srcId))
                    }
                    if enriched["to"] == nil && enriched["idTo"] == nil && enriched["des"] == nil && enriched["di"] == nil && element.desId != 0 {
                        enriched["to"] = Int64(UInt32(bitPattern: element.desId))
                    }
                }
            }

            let txtWrap = enriched["text"] as? [String: Any]
            var inner = (txtWrap?["data"] as? [String: Any]) ?? enriched
            if enriched["fromU"] == nil && inner["fromU"] == nil && inner["uidFrom"] == nil && inner["src"] == nil,
               let siVal = inner["si"] ?? enriched["si"] {
                enriched["fromU"] = siVal
                inner["fromU"] = siVal
            }
            if enriched["to"] == nil && inner["to"] == nil && inner["idTo"] == nil && inner["des"] == nil,
               let diVal = inner["gId"] ?? inner["groupId"] ?? inner["grid"] ?? inner["di"] ?? enriched["gId"] ?? enriched["groupId"] ?? enriched["di"] {
                enriched["to"] = diVal
                inner["to"] = diVal
            }
            if enriched["globalMsgId"] == nil && inner["globalMsgId"] == nil && inner["msgId"] == nil && inner["id"] == nil,
               let gmiVal = inner["gmi"] ?? enriched["gmi"] {
                enriched["globalMsgId"] = gmiVal
                inner["globalMsgId"] = gmiVal
                inner["id"] = gmiVal
            }
            if enriched["cliMsgId"] == nil && inner["cliMsgId"] == nil,
               let cmiVal = inner["cmi"] ?? enriched["cmi"] {
                enriched["cliMsgId"] = cmiVal
                inner["cliMsgId"] = cmiVal
            }
            if var wrap = txtWrap {
                wrap["data"] = inner
                enriched["text"] = wrap
            }

            var effectiveGids = baseKnownGids
            if isGroupCmd {
                let gidCandidate = ZolaJSON.int64(inner["to"] ?? inner["idTo"] ?? inner["des"] ?? inner["gId"] ?? inner["groupId"] ?? enriched["to"])
                if gidCandidate > 0 {
                    effectiveGids.insert(gidCandidate)
                }
            }

            let zm = ZolaMessage.fromRawItem(
                enriched,
                selfUid: session.uid,
                sendToMeId: session.sendToMeId,
                knownGroupIds: effectiveGids,
                cryptKey: session.cryptKey,
                defaultSource: isGroupCmd ? "mfetch" : "socket"
            )
            guard zm.threadId > 0 else { continue }
            harvestSender(zm)
            if !zm.isGroup {
                let peerUid = zm.isSelf ? zm.toId : zm.senderId
                if peerUid > 0, peerUid != session.uid {
                    stagedWatermarks.registerSingles([peerUid])
                }
            }

            let kUnseen = stagedWatermarks.markSeen(Self.dedupeKey(for: zm))
            let hasRealGlb = Self.hasRealServerGlobalId(zm)
            let gUnseen = hasRealGlb ? stagedWatermarks.markSeen("glb:\(zm.id)") : true
            let isUnseen = kUnseen && gUnseen

            if zm.isGroup {
                if hasRealGlb {
                    var cur = stagedWatermarks.groupCursors[zm.threadId] ?? ZolaGroupCursor(glbMsgId: 1, tsJoinGroup: 1)
                    if zm.id > cur.glbMsgId {
                        cur.glbMsgId = zm.id
                        stagedWatermarks.groupCursors[zm.threadId] = cur
                    }
                    maxBatchGlbId = max(maxBatchGlbId, zm.id)
                }
            } else {
                if zm.cliMsgId > stagedWatermarks.femcLastCliId {
                    stagedWatermarks.femcLastCliId = zm.cliMsgId
                }
                if hasRealGlb {
                    stagedWatermarks.femcLastGlbId = max(stagedWatermarks.femcLastGlbId, zm.id)
                    let curSingle = stagedWatermarks.singleCursors[zm.threadId] ?? 1
                    stagedWatermarks.singleCursors[zm.threadId] = max(curSingle, zm.id)
                    maxBatchGlbId = max(maxBatchGlbId, zm.id)
                }
            }

            let reactionUpdates = ZolaReactionUpdate.fromRawItem(enriched, selfUid: session.uid, knownGroupIds: effectiveGids, isGroup: isGroupCmd)
            if !reactionUpdates.isEmpty {
                // Reaction envelopes may reference an already-seen target ID. Actor->emoji assignment
                // is idempotent; message-delivery watermarks must never discard a mutation.
                emittedEvents.append(contentsOf: reactionUpdates.map {
                    ZolaEvent(type: "message.reaction", tsMs: zm.tsMs > 0 ? zm.tsMs : nowMs, reaction: $0)
                })
            } else if let event = messageEvent(zm, isUnseen: isUnseen, nowMs: nowMs) {
                emittedEvents.append(event)
            }

            let explicitGmi = ZolaJSON.int64(
                inner["globalMsgId"] ?? inner["msgId"] ?? inner["id"] ?? inner["gmi"]
                    ?? enriched["globalMsgId"] ?? enriched["msgId"] ?? enriched["id"] ?? enriched["gmi"]
            )
            let fromDI = ZolaJSON.int(inner["fromDI"] ?? enriched["fromDI"], default: 0)
            let isSameDeviceEcho = !isOfflineBatch && zm.senderId == session.uid && fromDI == 0
            if explicitGmi > 0 && !isSameDeviceEcho {
                let cmi = zm.cliMsgId > 0 ? zm.cliMsgId : ZolaJSON.int64(inner["cmi"] ?? enriched["cmi"])
                let tsVal = zm.tsMs > 0 ? zm.tsMs : nowMs
                let defaultItemCmd = isGroupCmd ? 201 : Int(element.cmd == 121 ? 101 : element.cmd)
                let itemCmd = ZolaJSON.int(inner["cmd"] ?? enriched["cmd"], default: defaultItemCmd)
                let rawMt = ZolaJSON.int(inner["cliMsgType"] ?? inner["mt"] ?? enriched["cliMsgType"] ?? enriched["mt"], default: 0)
                let mtVal = rawMt > 0 ? rawMt : max(1, Int(ZolaQuote.wireServerMsgType(forMsgType: zm.msgType, kind: zm.kind)))

                if isGroupCmd {
                    ackItems.append([
                        "gmi": explicitGmi,
                        "cmi": cmi,
                        "fromDI": fromDI,
                        "ts": tsVal,
                        "si": zm.senderId,
                        "cmd": itemCmd,
                        "mt": mtVal,
                        "at": ZolaJSON.int(inner["at"] ?? enriched["at"], default: 3),
                        "di": zm.threadId,
                    ])
                } else {
                    let destUid = zm.toId > 0 ? zm.toId : session.uid
                    ackItems.append([
                        "gmi": explicitGmi,
                        "cmi": cmi,
                        "at": ZolaJSON.int(inner["at"] ?? enriched["at"], default: 5),
                        "fromDI": fromDI,
                        "ts": tsVal,
                        "si": zm.senderId,
                        "cmd": itemCmd,
                        "mt": mtVal,
                        "st": 5,
                        "di": destUid,
                    ])
                }
            }
        }

        let stagedReactionSnapshots = reactionSnapshots
        if let priorReactionSnapshots { reactionSnapshots = priorReactionSnapshots }
        guard await persistDurableSocketEvents(emittedEvents, offline: isOfflineBatch, socket: sock) else { return }
        for ev in emittedEvents {
            handler(ev)
        }

        stagedWatermarks.initialized = true
        var watermarkPersisted = true
        if let url = watermarkFileURL {
            do {
                try ZolaFileSessionStore.saveWatermark(stagedWatermarks, to: url)
            } catch {
                watermarkPersisted = false
            }
        }
        guard watermarkPersisted else {
            // Do not commit `seenIds` or send Delivered ACK when disk persistence failed;
            // live UI already received `emittedEvents` and server will re-deliver cleanly on retry.
            return
        }
        watermarks = stagedWatermarks
        if priorReactionSnapshots != nil { reactionSnapshots = stagedReactionSnapshots }

        let srcId = Int32(truncatingIfNeeded: session.uid)
        if !ackItems.isEmpty, await sock.isSocketAlive() {
            let ackSeq = await sock.nextSeqId()
            if let ackFrame = ZolaCrypto.packSocketDeliveredAckFrame(
                srcId: srcId,
                items: ackItems,
                isGroup: isGroupCmd,
                isSeen: 0,
                seqId: ackSeq
            ) {
                try? await sock.sendFrame(ackFrame)
            }
        }

        if isOfflineBatch, maxBatchGlbId > 0, await sock.isSocketAlive() {
            let hasMoreFlag: Int = {
                guard let topDict = jsonObj as? [String: Any] else { return -1 }
                return ZolaJSON.int(
                    topDict["more"] ?? topDict["hasMore"] ?? (topDict["data"] as? [String: Any])?["more"],
                    default: -1
                )
            }()
            let shouldRequestNextPage = (hasMoreFlag == 1) || (hasMoreFlag == -1 && rawItems.count >= 50)
            if shouldRequestNextPage {
                let drainedPages: Int
                if isGroupCmd {
                    socketOfflineGroupPagesDrained += 1
                    drainedPages = socketOfflineGroupPagesDrained
                } else {
                    socketOfflineSinglePagesDrained += 1
                    drainedPages = socketOfflineSinglePagesDrained
                }
                guard drainedPages <= 200 else {
                    triggerCoalescedSocketWakeupPoll()
                    return
                }
                if drainedPages % 10 == 0 {
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    guard !Task.isCancelled, !session.isExpired, activeVoipSocket === sock, await sock.isSocketAlive() else { return }
                }
                let nextSeq = await sock.nextSeqId()
                let nextFrame = ZolaCrypto.packSocketGetOfflineFrame(
                    srcId: srcId,
                    lastGlobalMsgId: maxBatchGlbId,
                    counter: 50,
                    isGroup: isGroupCmd,
                    subCmd: 0,
                    seqId: nextSeq
                )
                try? await sock.sendFrame(nextFrame)
            }
        }
    }

    /// IPA 26.10.02: ChatDataManager.processReactionData (0x100947544),
    /// ackReactionMsgs (0x100947fbc). Do not advance chat cursors or emit placeholder messages.
    private func handleIncomingReactionSocketElement(
        _ element: ZolaUnpackedChatElement,
        json: Any,
        fromSocket sock: ZolaVoipSocketSession
    ) async {
        guard element.retCode == 0,
              let root = json as? [String: Any],
              ZolaJSON.int(root["error_code"] ?? root["e"], default: 0) == 0,
              let items = root["msg"] as? [[String: Any]],
              let handler = realtimeEventHandler else { return }
        let isGroup = element.cmd == 1785 || element.cmd == 1787
        var envelopeIDs: [Int64] = []
        var events: [ZolaEvent] = []
        for item in items {
            guard let text = item["text"] as? [String: Any],
                  let inner = text["data"] as? [String: Any] else { continue }
            let updates = ZolaReactionUpdate.fromRawItem(item, selfUid: session.uid, isGroup: isGroup)
            guard !updates.isEmpty else { continue }
            let timestamp = ZolaJSON.int64(inner["ts"] ?? inner["timestamp"])
            for update in updates {
                // Replays are intentionally delivered: actor assignment is idempotent and the
                // receiver may need to recover after an interrupted persistence operation.
                events.append(ZolaEvent(type: "message.reaction",
                                  tsMs: timestamp > 0 ? timestamp : Int64(Date().timeIntervalSince1970 * 1000),
                                  reaction: update))
            }
            let envelopeID = ZolaJSON.int64(inner["id"] ?? inner["globalMsgId"] ?? inner["msgId"] ?? inner["gmi"])
            if envelopeID > 0 { envelopeIDs.append(envelopeID) }
        }
        guard await persistDurableSocketEvents(events, offline: true, socket: sock) else { return }
        for event in events { handler(event) }
        guard !envelopeIDs.isEmpty, await sock.isSocketAlive() else { return }
        let sequence = await sock.nextSeqId()
        if let ack = ZolaCrypto.packSocketReactionAckFrame(
            srcId: Int32(truncatingIfNeeded: session.uid), globalMessageIds: envelopeIDs,
            isGroup: isGroup, seqId: sequence
        ) {
            try? await sock.sendFrame(ack)
        }
    }
    #endif

    // MARK: - Native Friend Status (`cmd = 396/4`, `378/1`) & Video Upload/Send (`subCmd = 44`)

    /// Native read-only poll detail (1641), including any voter profiles inside
    /// its identity-bound poll object. Separate1646 enrichment is disabled until
    /// native response correlation is verified; includeVoters cannot bypass this.
    /// See ZolaGroupPollWire for the static binary evidence and exact byte layout.
    public func fetchGroupPoll(pollId: String, groupId: Int64, includeVoters: Bool = false) async throws -> ZolaGroupPollDetail {
        try assertSessionAlive()
        guard groupId > 0, session.zcidIsNative, hasChatSocketEndpoints,
              let srcId = Int32(exactly: session.uid), srcId > 0 else {
            throw ZolaError.safetyGate("Chi tiết bình chọn cần phiên Zalo iOS Native đang hoạt động")
        }
        #if canImport(Network)
        return try await groupPollReadQueue.run { [self] in
            try await self.readGroupPollOnSocket(pollId: pollId, groupId: groupId, includeVoters: includeVoters, srcId: srcId)
        }
        #else
        throw ZolaError.safetyGate("Thiết bị không hỗ trợ kênh Zalo Native")
        #endif
    }

    #if canImport(Network)
    private func readGroupPollOnSocket(pollId: String, groupId: Int64, includeVoters: Bool, srcId: Int32) async throws -> ZolaGroupPollDetail {
        try await withAuthenticatedChatSocket { sock in
            let seq = await sock.nextSeqId()
            let frame = try ZolaGroupPollWire.requestFrame(pollId: pollId, read: .detail, srcId: srcId, seqId: seq)
            let response = try await sock.sendAndWait(rawPayload: frame.payload, expectedCmd: 1641, timeoutSeconds: 6)
            let parsed = try self.parseChatSocketResponse(response)
            // A timed-out1646 response can otherwise satisfy a later cmd-only waiter.
            //1641 carries poll+group identity; never attach an uncorrelated answers array.
            return try ZolaGroupPollWire.detail(from: parsed.data, expectedPollId: pollId, groupId: groupId)
        }
    }
    #endif

    /// Fetches outgoing (sent) friend requests natively over `UXChatSocket` (`cmd = 396, subCmd = 4`).
    public func fetchSentFriendRequests() async throws -> [ZolaFriendRequest] {
        try assertSessionAlive()
        #if canImport(Network)
        if session.zcidIsNative && hasChatSocketEndpoints {
            let srcId = Int32(truncatingIfNeeded: session.uid)
            let rawItems: [ZolaFriendRequest] = try await withAuthenticatedChatSocket { sock in
                let seq = await sock.nextSeqId()
                let frame = ZolaCrypto.packFriendListSentFrame(srcId: srcId, seqId: seq)
                let resp = try await sock.sendAndWait(
                    rawPayload: frame.payload,
                    expectedCmd: ZolaConstants.cmdFriendListSent,
                    timeoutSeconds: 6.0
                )
                let parsed = try self.parseChatSocketResponse(resp, allowedCodes: [Self.noSentRequestsCode])
                guard parsed.code == 0 else { return [] }
                return ZolaFriendRequest.parseSocketSentRequests(parsed.data, accountUid: self.session.uid)
            }
            var enriched: [ZolaFriendRequest] = []
            for var fr in rawItems {
                if fr.displayName == "UID \(fr.uid)" || fr.avatarUrl.isEmpty {
                    if let cached = usersCache[fr.uid], !cached.displayName.isEmpty {
                        fr.displayName = cached.displayName
                        if fr.avatarUrl.isEmpty { fr.avatarUrl = cached.avatarUrl }
                        if fr.phone.isEmpty { fr.phone = cached.phone }
                    } else if let prof = try? await getUserProfile(uid: fr.uid, avatarSize: 120) {
                        fr.displayName = prof.displayName
                        fr.avatarUrl = prof.avatarUrl
                        fr.phone = prof.phone
                    }
                }
                enriched.append(fr)
            }
            return enriched.sorted { $0.timestampMs > $1.timestampMs }
        }
        #endif
        let all = try await fetchFriendRequests()
        return all.filter { $0.direction == .outgoing }
    }

    /// Queries the raw friendship / request status dictionary with `fid` (`UXChatSocket cmd = 378, subCmd = 1`).
    public func fetchFriendRequestStatus(_ fid: Int64) async throws -> [String: Any] {
        try assertSessionAlive()
        guard fid > 0 else { throw ZolaError.invalidArgument("Invalid fid \(fid)") }
        #if canImport(Network)
        if hasChatSocketEndpoints {
            let srcId = Int32(truncatingIfNeeded: session.uid)
            let fid32 = Int32(truncatingIfNeeded: fid)
            return try await withAuthenticatedChatSocket { sock in
                let seq = await sock.nextSeqId()
                let frame = ZolaCrypto.packFriendRequestStatusFrame(
                    srcId: srcId,
                    targetUid: fid32,
                    seqId: seq
                )
                let resp = try await sock.sendAndWait(
                    rawPayload: frame.payload,
                    expectedCmd: ZolaConstants.cmdFriendRequestStatus,
                    timeoutSeconds: 6.0
                )
                return try self.parseChatSocketResponse(resp).data
            }
        }
        #endif
        return try await friendServiceCall(
            "reqstatus",
            params: ["fid": String(fid)],
            method: "GET"
        ).data
    }

    /// Typed 1-1 relationship status with `fid` (`friends`, `incomingRequest`, `outgoingRequest`, `stranger`).
    public func getPeerFriendStatus(_ fid: Int64) async throws -> ZolaPeerFriendStatus {
        let raw = try await fetchFriendRequestStatus(fid)
        let parsed = ZolaPeerFriendStatus.fromServerDict(raw, uid: fid)
        if parsed.isFriend, let existing = usersCache[fid], !existing.isFriend {
            usersCache[fid] = ZolaUser(
                uid: existing.uid,
                displayName: existing.displayName,
                zaloName: existing.zaloName,
                avatarUrl: existing.avatarUrl,
                fullAvatarUrl: existing.fullAvatarUrl,
                phone: existing.phone,
                gender: existing.gender,
                statusText: existing.statusText,
                globalId: existing.globalId,
                isFriend: true
            )
        }
        return parsed
    }

    /// Maximum video upload size over Pure-HTTP (`50 MB`).
    public static let maxVideoUploadBytes = 50 * 1024 * 1024

    /// Probes upright video dimensions, duration (milliseconds), and a first-frame JPEG poster image directly from a local file URL.
    public static func probeVideoFileMetadataAndPoster(
        url: URL
    ) async -> (width: Int, height: Int, durationMs: Int, posterData: Data?) {
        #if canImport(AVFoundation) && canImport(CoreGraphics) && canImport(ImageIO)
        let asset = AVURLAsset(url: url)
        var resolvedW = 720
        var resolvedH = 1280
        var resolvedDurMs = 0

        if let cmDur = try? await asset.load(.duration) {
            let sec = CMTimeGetSeconds(cmDur)
            if sec.isFinite && sec > 0 {
                resolvedDurMs = Int(round(sec * 1000.0))
            }
        }
        if let vTrack = (try? await asset.loadTracks(withMediaType: .video))?.first,
           let natSize = try? await vTrack.load(.naturalSize),
           let transform = try? await vTrack.load(.preferredTransform) {
            let oriented = natSize.applying(transform)
            let w = Int(round(abs(oriented.width)))
            let h = Int(round(abs(oriented.height)))
            if w > 0 && h > 0 {
                resolvedW = w
                resolvedH = h
            }
        }

        var posterJPEG: Data? = nil
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 960, height: 960)
        let sampleSec = resolvedDurMs > 200 ? min(0.15, Double(resolvedDurMs) / 2000.0) : 0.0
        let sampleTime = CMTime(seconds: sampleSec, preferredTimescale: 600)
        let cgImage: CGImage? = await {
            if let img = (try? await generator.image(at: sampleTime))?.image {
                return img
            }
            return (try? await generator.image(at: .zero))?.image
        }()
        if let cgImage {
            if resolvedW <= 0 || resolvedH <= 0 {
                resolvedW = max(1, cgImage.width)
                resolvedH = max(1, cgImage.height)
            }
            let outData = NSMutableData()
            if let dest = CGImageDestinationCreateWithData(outData, "public.jpeg" as CFString, 1, nil) {
                let opts = [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary
                CGImageDestinationAddImage(dest, cgImage, opts)
                if CGImageDestinationFinalize(dest) {
                    posterJPEG = outData as Data
                }
            }
        }
        return (resolvedW, resolvedH, resolvedDurMs, posterJPEG)
        #else
        return (720, 1280, 0, nil)
        #endif
    }

    /// Probes upright video dimensions, duration (milliseconds), and a first-frame JPEG poster image from in-memory `Data`.
    public static func probeVideoMetadataAndPoster(
        videoData: Data,
        fileExtension: String = "mp4"
    ) async -> (width: Int, height: Int, durationMs: Int, posterData: Data?) {
        #if canImport(AVFoundation) && canImport(CoreGraphics) && canImport(ImageIO)
        guard !videoData.isEmpty else { return (720, 1280, 0, nil) }
        let safeExt: String = {
            let trimmed = fileExtension.trimmingCharacters(in: CharacterSet(charactersIn: ". \t\r\n")).lowercased()
            return ["mp4", "mov", "m4v"].contains(trimmed) ? trimmed : "mp4"
        }()
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("zolakit-video-probe-\(UUID().uuidString).\(safeExt)")
        do {
            try videoData.write(to: tempURL, options: .atomic)
        } catch {
            return (720, 1280, 0, nil)
        }
        defer { try? FileManager.default.removeItem(at: tempURL) }
        return await probeVideoFileMetadataAndPoster(url: tempURL)
        #else
        return (720, 1280, 0, nil)
        #endif
    }

    /// Sends a native 1-1 video bubble (`cmd = 130, innerCmd = 113, subCmd = 44`, `action = "chat.video.msg"`)
    /// matching Zalo iOS `261002` `-[RichMessageContent _getParamForVideo]` (`0x100d95bc8`).
    public func sendVideo1To1(
        to toId: Int64,
        videoUrl: String,
        thumbUrl: String = "",
        durationMs: Int,
        width: Int = 720,
        height: Int = 1280,
        rotation: Int = 0,
        fileSize: Int = 0,
        clientFileId: Int32? = nil,
        caption: String = "",
        quote: ZolaQuote? = nil,
        dryRun: Bool = true,
        clientIdMs: Int64? = nil,
        trackingIdHex: String? = nil
    ) async throws -> ZolaSendReceipt {
        let cleanUrl = ZolaAttachment.normalizeMediaUrl(videoUrl.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !cleanUrl.isEmpty, cleanUrl.lowercased().hasPrefix("http") else {
            throw ZolaError.invalidArgument("videoUrl must be a valid HTTP(S) URL")
        }
        let rawThumb = thumbUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedThumb = rawThumb.isEmpty ? "" : ZolaAttachment.normalizeMediaUrl(rawThumb)
        let lowerThumb = normalizedThumb.lowercased()
        let cleanThumb = (lowerThumb.hasSuffix(".mp4") || lowerThumb.hasSuffix(".mov") || lowerThumb.hasSuffix(".m4v"))
            ? ""
            : normalizedThumb

        let safeW = width > 0 ? width : 720
        let safeH = height > 0 ? height : 1280
        let resolvedCliFileId: Int = {
            if let clientFileId, clientFileId > 0 { return Int(clientFileId) }
            let seed = (clientIdMs ?? Int64(Date().timeIntervalSince1970 * 1000)) & 0x7FFF_FFFF
            return max(1_000_001, Int(seed))
        }()
        let paramObj: [String: Any] = [
            "clientFileId": resolvedCliFileId,
            "duration": max(0, durationMs),
            "fileSize": max(0, fileSize),
            "video_height": safeH,
            "video_rotation": rotation,
            "video_width": safeW,
        ]
        let paramData = (try? JSONSerialization.data(withJSONObject: paramObj, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        let paramJson = String(decoding: paramData, as: UTF8.self)
        return try await sendMedia1To1(
            to: toId,
            subCmd: ZolaConstants.subCmdSendVideo,
            href: cleanUrl,
            thumb: cleanThumb,
            title: "",
            description: caption,
            action: "chat.video.msg",
            param: paramJson,
            caption: caption,
            quote: quote,
            dryRun: dryRun,
            clientIdMs: clientIdMs,
            trackingIdHex: trackingIdHex
        )
    }

    /// Uploads a video (`uploadFeature = 2`) + first-frame JPEG poster (`uploadFeature = 0` when needed)
    /// via Zalo iOS Native Pure-HTTP upload and sends `subCmd = 44` (`action = "chat.video.msg"`).
    public func uploadAndSendVideo(
        videoData: Data,
        fileName: String = "",
        posterData: Data? = nil,
        width: Int = 0,
        height: Int = 0,
        durationMs: Int = 0,
        rotation: Int = 0,
        skipAutoPosterProbe: Bool = false,
        threadId: Int64,
        type: ZolaThreadType = .user,
        caption: String = "",
        quote: ZolaQuote? = nil,
        dryRun: Bool = false,
        clientIdMs: Int64? = nil
    ) async throws -> ZolaVideoSendResult {
        try assertSessionAlive()
        guard !videoData.isEmpty else {
            throw ZolaError.invalidArgument("Dữ liệu video đang rỗng (0 byte)")
        }
        guard videoData.count <= Self.maxVideoUploadBytes else {
            throw ZolaError.invalidArgument("Video vượt quá giới hạn an toàn 50 MB trên kênh Pure-HTTP")
        }
        if type == .group || knownGroupIds().contains(threadId) {
            throw ZolaError.groupSendNotSupportedOverHttp
        }

        let rawName = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        let nameExt = (rawName as NSString).pathExtension.lowercased()
        let safeExt = ["mp4", "mov", "m4v"].contains(nameExt) ? nameExt : "mp4"
        let canonicalName = (rawName.isEmpty || rawName == "sendBubbleMessage")
            ? "\(ZolaCrypto.md5Hex(videoData)).\(safeExt)"
            : rawName

        var resolvedW = width
        var resolvedH = height
        var resolvedDurMs = durationMs
        var resolvedPoster = posterData
        if !dryRun && !skipAutoPosterProbe && (resolvedW <= 0 || resolvedH <= 0 || resolvedDurMs <= 0 || resolvedPoster == nil) {
            let probed = await Self.probeVideoMetadataAndPoster(videoData: videoData, fileExtension: safeExt)
            if resolvedW <= 0 { resolvedW = probed.width }
            if resolvedH <= 0 { resolvedH = probed.height }
            if resolvedDurMs <= 0 { resolvedDurMs = probed.durationMs }
            if resolvedPoster == nil { resolvedPoster = probed.posterData }
        }
        if resolvedW <= 0 { resolvedW = 720 }
        if resolvedH <= 0 { resolvedH = 1280 }

        let chosenCliFileId: Int32 = {
            let raw = Int32(truncatingIfNeeded: ((clientIdMs ?? Int64(Date().timeIntervalSince1970 * 1000)) & 0x7FFF_FFFF))
            return raw > 0 ? raw : 1_000_001
        }()

        if dryRun {
            let dryVideoUrl = "https://v24-zpc.zdn.vn/dryrun-\(clientIdMs ?? 0).\(safeExt)"
            let dryThumbUrl = "https://photo-stal-18.zdn.vn/dryrun-thumb-\(clientIdMs ?? 0).jpg"
            let receipt = try await sendVideo1To1(
                to: threadId,
                videoUrl: dryVideoUrl,
                thumbUrl: dryThumbUrl,
                durationMs: resolvedDurMs,
                width: resolvedW,
                height: resolvedH,
                rotation: rotation,
                fileSize: videoData.count,
                clientFileId: chosenCliFileId,
                caption: caption,
                quote: quote,
                dryRun: true,
                clientIdMs: clientIdMs
            )
            return ZolaVideoSendResult(
                videoUrl: dryVideoUrl,
                thumbUrl: dryThumbUrl,
                width: resolvedW,
                height: resolvedH,
                durationMs: resolvedDurMs,
                fileSize: videoData.count,
                posterData: resolvedPoster,
                receipt: receipt
            )
        }

        let uploaded = try await uploadMediaNativeHTTP(
            fileData: videoData,
            fileName: canonicalName,
            toId: threadId,
            isGroup: false,
            uploadFeature: 2,
            cliFileId: chosenCliFileId,
            width: resolvedW,
            height: resolvedH
        )
        let resolvedVideoUrl: String = {
            for key in ["normalUrl", "fileUrl", "url", "hdUrl", "org", "hd", "href"] {
                let candidate = ZolaAttachment.normalizeMediaUrl(ZolaJSON.string(uploaded[key]))
                if candidate.hasPrefix("https://") { return candidate }
            }
            return Self.extractUploadedFileURL(uploaded) ?? ""
        }()
        guard resolvedVideoUrl.hasPrefix("https://") else {
            throw ZolaError.transport(
                "Đã tải video lên Zalo (fileId=\(ZolaJSON.string(uploaded["fileId"]))) nhưng phản hồi không chứa URL video"
            )
        }

        var resolvedThumbUrl: String = {
            for key in ["thumbUrl", "thumb", "smallUrl"] {
                let candidate = ZolaAttachment.normalizeMediaUrl(ZolaJSON.string(uploaded[key]))
                let lower = candidate.lowercased()
                if candidate.hasPrefix("https://")
                    && !lower.hasSuffix(".mp4")
                    && !lower.hasSuffix(".mov")
                    && !lower.hasSuffix(".m4v")
                    && candidate != resolvedVideoUrl {
                    return candidate
                }
            }
            return ""
        }()

        if resolvedThumbUrl.isEmpty, let poster = resolvedPoster, !poster.isEmpty {
            let posterName = "\(ZolaCrypto.md5Hex(poster)).jpg"
            if let uploadedPoster = try? await uploadMediaNativeHTTP(
                fileData: poster,
                fileName: posterName,
                toId: threadId,
                isGroup: false,
                uploadFeature: 0,
                width: resolvedW,
                height: resolvedH
            ) {
                for key in ["thumbUrl", "thumb", "normalUrl", "hdUrl", "fileUrl", "url"] {
                    let candidate = ZolaAttachment.normalizeMediaUrl(ZolaJSON.string(uploadedPoster[key]))
                    if candidate.hasPrefix("https://") {
                        resolvedThumbUrl = candidate
                        break
                    }
                }
            }
        }

        let resolvedSize = max(videoData.count, ZolaJSON.int(uploaded["fileSize"]))
        let serverCliFileId = Int32(truncatingIfNeeded: ZolaJSON.int64(uploaded["clientFileId"], default: Int64(chosenCliFileId)))
        let serverDurMs = ZolaJSON.int(uploaded["duration"])
        let finalDurMs = resolvedDurMs > 0 ? resolvedDurMs : (serverDurMs > 0 && serverDurMs < 500 ? serverDurMs * 1000 : serverDurMs)

        let receipt = try await sendVideo1To1(
            to: threadId,
            videoUrl: resolvedVideoUrl,
            thumbUrl: resolvedThumbUrl,
            durationMs: finalDurMs,
            width: resolvedW,
            height: resolvedH,
            rotation: rotation,
            fileSize: resolvedSize,
            clientFileId: serverCliFileId > 0 ? serverCliFileId : chosenCliFileId,
            caption: caption,
            quote: quote,
            dryRun: false,
            clientIdMs: clientIdMs
        )
        return ZolaVideoSendResult(
            videoUrl: resolvedVideoUrl,
            thumbUrl: resolvedThumbUrl,
            width: resolvedW,
            height: resolvedH,
            durationMs: finalDurMs,
            fileSize: resolvedSize,
            posterData: resolvedPoster,
            receipt: receipt
        )
    }
}

/// Failure of `sendGroupText`. `unconfirmed` means the frame was handed to the socket (or its ACK timed out),
/// so the message may have reached the group and must not be resent automatically.
public struct ZolaGroupSendError: LocalizedError, Sendable, Equatable {
    public enum Delivery: Sendable, Equatable {
        case notSent
        case unconfirmed
    }

    public let delivery: Delivery
    public let underlying: ZolaError

    public init(delivery: Delivery, underlying: ZolaError) {
        self.delivery = delivery
        self.underlying = underlying
    }

    public var errorDescription: String? { underlying.errorDescription }
}

final class ZolaHandOffFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
