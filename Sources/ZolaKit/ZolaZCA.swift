import Foundation

/// Thread type selector for Zalo conversations.
public enum ZolaThreadType: Int, Sendable, Codable, Equatable {
    /// Direct 1-1 user conversation (`0`).
    case user = 0
    /// Multi-member group conversation (`1`).
    case group = 1
}

/// Structured message payload.
/// Supports string literals (`"Xin chào!"`) or structured construction (`ZolaMessagePayload(msg: "Xin chào!", ttl: 0)`).
public struct ZolaMessagePayload: Sendable, Equatable, ExpressibleByStringLiteral {
    public var msg: String
    public var quote: ZolaQuote?
    public var ttl: Int

    public init(msg: String, quote: ZolaQuote? = nil, ttl: Int = 0) {
        self.msg = msg
        self.quote = quote
        self.ttl = ttl
    }

    public init(stringLiteral value: String) {
        self.msg = value
        self.quote = nil
        self.ttl = 0
    }
}

extension ZolaLoginResult {
    /// Converts a successful `ZolaLoginResult` into a ready-to-use `ZolaSession`.
    public func makeSession() throws -> ZolaSession {
        try ZolaSession(
            uid: userId,
            sessionKey: sessionKey,
            cryptKey: cryptKey,
            zcid: zcid,
            zcidIsNative: !zcid.isEmpty,
            sendToMeId: sendToMeId > 0 ? sendToMeId : ZolaConstants.defaultSendToMeId,
            serviceHosts: serviceHosts.isEmpty ? nil : serviceHosts,
            socketServers: socketServers.isEmpty ? nil : socketServers,
            keySetId: keySetId,
            keySetValue: keySetValue,
            aesPublicId: aesPublicId,
            aesPrivateId: aesPrivateId,
            accessToken: token.isEmpty ? nil : token,
            loginPhone: loginPhone
        )
    }
}

/// High-level entry point allowing AI Agents and developers
/// to authenticate and obtain a `ZolaClient` (`api`) instance in a single call.
public struct Zola: Sendable {
    public init() {}

    /// Creates a `ZolaClient` from an already-hydrated `ZolaSession`.
    public func login(
        session: ZolaSession,
        watermarkFileURL: URL? = nil,
        transport: ZolaNetworkTransport? = nil
    ) -> ZolaClient {
        ZolaClient(session: session, watermarkFileURL: watermarkFileURL, transport: transport)
    }

    /// Loads a `ZolaSession` from Apple Keychain (`com.zolakit.session`) and returns a ready `ZolaClient`.
    public func loadKeychainSession(
        uid: Int64,
        service: String = "com.zolakit.session",
        transport: ZolaNetworkTransport? = nil
    ) throws -> ZolaClient {
        let store = ZolaKeychainSessionStore(service: service)
        guard let session = try store.load(account: String(uid)) else {
            throw ZolaError.invalidArgument("No saved Keychain session found for UID \(uid)")
        }
        return ZolaClient(session: session, transport: transport)
    }

    /// Loads a `ZolaSession` from a JSON file (`session-<uid>.local.json`) and returns a ready `ZolaClient`.
    public func loadFileSession(
        url: URL,
        watermarkFileURL: URL? = nil,
        transport: ZolaNetworkTransport? = nil
    ) throws -> ZolaClient {
        let session = try ZolaFileSessionStore.loadInteropJSON(from: url)
        return ZolaClient(session: session, watermarkFileURL: watermarkFileURL, transport: transport)
    }

    /// Authenticates with phone + password via `ZolaLoginClient`.
    public func loginWithPassword(
        phone: String,
        password: String,
        config: ZolaLoginConfig = .init(),
        identity: ZolaDeviceIdentity? = nil,
        transport: ZolaNetworkTransport? = nil
    ) async throws -> ZolaLoginOutcome {
        let auth: ZolaLoginClient
        if let identity {
            auth = ZolaLoginClient(config: config, identity: identity, transport: transport)
        } else {
            let store = ZolaDeviceIdentityStore()
            let resolvedIdentity = await MainActor.run { ZolaDeviceIdentity.currentDevice(store: store) }
            auth = ZolaLoginClient(config: config, identity: resolvedIdentity, identityStore: store, transport: transport)
        }
        return try await auth.login(phone: phone, password: password)
    }
}

// MARK: - Compatible API Surface on ZolaClient

extension ZolaClient {
    /// Default Zalo iOS Native (`261002802`) service hosts from `service_map.bin`.
    /// When the session carries its own service map (`session.serviceHosts`) the
    /// per-account host wins — see `resolvedServiceBaseURL`.
    public static let defaultGroupWpaHost = "https://group.api.zaloapp.com"
    public static let defaultChatWpaHost = "https://failover.zingmp3.vn"
    public static let defaultAliasHost = "https://alias.api.zaloapp.com"
    public static let defaultConversationHost = "https://fe-gr-chat.zalo.me"
    public static let defaultProfileHost = "https://talk-m.zaloapp.com"
    public static let defaultLabelHost = "https://zalo-m.zaloapp.com"
    public static let defaultQuickMsgHost = "https://zalo-m.zaloapp.com"
    public static let defaultAutoReplyHost = "https://zalo-m.zaloapp.com"
    public static let defaultStickerHost = "https://stickers.zaloapp.com"
    public static let defaultReactionHost = "https://reaction.api.zaloapp.com"
    /// Zalo file/photo service host (native service map `file` entry).
    public static let defaultFileWpaHost = "https://photo.api.zaloapp.com"

    /// Returns `true` when `urlString` points at a Zalo Web (`zpw_type = 30`)
    /// `*-wpa.chat.zalo.me` host, which is forbidden on iOS Native sessions
    /// (`client_type = 2`, `zpw_type = 24`) because it triggers `error_code = 602`.
    public static func isForbiddenWebWpaURL(_ urlString: String) -> Bool {
        let raw = urlString.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let host = URL(string: raw)?.host?.lowercased() ?? raw
        return host.contains("wpa.chat.zalo.me")
            || host == "quickmessage.chat.zalo.me"
            || host == "auto-rep-msg.chat.zalo.me"
    }

    /// Maps each default service host to its native service-map key so a
    /// session-provided host (assigned per-account at login) overrides the default.
    /// Session hosts pointing at forbidden Zalo Web `*-wpa.chat.zalo.me` endpoints
    /// are ignored so poisoned maps saved by older builds can never dial out.
    internal func resolvedServiceBaseURL(_ baseURL: String, serviceKey: String? = nil) -> String {
        let normalizedDefault = (serviceKey == "friend" || baseURL.lowercased().contains("friend.talk.zing.vn"))
            ? ZolaSession.normalizeFriendHost(baseURL)
            : baseURL
        guard let map = session.serviceHosts, !map.isEmpty else { return normalizedDefault }
        let key: String
        if let serviceKey {
            key = serviceKey
        } else {
            switch normalizedDefault {
            case Self.defaultChatWpaHost: key = "chat"
            case Self.defaultGroupWpaHost: key = "group"
            case Self.defaultStickerHost: key = "sticker"
            case Self.defaultReactionHost: key = "reaction"
            case Self.defaultAliasHost: key = "alias"
            case Self.defaultConversationHost: key = "conversation"
            case Self.defaultProfileHost: key = "profile"
            case Self.defaultFileWpaHost: key = "file"
            case ZolaConstants.defaultFriendHost: key = "friend"
            default: return normalizedDefault
            }
        }
        let host = map[key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if host.isEmpty || Self.isForbiddenWebWpaURL(host) { return normalizedDefault }
        return (key == "friend") ? ZolaSession.normalizeFriendHost(host) : host
    }

    /// Generic ZCID-encrypted service request helper for Zalo REST services.
    internal func encryptedServiceCall(
        baseURL: String,
        endpoint: String,
        params: [String: Any],
        method: String = "GET",
        allowedCodes: Set<Int> = [],
        serviceKey: String? = nil
    ) async throws -> (code: Int, data: [String: Any]) {
        try assertSessionAlive()
        guard session.zcidIsNative else {
            throw ZolaError.safetyGate(
                "Nick này được nạp từ máy tính nên chưa có khoá zcid gốc. Hãy đăng nhập trực tiếp nick này bằng đăng nhập native (ZolaLoginClient)."
            )
        }
        var inner = params
        if inner["imei"] == nil {
            inner["imei"] = ZolaCrypto.extractZCIDIdentity(zcid: session.zcid).imei
        }
        let resolvedBase = resolvedServiceBaseURL(baseURL, serviceKey: serviceKey)
        let fullURL = endpoint.isEmpty ? resolvedBase : "\(resolvedBase)/\(endpoint)"
        let req = try ZolaRequestBuilder.buildEncryptedRequest(
            url: fullURL,
            innerParams: inner,
            session: session,
            method: method
        )
        if let u = req.url?.absoluteString, Self.isForbiddenWebWpaURL(u) {
            throw ZolaError.safetyGate(
                "Đã chặn endpoint Zalo Web (*-wpa.chat.zalo.me) trên phiên iOS Native để tránh lỗi mã 602 (zpw_type)."
            )
        }
        let (status, raw) = try await executeSessionRequest(req)
        let body = ZolaRequestBuilder.gunzipDecompress(raw) ?? raw
        guard let env = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
            if status == 404 || Self.isHTMLErrorBody(body) {
                throw ZolaError.safetyGate("Máy chủ Zalo cho app iOS không có chức năng này (\(endpoint)).")
            }
            throw ZolaError.transport("Non-JSON response on \(endpoint)")
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

    // MARK: 1. Account & Context (`getOwnId`, `getContext`, `fetchAccountInfo`, `keepAlive`)

    /// Returns the authenticated account's Zalo UID as a `String` (matches `api.getOwnId()`).
    public func getOwnId() -> String {
        String(session.uid)
    }

    /// Returns the active `ZolaSession` context (matches `api.getContext()`).
    public func getContext() -> ZolaSession {
        session
    }

    /// Fetches the current account's profile (matches `api.fetchAccountInfo()`).
    public func fetchAccountInfo() async throws -> ZolaUser {
        try await getUserProfile(uid: session.uid)
    }

    /// Pings the session to verify liveness (matches `api.keepAlive()`).
    @discardableResult
    public func keepAlive() async throws -> Bool {
        _ = try await fetchFemc(lastClientMsgId: watermarks.femcLastCliId, lastGlobalMsgId: watermarks.femcLastGlbId)
        return true
    }

    /// Convenience alias for `eventStream(intervalSeconds:includePreload:)` matching `listener`.
    public nonisolated func events(
        intervalSeconds: Double = 2.0,
        includePreload: Bool = true
    ) -> AsyncThrowingStream<ZolaEvent, Error> {
        eventStream(intervalSeconds: intervalSeconds, includePreload: includePreload)
    }

    // MARK: 2. User Lookup & Contacts (`findUser`, `findUserByUsername`, `getMultiUsersByPhones`, `getUserInfo`)

    /// Looks up a Zalo user by phone number (`api.findUser(phoneNumber)`).
    /// Returns `nil` when Zalo returns error code `216` (phone not registered / not searchable), or throws on other server errors.
    public func findUser(_ phoneNumber: String, countryCode: String = "84") async throws -> ZolaUser? {
        switch try await findUserByPhone(phoneNumber, countryCode: countryCode) {
        case .found(let user):
            return user
        case .notFound:
            return nil
        case .failed(let code, let message):
            throw ZolaError.server(code: code, message: message)
        }
    }

    /// Looks up a Zalo user by username (`api.findUserByUsername(username)`).
    public func findUserByUsername(_ username: String, avatarSize: Int = 240) async throws -> ZolaUser? {
        let trimmed = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ZolaError.invalidArgument("Username must not be empty")
        }
        let (_, data) = try await friendServiceCall(
            "search/by-user-name",
            params: [
                "user_name": trimmed,
                "avatar_size": avatarSize,
            ],
            method: "GET",
            allowedCodes: [Self.phoneNotFoundCode]
        )
        let profDict = (data["profile"] as? [String: Any]) ?? data
        let user = ZolaUser.fromServerDict(profDict)
        return (user.uid > 0 && !user.isLockedAccount) ? user : nil
    }

    /// Looks up multiple Zalo users by phone numbers (`api.getMultiUsersByPhones(phones)`).
    public func getMultiUsersByPhones(
        _ phones: [String],
        countryCode: String = "84",
        avatarSize: Int = 240
    ) async throws -> [String: ZolaUser] {
        let normalized = phones.map { Self.internationalPhone($0, countryCode: countryCode) }.filter { $0.count >= 8 }
        guard !normalized.isEmpty else { return [:] }
        let (_, data) = try await friendServiceCall(
            "profile/multiget",
            params: [
                "phones": normalized,
                "avatar_size": avatarSize,
                "language": "vi",
            ],
            method: "GET",
            allowedCodes: [Self.phoneNotFoundCode]
        )
        var result: [String: ZolaUser] = [:]
        for (k, v) in data {
            if let dict = v as? [String: Any] {
                let u = ZolaUser.fromServerDict(dict)
                if u.uid > 0 && !u.isLockedAccount {
                    result[k] = u
                }
            }
        }
        return result
    }

    /// Fetches profile details for a Zalo UID (`api.getUserInfo(userId)`).
    public func getUserInfo(_ uid: Int64, avatarSize: Int = 120) async throws -> ZolaUser {
        try await getUserProfile(uid: uid, avatarSize: avatarSize)
    }

    // MARK: 3. Friends & Friend Requests (`getAllFriends`, `getFriendRecommendations`, `getSentFriendRequest`, `removeFriend`, `blockUser`, `changeFriendAlias`, ...)

    /// Fetches the account's full friend list (`api.getAllFriends()`).
    public func getAllFriends(avatarSize: Int = 120) async throws -> [ZolaUser] {
        try await listFriends(avatarSize: avatarSize)
    }

    /// Fetches incoming friend requests and friend recommendations (`api.getFriendRecommendations()`).
    public func getFriendRecommendations() async throws -> [ZolaFriendRequest] {
        let all = try await fetchFriendRequests()
        return all.filter { $0.direction != .outgoing }
    }

    /// Fetches outgoing (sent) friend requests (`UXChatSocket cmd = 396, subCmd = 4`).
    public func getSentFriendRequest() async throws -> [ZolaFriendRequest] {
        try await fetchSentFriendRequests()
    }

    /// Queries the friendship / request status with `fid` (`UXChatSocket cmd = 378, subCmd = 1`).
    public func getFriendRequestStatus(_ fid: Int64) async throws -> [String: Any] {
        try await fetchFriendRequestStatus(fid)
    }

    /// Unfriends `friendId` (`api.removeFriend(friendId)`).
    @discardableResult
    public func removeFriend(_ friendId: Int64, dryRun: Bool = false) async throws -> Bool {
        try assertSessionAlive()
        guard friendId > 0 else { throw ZolaError.invalidArgument("Invalid friendId \(friendId)") }
        if dryRun { return true }
        _ = try await friendServiceCall(
            "remove",
            params: ["fid": String(friendId)],
            method: "POST"
        )
        return true
    }

    /// Blocks `userId` (`api.blockUser(userId)`).
    @discardableResult
    public func blockUser(_ userId: Int64, dryRun: Bool = false) async throws -> Bool {
        try assertSessionAlive()
        guard userId > 0 else { throw ZolaError.invalidArgument("Invalid userId \(userId)") }
        if dryRun { return true }
        _ = try await friendServiceCall(
            "block",
            params: ["fid": String(userId)],
            method: "POST"
        )
        return true
    }

    /// Unblocks `userId` (`api.unblockUser(userId)`).
    @discardableResult
    public func unblockUser(_ userId: Int64, dryRun: Bool = false) async throws -> Bool {
        try assertSessionAlive()
        guard userId > 0 else { throw ZolaError.invalidArgument("Invalid userId \(userId)") }
        if dryRun { return true }
        _ = try await friendServiceCall(
            "unblock",
            params: ["fid": String(userId)],
            method: "POST"
        )
        return true
    }

    /// Sets a custom alias (nickname) for a friend (`api.changeFriendAlias(alias, friendId)`).
    @discardableResult
    public func changeFriendAlias(_ alias: String, friendId: Int64, dryRun: Bool = false) async throws -> Bool {
        try assertSessionAlive()
        guard friendId > 0, !alias.isEmpty else {
            throw ZolaError.invalidArgument("friendId and alias must be non-empty")
        }
        if dryRun { return true }
        _ = try await encryptedServiceCall(
            baseURL: Self.defaultAliasHost,
            endpoint: "api/alias/update",
            params: ["friendId": String(friendId), "alias": alias],
            method: "GET"
        )
        return true
    }

    /// Removes the custom alias for a friend (`api.removeFriendAlias(friendId)`).
    @discardableResult
    public func removeFriendAlias(_ friendId: Int64, dryRun: Bool = false) async throws -> Bool {
        try assertSessionAlive()
        guard friendId > 0 else { throw ZolaError.invalidArgument("Invalid friendId \(friendId)") }
        if dryRun { return true }
        _ = try await encryptedServiceCall(
            baseURL: Self.defaultAliasHost,
            endpoint: "api/alias/remove",
            params: ["friendId": String(friendId)],
            method: "GET"
        )
        return true
    }

    /// Lists all friend aliases (`api.getAliasList()`).
    public func getAliasList(page: Int = 1, count: Int = 100) async throws -> [Int64: String] {
        let (_, data) = try await encryptedServiceCall(
            baseURL: Self.defaultAliasHost,
            endpoint: "api/alias/list",
            params: ["page": page, "count": count],
            method: "GET"
        )
        let items = (data["items"] ?? data["list"] ?? data["data"]) as? [[String: Any]] ?? []
        var aliases: [Int64: String] = [:]
        for item in items {
            let uid = ZolaJSON.int64(item["userId"] ?? item["friendId"] ?? item["uid"])
            let name = ZolaJSON.string(item["alias"])
            if uid > 0, !name.isEmpty {
                aliases[uid] = name
            }
        }
        return aliases
    }

    // MARK: 4. Groups (`getAllGroups`, `createGroup`, `addUserToGroup`, `removeUserFromGroup`, `changeGroupName`, `enableGroupLink`, ...)

    /// Lists all joined groups (`api.getAllGroups()`).
    public func getAllGroups() async throws -> [ZolaGroup] {
        try await listJoinedGroups()
    }

    /// Creates a new Zalo group (`api.createGroup(options)`).
    public func createGroup(
        name: String,
        members: [Int64],
        dryRun: Bool = false
    ) async throws -> [String: Any] {
        try assertSessionAlive()
        let validMembers = members.filter { $0 > 0 }
        guard !validMembers.isEmpty else {
            throw ZolaError.invalidArgument("Group must have at least one member")
        }
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let params: [String: Any] = [
            "clientId": nowMs,
            "gname": name,
            "gdesc": NSNull(),
            "members": validMembers.map { String($0) },
            "membersTypes": Array(repeating: -1, count: validMembers.count),
            "nameChanged": name.isEmpty ? 0 : 1,
            "createLink": 1,
            "clientLang": "vi",
            "zsource": 601,
        ]
        if dryRun {
            return ["dryRun": true, "params": params]
        }
        return try await encryptedServiceCall(
            baseURL: Self.defaultGroupWpaHost,
            endpoint: "api/group/create/v2",
            params: params,
            method: "POST"
        ).data
    }

    /// Invites users into a group (`api.addUserToGroup(memberId, groupId)`).
    public func addUserToGroup(
        groupId: Int64,
        memberIds: [Int64],
        dryRun: Bool = false
    ) async throws -> [String: Any] {
        try assertSessionAlive()
        let validMembers = memberIds.filter { $0 > 0 }
        guard groupId > 0, !validMembers.isEmpty else {
            throw ZolaError.invalidArgument("Invalid groupId or empty memberIds")
        }
        let params: [String: Any] = [
            "grid": String(groupId),
            "members": validMembers.map { String($0) },
            "memberTypes": Array(repeating: -1, count: validMembers.count),
            "clientLang": "vi",
        ]
        if dryRun { return ["dryRun": true, "params": params] }
        return try await encryptedServiceCall(
            baseURL: Self.defaultGroupWpaHost,
            endpoint: "api/group/invite/v2",
            params: params,
            method: "POST"
        ).data
    }

    /// Removes users from a group (`api.removeUserFromGroup(memberId, groupId)`).
    public func removeUserFromGroup(
        groupId: Int64,
        memberIds: [Int64],
        dryRun: Bool = false
    ) async throws -> [String: Any] {
        try assertSessionAlive()
        let validMembers = memberIds.filter { $0 > 0 }
        guard groupId > 0, !validMembers.isEmpty else {
            throw ZolaError.invalidArgument("Invalid groupId or empty memberIds")
        }
        let params: [String: Any] = [
            "grid": String(groupId),
            "members": validMembers.map { String($0) },
        ]
        if dryRun { return ["dryRun": true, "params": params] }
        return try await encryptedServiceCall(
            baseURL: Self.defaultGroupWpaHost,
            endpoint: "api/group/kickout",
            params: params,
            method: "POST"
        ).data
    }

    /// Renames a group (`api.changeGroupName(name, groupId)`).
    @discardableResult
    public func changeGroupName(_ name: String, groupId: Int64, dryRun: Bool = false) async throws -> Bool {
        try assertSessionAlive()
        guard groupId > 0, !name.isEmpty else {
            throw ZolaError.invalidArgument("Invalid groupId or empty group name")
        }
        if dryRun { return true }
        _ = try await encryptedServiceCall(
            baseURL: Self.defaultGroupWpaHost,
            endpoint: "api/group/updateinfo",
            params: ["grid": String(groupId), "gname": name],
            method: "POST"
        )
        return true
    }

    /// Enables and returns the group invite link (`api.enableGroupLink(groupId)`).
    public func enableGroupLink(groupId: Int64, dryRun: Bool = false) async throws -> String? {
        try assertSessionAlive()
        guard groupId > 0 else { throw ZolaError.invalidArgument("Invalid groupId \(groupId)") }
        if dryRun { return "https://zalo.me/g/dryrun-\(groupId)" }
        let (_, data) = try await encryptedServiceCall(
            baseURL: Self.defaultGroupWpaHost,
            endpoint: "api/group/link/new",
            params: ["grid": String(groupId)],
            method: "POST"
        )
        let link = ZolaJSON.string(data["link"] ?? data["url"])
        return link.isEmpty ? nil : link
    }

    /// Disables the group invite link (`api.disableGroupLink(groupId)`).
    @discardableResult
    public func disableGroupLink(groupId: Int64, dryRun: Bool = false) async throws -> Bool {
        try assertSessionAlive()
        guard groupId > 0 else { throw ZolaError.invalidArgument("Invalid groupId \(groupId)") }
        if dryRun { return true }
        _ = try await encryptedServiceCall(
            baseURL: Self.defaultGroupWpaHost,
            endpoint: "api/group/link/disable",
            params: ["grid": String(groupId)],
            method: "GET"
        )
        return true
    }

    /// Returns the active group invite link (`api.getGroupLinkDetail(groupId)`).
    public func getGroupLinkDetail(groupId: Int64) async throws -> String? {
        guard groupId > 0 else { throw ZolaError.invalidArgument("Invalid groupId \(groupId)") }
        let (_, data) = try await encryptedServiceCall(
            baseURL: Self.defaultGroupWpaHost,
            endpoint: "api/group/link/detail",
            params: ["grid": String(groupId)],
            method: "GET"
        )
        let link = ZolaJSON.string(data["link"] ?? data["url"])
        return link.isEmpty ? nil : link
    }

    // MARK: 5. Messaging, Reactions, Undo, Delete, Typing & Seen (`sendMessage`, `addReaction`, `undo`, `deleteMessage`, `sendTypingEvent`, `sendSeenEvent`)

    /// Sends a message to a user or group (`sendMessage(message, threadId, type)`),
    /// encoding native `TLV tag = 2` (`QuoteData`) when `payload.quote` is present.
    public func sendMessage(
        _ payload: ZolaMessagePayload,
        threadId: Int64,
        type: ZolaThreadType = .user,
        dryRun: Bool = true
    ) async throws -> ZolaSendReceipt {
        try await sendText1To1(
            to: threadId,
            text: payload.msg,
            quote: payload.quote,
            ttlMs: payload.ttl > 0 ? Int64(payload.ttl) : 0,
            dryRun: dryRun,
            isGroup: type == .group
        )
    }

    /// Sends a 1-1 reply (quoted text) over the native failover channel
    /// (`failover.zingmp3.vn/api/message`, `cmd = 130, innerCmd = 113, subCmd = 41` `CrypKey`)
    /// with Zalo iOS Native `TLV tag = 2` (`QuoteData`). Group replies are not supported over HTTP failover.
    public func sendQuotedText(
        text: String,
        threadId: Int64,
        quote: ZolaQuote,
        type: ZolaThreadType = .user,
        dryRun: Bool = false
    ) async throws -> ZolaSendReceipt {
        try assertSessionAlive()
        guard !text.isEmpty else {
            throw ZolaError.invalidArgument("Message text must not be empty")
        }
        if type == .group || knownGroupIds().contains(threadId) {
            throw ZolaError.groupSendNotSupportedOverHttp
        }
        return try await sendText1To1(
            to: threadId,
            text: text,
            quote: quote,
            dryRun: dryRun,
            isGroup: false,
            requireCryptKey: !dryRun
        )
    }

    /// Resolves a sticker's real `cateId`/`stickerType` for the native `subCmd = 36` (`0x24`) frame.
    /// When `cateIdHint` is missing or still carries the generic fallback (`10425`), fetches the
    /// sticker's 16-byte little-endian CDN header (`[magic, cid, sid, stype]`, `magic == 20000`)
    /// from `zalo-api.zadn.vn` and caches the resolved metadata on `ZolaClient`.
    public func resolveStickerMetaNative(
        stickerId: Int64,
        cateIdHint: Int64 = 0,
        typeHint: Int64 = 0
    ) async -> (cateId: Int32, stickerType: Int8) {
        if cateIdHint == 0 && (1...30).contains(stickerId) {
            return (cateId: 0, stickerType: 2)
        }
        if let cached = stickerMetaCache[stickerId] {
            return cached
        }
        if cateIdHint > 0, cateIdHint != 10_425, typeHint > 0 {
            let resolved = (
                cateId: Int32(truncatingIfNeeded: cateIdHint),
                stickerType: Int8(clamping: typeHint)
            )
            stickerMetaCache[stickerId] = resolved
            return resolved
        }
        if let url = URL(string: "https://zalo-api.zadn.vn/api/emoticon/sticker?eid=\(stickerId)&size=130") {
            var req = URLRequest(url: url)
            req.httpMethod = "GET"
            if let (status, data) = try? await executeSessionRequest(req), status == 200, data.count >= 16 {
                let base = data.startIndex
                func le32(_ off: Int) -> UInt32 {
                    UInt32(data[base + off])
                        | (UInt32(data[base + off + 1]) << 8)
                        | (UInt32(data[base + off + 2]) << 16)
                        | (UInt32(data[base + off + 3]) << 24)
                }
                let magic = le32(0)
                let cid = le32(4)
                let stype = le32(12)
                if magic == 20_000, cid > 0 {
                    let resolved = (
                        cateId: Int32(bitPattern: cid),
                        stickerType: Int8(clamping: stype > 0 ? Int(stype) : 7)
                    )
                    stickerMetaCache[stickerId] = resolved
                    return resolved
                }
            }
        }
        for pack in ZolaStickerCatalog.packs {
            if let hit = pack.stickers.first(where: { $0.stickerId == stickerId && $0.cateId > 0 && $0.cateId != 10_425 }) {
                let resolved = (
                    cateId: Int32(truncatingIfNeeded: hit.cateId),
                    stickerType: Int8(clamping: hit.stickerType > 0 ? hit.stickerType : 7)
                )
                stickerMetaCache[stickerId] = resolved
                return resolved
            }
        }
        if let detail = try? await getStickersDetail(stickerId) {
            let nested = (detail["sticker"] as? [String: Any]) ?? detail
            let cid = ZolaJSON.int64(nested["cateId"] ?? nested["cid"] ?? nested["catId"] ?? detail["cateId"] ?? detail["cid"])
            let stype = ZolaJSON.int(nested["type"] ?? nested["stickerType"] ?? detail["type"])
            if cid > 0 {
                let resolved = (
                    cateId: Int32(truncatingIfNeeded: cid),
                    stickerType: Int8(clamping: stype > 0 ? stype : (typeHint > 0 ? Int(typeHint) : 7))
                )
                stickerMetaCache[stickerId] = resolved
                return resolved
            }
        }
        return (Int32(truncatingIfNeeded: max(0, cateIdHint)), Int8(clamping: typeHint > 0 ? typeHint : 7))
    }

    /// Sends a native 1-1 sticker over the failover channel
    /// (`failover.zingmp3.vn/api/message`, `cmd = 130, innerCmd = 113, subCmd = 36`).
    /// Group stickers are not supported over HTTP failover.
    public func sendSticker(
        stickerId: Int64,
        cateId: Int64,
        stickerType: Int64,
        threadId: Int64,
        type: ZolaThreadType = .user,
        quote: ZolaQuote? = nil,
        dryRun: Bool = false,
        clientIdMs: Int64? = nil
    ) async throws -> ZolaSendReceipt {
        try assertSessionAlive()
        guard stickerId > 0 else {
            throw ZolaError.invalidArgument("stickerId must be positive")
        }
        if type == .group || knownGroupIds().contains(threadId) {
            throw ZolaError.groupSendNotSupportedOverHttp
        }
        let meta = await resolveStickerMetaNative(stickerId: stickerId, cateIdHint: cateId, typeHint: stickerType)
        return try await sendSticker1To1(
            to: threadId,
            stickerId: Int32(truncatingIfNeeded: stickerId),
            cateId: meta.cateId,
            stickerType: meta.stickerType,
            quote: quote,
            dryRun: dryRun,
            clientIdMs: clientIdMs
        )
    }

    /// Resolves a sticker's real `cateId`/`stickerType` from its native CDN header,
    /// then sends it (`subCmd = 36`). Callers that only know the sticker id (e.g. a sticker tray)
    /// should use this instead of guessing `type`/`cateId`.
    public func sendStickerResolvingDetail(
        stickerId: Int64,
        cateIdHint: Int64,
        typeHint: Int64 = 0,
        threadId: Int64,
        type: ZolaThreadType = .user,
        quote: ZolaQuote? = nil,
        dryRun: Bool = false,
        clientIdMs: Int64? = nil
    ) async throws -> ZolaSendReceipt {
        try assertSessionAlive()
        guard stickerId > 0 else {
            throw ZolaError.invalidArgument("stickerId must be positive")
        }
        if type == .group || knownGroupIds().contains(threadId) {
            throw ZolaError.groupSendNotSupportedOverHttp
        }
        let meta = await resolveStickerMetaNative(stickerId: stickerId, cateIdHint: cateIdHint, typeHint: typeHint)
        return try await sendSticker1To1(
            to: threadId,
            stickerId: Int32(truncatingIfNeeded: stickerId),
            cateId: meta.cateId,
            stickerType: meta.stickerType,
            quote: quote,
            dryRun: dryRun,
            clientIdMs: clientIdMs
        )
    }

    /// Maps any of the 6 supported Zalo reactions (emoji or wire code, or `""` to clear) onto `(rIcon, rType, displayEmoji)`.
    public static func zaloReactionIcon(for emojiOrIcon: String) -> (rIcon: String, rType: Int, displayEmoji: String)? {
        let trimmed = emojiOrIcon.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return (rIcon: "", rType: 0, displayEmoji: "")
        }
        switch trimmed {
        case "/-heart", "❤️", "❤":
            return (rIcon: "/-heart", rType: 5, displayEmoji: "❤️")
        case "/-strong", "👍":
            return (rIcon: "/-strong", rType: 3, displayEmoji: "👍")
        case ":>", "😆", "😂":
            return (rIcon: ":>", rType: 0, displayEmoji: "😆")
        case ":-o", "😮":
            return (rIcon: ":-o", rType: 32, displayEmoji: "😮")
        case ":-((" , "😢":
            return (rIcon: ":-((" , rType: 2, displayEmoji: "😢")
        case ":-h", "😡", "😠":
            return (rIcon: ":-h", rType: 20, displayEmoji: "😡")
        default:
            return nil
        }
    }

    /// Sends a native 1-1 message reaction (`cmd = 130, innerCmd = 113, subCmd = 55`)
    /// matching Zalo iOS `261002` `-[ReactionEntity createReactionChatElement]` (`0x100E06A38`).
    public func sendReaction1To1(
        to toId: Int64,
        messageSenderUid: Int64,
        cliMsgId: Int64,
        globalMsgId: Int64,
        icon: String,
        msgType: Int = 1,
        dryRun: Bool = false,
        clientIdMs: Int64? = nil
    ) async throws -> ZolaSendReceipt {
        try assertSessionAlive()
        guard let mapped = Self.zaloReactionIcon(for: icon) else {
            throw ZolaError.invalidArgument("Unsupported Zalo reaction icon: \(icon)")
        }
        let senderStr = String(messageSenderUid > 0 ? messageSenderUid : session.uid)
        let rMsgItem: [String: Any] = [
            "cMsgID": cliMsgId,
            "gMsgID": globalMsgId,
            "msgType": msgType,
        ]
        let paramObj: [String: Any] = [
            "msgSender": senderStr,
            "rIcon": mapped.rIcon,
            "rMsg": [rMsgItem],
            "rType": mapped.rType,
            "source": 6,
        ]
        let paramData = (try? JSONSerialization.data(withJSONObject: paramObj, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        let paramJson = String(decoding: paramData, as: UTF8.self)
        return try await sendMedia1To1(
            to: toId,
            subCmd: ZolaConstants.subCmdSendReaction,
            href: "",
            thumb: "",
            title: "",
            description: "",
            action: "",
            param: paramJson,
            caption: "",
            quote: nil,
            includeIOSPropsOverride: false,
            dryRun: dryRun,
            clientIdMs: clientIdMs
        )
    }

    /// Adds a reaction (`"/-heart"`, `"/-strong"`, `":>"`, `":-o"`, `":-(("`, `":-h"`, emoji equivalents, or `""` to clear)
    /// over Zalo iOS Native `failover.zingmp3.vn/api/message` (`subCmd = 55`) for 1-1/Cloud chats.
    @discardableResult
    public func addReaction(
        _ icon: String,
        message: ZolaMessage,
        type: ZolaThreadType = .user,
        dryRun: Bool = false
    ) async throws -> Bool {
        try assertSessionAlive()
        guard let mapped = Self.zaloReactionIcon(for: icon) else {
            throw ZolaError.invalidArgument("Unsupported Zalo reaction icon: \(icon)")
        }
        if dryRun { return true }
        let rIcon = mapped.rIcon
        let rType = mapped.rType
        if type == .group || message.isGroup {
            let groupParams: [String: Any] = [
                "reactInfo": [
                    "rIcon": rIcon,
                    "rType": rType,
                    "source": 6,
                    "msgIds": "[{\"gMsgID\":\(message.id),\"cMsgID\":\(message.cliMsgId),\"msgType\":1}]",
                ],
                "grid": String(message.threadId),
            ]
            do {
                _ = try await encryptedServiceCall(
                    baseURL: Self.defaultReactionHost,
                    endpoint: "api/group/reaction",
                    params: groupParams,
                    method: "POST",
                    serviceKey: "reaction"
                )
            } catch {
                _ = try await encryptedServiceCall(
                    baseURL: Self.defaultGroupWpaHost,
                    endpoint: "api/group/react",
                    params: groupParams,
                    method: "POST",
                    serviceKey: "group"
                )
            }
            return true
        } else {
            let targetThreadId: Int64 = {
                if message.isCloud { return session.sendToMeId }
                if message.threadId > 0 && message.threadId != session.uid { return message.threadId }
                return message.isSelf ? message.toId : message.senderId
            }()
            let resolvedSender = message.senderId > 0
                ? message.senderId
                : (message.isSelf ? session.uid : targetThreadId)
            let receipt = try await sendReaction1To1(
                to: targetThreadId,
                messageSenderUid: resolvedSender,
                cliMsgId: message.cliMsgId,
                globalMsgId: message.id,
                icon: icon,
                dryRun: false
            )
            return receipt.ok
        }
    }

    /// Recalls (unsends) a sent message (`api.undo(payload, threadId, type)`).
    @discardableResult
    public func undo(
        message: ZolaMessage,
        threadId: Int64,
        type: ZolaThreadType = .user,
        dryRun: Bool = false
    ) async throws -> Bool {
        try assertSessionAlive()
        guard threadId > 0 else { throw ZolaError.invalidArgument("Invalid threadId \(threadId)") }
        if dryRun { return true }
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        if type == .group || message.isGroup {
            let resolvedBase = resolvedServiceBaseURL(Self.defaultGroupWpaHost, serviceKey: "group")
            if transport is ZolaURLSessionTransport && resolvedBase == Self.defaultGroupWpaHost {
                throw ZolaError.safetyGate(
                    "Thu hồi hai chiều trên nhóm Zalo iOS cần kênh Socket 2001 (sẽ mở ở Đợt 2). Hiện bạn có thể dùng 'Xoá ở phía tôi' hoặc thu hồi trên ứng dụng Zalo chính thức."
                )
            }
            _ = try await encryptedServiceCall(
                baseURL: Self.defaultGroupWpaHost,
                endpoint: "api/group/undomsg",
                params: [
                    "grid": String(threadId),
                    "msgId": message.id,
                    "clientId": nowMs,
                    "cliMsgIdUndo": message.cliMsgId,
                    "visibility": 0,
                    "clientLang": "vi",
                ],
                method: "POST"
            )
        } else {
            let resolvedBase = resolvedServiceBaseURL(Self.defaultChatWpaHost, serviceKey: "chat")
            if transport is ZolaURLSessionTransport && resolvedBase == Self.defaultChatWpaHost {
                throw ZolaError.safetyGate(
                    "Thu hồi hai chiều cho mọi người trên Zalo iOS cần kênh Socket 2001 (sẽ mở ở Đợt 2). Hiện bạn có thể dùng 'Xoá ở phía tôi' hoặc thu hồi trên ứng dụng Zalo chính thức."
                )
            }
            _ = try await encryptedServiceCall(
                baseURL: Self.defaultChatWpaHost,
                endpoint: "api/message/undo",
                params: [
                    "toid": String(threadId),
                    "msgId": message.id,
                    "clientId": nowMs,
                    "cliMsgIdUndo": message.cliMsgId,
                ],
                method: "POST"
            )
        }
        return true
    }

    /// Deletes a message for self or everyone (`api.deleteMessage(dest, onlyMe)`).
    @discardableResult
    public func deleteMessage(
        _ message: ZolaMessage,
        threadId: Int64,
        type: ZolaThreadType = .user,
        onlyMe: Bool = true,
        dryRun: Bool = false
    ) async throws -> Bool {
        try assertSessionAlive()
        guard threadId > 0 else { throw ZolaError.invalidArgument("Invalid threadId \(threadId)") }
        if dryRun { return true }
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let msgEntry: [String: Any] = [
            "cliMsgId": String(message.cliMsgId),
            "globalMsgId": String(message.id),
            "ownerId": String(message.senderId),
            "destId": String(threadId),
        ]
        if type == .group || message.isGroup {
            let resolvedBase = resolvedServiceBaseURL(Self.defaultGroupWpaHost, serviceKey: "group")
            if transport is ZolaURLSessionTransport && resolvedBase == Self.defaultGroupWpaHost {
                return true
            }
            _ = try await encryptedServiceCall(
                baseURL: Self.defaultGroupWpaHost,
                endpoint: "api/group/deletemsg",
                params: [
                    "grid": String(threadId),
                    "cliMsgId": nowMs,
                    "msgs": [msgEntry],
                    "onlyMe": onlyMe ? 1 : 0,
                ],
                method: "POST"
            )
        } else {
            let resolvedBase = resolvedServiceBaseURL(Self.defaultChatWpaHost, serviceKey: "chat")
            if transport is ZolaURLSessionTransport && resolvedBase == Self.defaultChatWpaHost {
                return true
            }
            _ = try await encryptedServiceCall(
                baseURL: Self.defaultChatWpaHost,
                endpoint: "api/message/delete",
                params: [
                    "toid": String(threadId),
                    "cliMsgId": nowMs,
                    "msgs": [msgEntry],
                    "onlyMe": onlyMe ? 1 : 0,
                ],
                method: "POST"
            )
        }
        return true
    }

    /// Sends a typing indicator event (`api.sendTypingEvent(threadId, type)`).
    @discardableResult
    public func sendTypingEvent(
        threadId: Int64,
        type: ZolaThreadType = .user,
        dryRun: Bool = false
    ) async throws -> Bool {
        try assertSessionAlive()
        guard threadId > 0 else { throw ZolaError.invalidArgument("Invalid threadId \(threadId)") }
        if dryRun { return true }
        if type == .group {
            _ = try await encryptedServiceCall(
                baseURL: Self.defaultGroupWpaHost,
                endpoint: "api/group/typing",
                params: ["grid": String(threadId)],
                method: "POST"
            )
        } else {
            _ = try await encryptedServiceCall(
                baseURL: Self.defaultChatWpaHost,
                endpoint: "api/message/typing",
                params: ["toid": String(threadId), "destType": 1],
                method: "POST"
            )
        }
        return true
    }

    /// Sends a playable 1-1 voice message over the native failover channel
    /// (`failover.zingmp3.vn/api/message`, `cmd = 130, innerCmd = 113, subCmd = 31` `chat.voice`).
    /// Group voice is not supported over HTTP failover.
    @discardableResult
    public func sendVoice(
        voiceUrl: String,
        threadId: Int64,
        type: ZolaThreadType = .user,
        durationMs: Int = 5000,
        fileSize: Int = 0,
        m4aUrl: String = "",
        quote: ZolaQuote? = nil,
        dryRun: Bool = false
    ) async throws -> Bool {
        try assertSessionAlive()
        guard threadId > 0 else { throw ZolaError.invalidArgument("Invalid threadId \(threadId)") }
        let trimmed = voiceUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ZolaError.invalidArgument("voiceUrl must not be empty") }
        if type == .group || knownGroupIds().contains(threadId) {
            let receipt = try await sendVoiceGroup(
                gid: threadId,
                voiceUrl: trimmed,
                durationMs: durationMs,
                fileSize: fileSize,
                m4aUrl: m4aUrl,
                quote: quote,
                dryRun: dryRun
            )
            return receipt.ok
        }
        let receipt = try await sendVoice1To1(
            to: threadId,
            voiceUrl: trimmed,
            durationMs: durationMs,
            fileSize: fileSize,
            fileExt: "aac",
            m4aUrl: m4aUrl,
            quote: quote,
            dryRun: dryRun
        )
        return receipt.ok
    }

    /// Uploads a file to Zalo's native iOS HTTP upload service (`uploadConfig.api_url` -> `ZaloUploadHTTPBackground`)
    /// without opening `UXSocket` (`2001`) or calling forbidden Zalo Web `*-wpa.chat.zalo.me` hosts.
    @discardableResult
    public func uploadAttachment(
        fileName: String,
        fileData: Data,
        threadId: Int64,
        type: ZolaThreadType = .user,
        dryRun: Bool = false
    ) async throws -> [String: Any] {
        try assertSessionAlive()
        guard !fileData.isEmpty else { throw ZolaError.invalidArgument("fileData must not be empty") }
        if dryRun { return [:] }
        return try await uploadMediaNativeHTTP(
            fileData: fileData,
            fileName: fileName,
            toId: threadId,
            isGroup: type == .group || knownGroupIds().contains(threadId)
        )
    }

    /// Marks up to 50 messages as seen (`api.sendSeenEvent(messages, type)`).
    @discardableResult
    public func sendSeenEvent(
        messages: [ZolaMessage],
        type: ZolaThreadType = .user,
        dryRun: Bool = false
    ) async throws -> Bool {
        try assertSessionAlive()
        guard !messages.isEmpty else { return true }
        if dryRun { return true }
        let targetId = messages[0].threadId
        let seenEntries: [[String: Any]] = messages.prefix(50).map { m in
            [
                "cmi": String(m.cliMsgId),
                "gmi": String(m.id),
                "si": String(m.senderId),
                "di": String(m.toId == session.uid ? 0 : m.toId),
                "mt": m.msgType,
                "st": 0,
                "at": 0,
                "cmd": -1,
                "ts": m.tsMs,
            ]
        }
        if type == .group || messages[0].isGroup {
            _ = try await encryptedServiceCall(
                baseURL: Self.defaultGroupWpaHost,
                endpoint: "api/group/seenv2",
                params: [
                    "msgInfos": [
                        "data": seenEntries,
                        "grid": String(targetId),
                    ]
                ],
                method: "POST"
            )
        } else {
            _ = try await encryptedServiceCall(
                baseURL: Self.defaultChatWpaHost,
                endpoint: "api/message/seenv2",
                params: [
                    "msgInfos": [
                        "data": seenEntries,
                        "senderId": String(targetId),
                    ]
                ],
                method: "POST"
            )
        }
        return true
    }

    /// Parses link metadata (`api.parseLink(link)`).
    public func parseLink(_ link: String) async throws -> [String: Any] {
        guard !link.isEmpty else { throw ZolaError.invalidArgument("Link must not be empty") }
        let linkHost = session.serviceHosts?["parselink"]
            ?? session.serviceHosts?["chat"]
            ?? Self.defaultLabelHost
        return try await encryptedServiceCall(
            baseURL: linkHost,
            endpoint: "api/message/link",
            params: ["link": link, "version": 1],
            method: "POST",
            serviceKey: "parselink"
        ).data
    }

    /// Maximum safe size for a single pure-HTTP document upload (`25 MB`).
    public static let maxDocumentUploadBytes: Int = 25 * 1_024 * 1_024

    /// Extracts the first `http://` or `https://` URL found in `text`, trimming trailing punctuation.
    public static func extractFirstURL(in text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let range = trimmed.range(of: #"https?://[^\s<>"]+"#, options: [.regularExpression, .caseInsensitive])
        else { return nil }
        var candidate = String(trimmed[range])
        let trailingPunct = CharacterSet(charactersIn: ".,;:!?)]}>'\"")
        while let lastScalar = candidate.unicodeScalars.last, trailingPunct.contains(lastScalar) {
            if lastScalar == ")", candidate.filter({ $0 == "(" }).count >= candidate.filter({ $0 == ")" }).count {
                break
            }
            candidate.unicodeScalars.removeLast()
        }
        guard let parsed = URL(string: candidate),
              let scheme = parsed.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = parsed.host,
              host.contains(".")
        else { return nil }
        return candidate
    }

    private static func isPrivateOrLocalPreviewHost(_ host: String) -> Bool {
        let h = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if h.isEmpty || h == "localhost" || h == "::1" || h.hasSuffix(".local") || h.hasSuffix(".internal") {
            return true
        }
        let octets = h.split(separator: ".").compactMap { Int($0) }
        if octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) {
            if octets[0] == 10 || octets[0] == 127 || octets[0] == 0 { return true }
            if octets[0] == 169 && octets[1] == 254 { return true }
            if octets[0] == 192 && octets[1] == 168 { return true }
            if octets[0] == 172 && (16...31).contains(octets[1]) { return true }
        }
        return false
    }

    private static func decodeBasicHTMLEntities(_ input: String) -> String {
        input
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&#x27;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    internal static func extractHTMLMetaContent(in html: String, keys: [String]) -> String {
        for key in keys {
            let escaped = NSRegularExpression.escapedPattern(for: key)
            let patterns = [
                #"<meta[^>]+(?:property|name)\s*=\s*["']\#(escaped)["'][^>]*content\s*=\s*"([^"]+)""#,
                #"<meta[^>]+(?:property|name)\s*=\s*["']\#(escaped)["'][^>]*content\s*=\s*'([^']+)'"#,
                #"<meta[^>]+content\s*=\s*"([^"]+)"[^>]*(?:property|name)\s*=\s*["']\#(escaped)["']"#,
                #"<meta[^>]+content\s*=\s*'([^']+)'[^>]*(?:property|name)\s*=\s*["']\#(escaped)["']"#,
            ]
            for pattern in patterns {
                if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                   let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                   match.numberOfRanges >= 2,
                   let valueRange = Range(match.range(at: 1), in: html) {
                    let decoded = decodeBasicHTMLEntities(String(html[valueRange]))
                    if !decoded.isEmpty { return decoded }
                }
            }
        }
        return ""
    }

    private static func extractHTMLTitleTag(in html: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"<title[^>]*>([\s\S]*?)</title>"#, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              match.numberOfRanges >= 2,
              let valueRange = Range(match.range(at: 1), in: html)
        else { return "" }
        return decodeBasicHTMLEntities(String(html[valueRange]))
    }

    /// Resolves OpenGraph / link card metadata for `rawUrl` without touching forbidden web endpoints or risking session state.
    public func resolveLinkMetadata(_ rawUrl: String) async -> ZolaLinkMetadata? {
        guard let cleanUrl = Self.extractFirstURL(in: rawUrl),
              let parsedURL = URL(string: cleanUrl),
              let rawHost = parsedURL.host,
              !Self.isPrivateOrLocalPreviewHost(rawHost),
              !Self.isForbiddenWebWpaURL(cleanUrl)
        else {
            return nil
        }

        let domain = rawHost.replacingOccurrences(of: "^www\\.", with: "", options: .regularExpression)
        var resolvedTitle = ""
        var resolvedDesc = ""
        var resolvedThumb = ""

        if !session.isExpired, session.zcidIsNative,
           (session.serviceHosts?["parselink"] != nil || session.serviceHosts?["chat"] != nil),
           let apiData = try? await parseLink(cleanUrl)
        {
            let nested = (apiData["data"] as? [String: Any]) ?? apiData
            let t = ZolaJSON.string(nested["title"] ?? nested["mediaTitle"] ?? nested["linkTitle"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let d = ZolaJSON.string(nested["desc"] ?? nested["description"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let img = ZolaAttachment.normalizeMediaUrl(
                ZolaJSON.string(nested["thumb"] ?? nested["image"] ?? nested["thumbUrl"])
            )
            if !t.isEmpty && t != "sendBubbleMessage" { resolvedTitle = t }
            if !d.isEmpty && d != "sendBubbleMessage" { resolvedDesc = d }
            if !img.isEmpty && !ZolaLinkMetadata.isPlaceholderThumb(img) { resolvedThumb = img }
        }

        if resolvedTitle.isEmpty || resolvedThumb.isEmpty {
            var htmlReq = URLRequest(url: parsedURL)
            htmlReq.httpMethod = "GET"
            htmlReq.timeoutInterval = 6
            htmlReq.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
            htmlReq.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148", forHTTPHeaderField: "User-Agent")
            if let (status, rawBytes) = try? await executeSessionRequest(htmlReq), (200..<400).contains(status), !rawBytes.isEmpty {
                let unzipped = ZolaRequestBuilder.gunzipDecompress(rawBytes) ?? rawBytes
                let capped = unzipped.prefix(262_144)
                let html = String(decoding: capped, as: UTF8.self)
                if resolvedTitle.isEmpty {
                    let ogTitle = Self.extractHTMLMetaContent(in: html, keys: ["og:title", "twitter:title"])
                    resolvedTitle = !ogTitle.isEmpty ? ogTitle : Self.extractHTMLTitleTag(in: html)
                }
                if resolvedDesc.isEmpty {
                    resolvedDesc = Self.extractHTMLMetaContent(in: html, keys: ["og:description", "twitter:description", "description"])
                }
                if resolvedThumb.isEmpty {
                    let rawOgImg = Self.extractHTMLMetaContent(in: html, keys: ["og:image", "twitter:image", "og:image:url"])
                    if !rawOgImg.isEmpty {
                        let absImg: String
                        if rawOgImg.lowercased().hasPrefix("http://") || rawOgImg.lowercased().hasPrefix("https://") || rawOgImg.hasPrefix("//") {
                            absImg = ZolaAttachment.normalizeMediaUrl(rawOgImg)
                        } else if let relResolved = URL(string: rawOgImg, relativeTo: parsedURL)?.absoluteURL.absoluteString {
                            absImg = relResolved
                        } else {
                            absImg = ""
                        }
                        if !absImg.isEmpty && !ZolaLinkMetadata.isPlaceholderThumb(absImg) {
                            resolvedThumb = absImg
                        }
                    }
                }
            }
        }

        let rawFinalTitle = (!resolvedTitle.isEmpty && resolvedTitle != "sendBubbleMessage") ? resolvedTitle : domain
        let finalTitle = String(rawFinalTitle.prefix(500))
        let finalDesc = resolvedDesc == "sendBubbleMessage" ? "" : String(resolvedDesc.prefix(2_000))
        return ZolaLinkMetadata(
            url: cleanUrl,
            title: finalTitle,
            descriptionText: finalDesc,
            thumbUrl: resolvedThumb,
            domain: domain
        )
    }

    /// Sends a native 1-1 rich Link Preview Card (`cmd = 130, innerCmd = 113, subCmd = 38`, `action = "recommened.link"`).
    public func sendLink1To1(
        to toId: Int64,
        url: String,
        title: String = "",
        descriptionText: String = "",
        thumbUrl: String = "",
        domain: String = "",
        caption: String = "",
        quote: ZolaQuote? = nil,
        dryRun: Bool = true,
        clientIdMs: Int64? = nil,
        trackingIdHex: String? = nil
    ) async throws -> ZolaSendReceipt {
        let cleanUrl = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanUrl.isEmpty, cleanUrl.lowercased().hasPrefix("http") else {
            throw ZolaError.invalidArgument("Link URL must start with http:// or https://")
        }
        let resolvedDomain: String = {
            if !domain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return domain.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return URL(string: cleanUrl)?.host?.replacingOccurrences(of: "^www\\.", with: "", options: .regularExpression) ?? cleanUrl
        }()
        let cleanTitle = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500))
        let resolvedTitle = (!cleanTitle.isEmpty && cleanTitle != "sendBubbleMessage") ? cleanTitle : resolvedDomain
        let cleanThumb = ZolaLinkMetadata.isPlaceholderThumb(thumbUrl) ? "" : ZolaAttachment.normalizeMediaUrl(thumbUrl)
        let cleanDesc = String(descriptionText.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2_000))
        let cleanCaption = String(caption.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2_000))
        let resolvedDesc: String = {
            if !cleanDesc.isEmpty && cleanDesc != "sendBubbleMessage" { return cleanDesc }
            if !cleanCaption.isEmpty && cleanCaption != "sendBubbleMessage" { return cleanCaption }
            return resolvedDomain
        }()
        var paramObj: [String: Any] = [
            "linkTitle": resolvedTitle,
            "mediaTitle": resolvedTitle,
            "src": resolvedDomain,
            "type": 0,
        ]
        if !cleanCaption.isEmpty {
            paramObj["caption"] = cleanCaption
        }
        let paramData = (try? JSONSerialization.data(withJSONObject: paramObj, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        let paramJson = String(decoding: paramData, as: UTF8.self)
        return try await sendMedia1To1(
            to: toId,
            subCmd: ZolaConstants.subCmdSendLinkBubble,
            href: cleanUrl,
            thumb: cleanThumb,
            title: resolvedTitle,
            description: resolvedDesc,
            action: "recommened.link",
            param: paramJson,
            caption: cleanCaption,
            quote: quote,
            dryRun: dryRun,
            clientIdMs: clientIdMs,
            trackingIdHex: trackingIdHex
        )
    }

    /// Sends a native 1-1 document/file bubble (`cmd = 130, innerCmd = 113, subCmd = 46`, `action = "share.file"`).
    public func sendFile1To1(
        to toId: Int64,
        fileUrl: String,
        fileName: String,
        fileSize: Int,
        fileExt: String = "",
        checksumMd5: String = "",
        caption: String = "",
        quote: ZolaQuote? = nil,
        dryRun: Bool = true,
        clientIdMs: Int64? = nil,
        trackingIdHex: String? = nil
    ) async throws -> ZolaSendReceipt {
        let cleanUrl = fileUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanName = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanUrl.isEmpty else {
            throw ZolaError.invalidArgument("fileUrl must not be empty")
        }
        guard !cleanName.isEmpty && cleanName != "sendBubbleMessage" else {
            throw ZolaError.invalidArgument("fileName must not be empty")
        }
        let cleanExt: String = {
            let trimmed = fileExt.trimmingCharacters(in: CharacterSet(charactersIn: ". \t\r\n")).lowercased()
            if !trimmed.isEmpty { return trimmed }
            let pathExt = (cleanName as NSString).pathExtension.lowercased()
            return pathExt.isEmpty ? "dat" : pathExt
        }()
        var paramObj: [String: Any] = [
            "fType": 1,
            "fileExt": cleanExt,
            "fileName": cleanName,
            "fileSize": max(0, fileSize),
        ]
        if !checksumMd5.isEmpty {
            paramObj["checksum"] = checksumMd5.lowercased()
        }
        let paramData = (try? JSONSerialization.data(withJSONObject: paramObj, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        let paramJson = String(decoding: paramData, as: UTF8.self)
        return try await sendMedia1To1(
            to: toId,
            subCmd: ZolaConstants.subCmdSendFile,
            href: cleanUrl,
            thumb: "",
            title: cleanName,
            description: caption,
            action: "share.file",
            param: paramJson,
            caption: caption,
            quote: quote,
            dryRun: dryRun,
            clientIdMs: clientIdMs,
            trackingIdHex: trackingIdHex
        )
    }

    /// Sends a native 1-1 photo bubble (`cmd = 130, innerCmd = 113, subCmd = 32`, `action = "chat.photo"`)
    /// matching Zalo iOS `261002` `-[RichMessageContent _getParamForPhoto]` (`0x100D95424`).
    public func sendPhoto1To1(
        to toId: Int64,
        photoUrl: String,
        thumbUrl: String = "",
        width: Int = 0,
        height: Int = 0,
        fileExt: String = "jpg",
        caption: String = "",
        quote: ZolaQuote? = nil,
        dryRun: Bool = true,
        clientIdMs: Int64? = nil,
        trackingIdHex: String? = nil,
        mediaGroup: ZolaMediaGroupLayout? = nil
    ) async throws -> ZolaSendReceipt {
        let cleanUrl = ZolaAttachment.normalizeMediaUrl(photoUrl.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !cleanUrl.isEmpty, cleanUrl.lowercased().hasPrefix("http") else {
            throw ZolaError.invalidArgument("photoUrl must be a valid HTTP(S) URL")
        }
        let rawThumb = thumbUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanThumb = rawThumb.isEmpty ? cleanUrl : ZolaAttachment.normalizeMediaUrl(rawThumb)
        let cleanExt: String = {
            let trimmed = fileExt.trimmingCharacters(in: CharacterSet(charactersIn: ". \t\r\n")).lowercased()
            return trimmed.isEmpty ? "jpg" : trimmed
        }()
        let safeW = width > 0 ? width : 720
        let safeH = height > 0 ? height : 720
        let paramJson = ZolaMediaGroupLayout.photoParamJSON(url: cleanUrl, thumb: cleanThumb,
            width: safeW, height: safeH, fileExt: cleanExt, mediaGroup: mediaGroup)
        return try await sendMedia1To1(
            to: toId,
            subCmd: ZolaConstants.subCmdSendPhoto,
            href: cleanUrl,
            thumb: cleanThumb,
            title: "",
            description: caption,
            action: "chat.photo",
            param: paramJson,
            caption: caption,
            quote: quote,
            dryRun: dryRun,
            clientIdMs: clientIdMs,
            trackingIdHex: trackingIdHex,
            extraDataJSON: mediaGroup?.extraDataJSON
        )
    }

    /// Uploads an image via Zalo iOS Native Pure-HTTP upload (`uploadFeature = 0`) and sends `subCmd = 32` (`action = "chat.photo"`).
    public func uploadAndSendPhoto(
        imageData: Data,
        fileName: String = "",
        width: Int = 0,
        height: Int = 0,
        threadId: Int64,
        type: ZolaThreadType = .user,
        caption: String = "",
        quote: ZolaQuote? = nil,
        dryRun: Bool = false,
        clientIdMs: Int64? = nil,
        mediaGroup: ZolaMediaGroupLayout? = nil
    ) async throws -> (photoUrl: String, thumbUrl: String, receipt: ZolaSendReceipt) {
        try assertSessionAlive()
        guard !imageData.isEmpty else {
            throw ZolaError.invalidArgument("Dữ liệu ảnh đang rỗng (0 byte)")
        }
        if type == .group || knownGroupIds().contains(threadId) {
            throw ZolaError.groupSendNotSupportedOverHttp
        }
        let sniffed = ZolaCrypto.sniffImageDimensions(imageData)
        let resolvedW = width > 0 ? width : (sniffed?.width ?? 720)
        let resolvedH = height > 0 ? height : (sniffed?.height ?? 720)
        let inferredExt: String = {
            let head = [UInt8](imageData.prefix(12))
            if head.count >= 4, head[0] == 0x89, head[1] == 0x50, head[2] == 0x4E, head[3] == 0x47 { return "png" }
            if head.count >= 6, head[0] == 0x47, head[1] == 0x49, head[2] == 0x46 { return "gif" }
            if head.count >= 12, head[0] == 0x52, head[1] == 0x49, head[2] == 0x46, head[3] == 0x46,
               head[8] == 0x57, head[9] == 0x45, head[10] == 0x42, head[11] == 0x50 { return "webp" }
            let fromName = (fileName.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).pathExtension.lowercased()
            return ["jpg", "jpeg", "png", "webp", "gif", "heic"].contains(fromName) ? fromName : "jpg"
        }()
        let rawName = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        let canonicalName = rawName.isEmpty ? "\(ZolaCrypto.md5Hex(imageData)).\(inferredExt)" : rawName

        if dryRun {
            let dryUrl = "https://photo-stal-18.zdn.vn/dryrun-\(clientIdMs ?? 0).\(inferredExt)"
            let receipt = try await sendPhoto1To1(
                to: threadId,
                photoUrl: dryUrl,
                thumbUrl: dryUrl,
                width: resolvedW,
                height: resolvedH,
                fileExt: inferredExt,
                caption: caption,
                quote: quote,
                dryRun: true,
                clientIdMs: clientIdMs,
                mediaGroup: mediaGroup
            )
            return (dryUrl, dryUrl, receipt)
        }

        let uploaded = try await uploadMediaNativeHTTP(
            fileData: imageData,
            fileName: canonicalName,
            toId: threadId,
            isGroup: false,
            uploadFeature: 0,
            width: resolvedW,
            height: resolvedH
        )
        let resolvedPhotoUrl: String = {
            for key in ["hdUrl", "org", "normalUrl", "fileUrl", "url", "hd", "href"] {
                let candidate = ZolaAttachment.normalizeMediaUrl(ZolaJSON.string(uploaded[key]))
                if candidate.hasPrefix("https://") { return candidate }
            }
            return Self.extractUploadedFileURL(uploaded) ?? ""
        }()
        guard resolvedPhotoUrl.hasPrefix("https://") else {
            throw ZolaError.transport(
                "Đã tải ảnh lên Zalo (fileId=\(ZolaJSON.string(uploaded["fileId"]))) nhưng phản hồi không chứa URL ảnh"
            )
        }
        let resolvedThumbUrl: String = {
            for key in ["thumbUrl", "thumb", "normalUrl"] {
                let candidate = ZolaAttachment.normalizeMediaUrl(ZolaJSON.string(uploaded[key]))
                if candidate.hasPrefix("https://") { return candidate }
            }
            return resolvedPhotoUrl
        }()
        let receipt = try await sendPhoto1To1(
            to: threadId,
            photoUrl: resolvedPhotoUrl,
            thumbUrl: resolvedThumbUrl,
            width: resolvedW,
            height: resolvedH,
            fileExt: inferredExt,
            caption: caption,
            quote: quote,
            dryRun: false,
            clientIdMs: clientIdMs,
            mediaGroup: mediaGroup
        )
        return (resolvedPhotoUrl, resolvedThumbUrl, receipt)
    }

    /// Uploads a document/file via Zalo iOS Native Pure-HTTP upload (`uploadFeature = 2`) and sends `subCmd = 46` (`action = "share.file"`).
    public func uploadAndSendFile(
        fileData: Data,
        fileName: String,
        threadId: Int64,
        type: ZolaThreadType = .user,
        caption: String = "",
        quote: ZolaQuote? = nil,
        dryRun: Bool = false,
        clientIdMs: Int64? = nil
    ) async throws -> (fileUrl: String, receipt: ZolaSendReceipt) {
        try assertSessionAlive()
        guard !fileData.isEmpty else {
            throw ZolaError.invalidArgument("Tệp đính kèm đang rỗng (0 byte)")
        }
        guard fileData.count <= Self.maxDocumentUploadBytes else {
            throw ZolaError.invalidArgument("Tệp vượt quá giới hạn an toàn 25 MB trên kênh Pure-HTTP")
        }
        if type == .group || knownGroupIds().contains(threadId) {
            throw ZolaError.groupSendNotSupportedOverHttp
        }
        let rawName = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        let ext = (rawName as NSString).pathExtension.lowercased()
        let safeExt = ext.isEmpty ? "dat" : ext
        let checksum = ZolaCrypto.md5Hex(fileData)
        let canonicalName = (rawName.isEmpty || rawName == "sendBubbleMessage") ? "\(checksum).\(safeExt)" : rawName

        if dryRun {
            let dryUrl = "https://f24-zpc.zdn.vn/dryrun-\(clientIdMs ?? 0)/\(ZolaRequestBuilder.urlEncode(canonicalName))"
            let receipt = try await sendFile1To1(
                to: threadId,
                fileUrl: dryUrl,
                fileName: canonicalName,
                fileSize: fileData.count,
                fileExt: safeExt,
                checksumMd5: checksum,
                caption: caption,
                quote: quote,
                dryRun: true,
                clientIdMs: clientIdMs
            )
            return (dryUrl, receipt)
        }

        let uploaded = try await uploadMediaNativeHTTP(
            fileData: fileData,
            fileName: canonicalName,
            toId: threadId,
            isGroup: false,
            uploadFeature: 2
        )
        let resolvedFileUrl: String = {
            for key in ["fileUrl", "normalUrl", "url", "org", "hdUrl", "hd", "href"] {
                let candidate = ZolaAttachment.normalizeMediaUrl(ZolaJSON.string(uploaded[key]))
                if candidate.hasPrefix("https://") { return candidate }
            }
            return Self.extractUploadedFileURL(uploaded) ?? ""
        }()
        guard resolvedFileUrl.hasPrefix("https://") else {
            throw ZolaError.transport(
                "Đã tải tệp lên Zalo (fileId=\(ZolaJSON.string(uploaded["fileId"]))) nhưng phản hồi không chứa URL tệp"
            )
        }
        let resolvedSize = max(fileData.count, ZolaJSON.int(uploaded["fileSize"]))
        let receipt = try await sendFile1To1(
            to: threadId,
            fileUrl: resolvedFileUrl,
            fileName: canonicalName,
            fileSize: resolvedSize,
            fileExt: safeExt,
            checksumMd5: checksum,
            caption: caption,
            quote: quote,
            dryRun: false,
            clientIdMs: clientIdMs
        )
        return (resolvedFileUrl, receipt)
    }

    /// Searches sticker IDs by keyword (`api.getStickers(keyword)`).
    public func getStickers(_ keyword: String) async throws -> [Int64] {
        guard !keyword.isEmpty else { return [] }
        let (_, data) = try await encryptedServiceCall(
            baseURL: Self.defaultStickerHost,
            endpoint: "api/message/sticker/suggest/stickers",
            params: ["keyword": keyword, "gif": 1, "guggy": 0],
            method: "GET"
        )
        let sids = (data["sids"] as? [Any]) ?? []
        return sids.map { ZolaJSON.int64($0) }.filter { $0 > 0 }
    }

    /// Fetches sticker metadata (`api.getStickersDetail(stickerIds)`).
    public func getStickersDetail(_ stickerId: Int64) async throws -> [String: Any] {
        guard stickerId > 0 else { throw ZolaError.invalidArgument("Invalid stickerId \(stickerId)") }
        return try await encryptedServiceCall(
            baseURL: Self.defaultStickerHost,
            endpoint: "api/message/sticker/sticker_detail",
            params: ["sid": stickerId],
            method: "GET"
        ).data
    }

    // MARK: 6. Conversation Settings, Labels, Quick Messages & Custom Calls

    /// Lists pinned conversation IDs (`api.getPinConversations()`).
    public func getPinConversations() async throws -> [String] {
        let (_, data) = try await encryptedServiceCall(
            baseURL: Self.defaultConversationHost,
            endpoint: "api/pinconvers/list",
            params: [:],
            method: "GET"
        )
        return (data["conversations"] as? [String]) ?? []
    }

    /// Pins or unpins conversations (`api.setPinnedConversations(pinned, conversations)`).
    @discardableResult
    public func setPinnedConversations(
        pinned: Bool,
        threadIds: [Int64],
        type: ZolaThreadType = .user,
        dryRun: Bool = false
    ) async throws -> Bool {
        try assertSessionAlive()
        guard !threadIds.isEmpty else { return true }
        if dryRun { return true }
        let prefix = type == .group ? "g" : "u"
        let formatted = threadIds.map { "\(prefix)\($0)" }
        _ = try await encryptedServiceCall(
            baseURL: Self.defaultConversationHost,
            endpoint: "api/pinconvers/updatev2",
            params: [
                "actionType": pinned ? 1 : 2,
                "conversations": formatted,
            ],
            method: "POST"
        )
        return true
    }

    /// Gets muted conversation settings (`api.getMute()`).
    public func getMute() async throws -> [String: Any] {
        if let res = try? await encryptedServiceCall(
            baseURL: Self.defaultProfileHost,
            endpoint: "api/social/profile/getmute",
            params: [:],
            method: "GET"
        ) {
            return res.data
        }
        return try await encryptedServiceCall(
            baseURL: Self.defaultProfileHost,
            endpoint: "api/conv/getmute",
            params: [:],
            method: "GET"
        ).data
    }

    /// Fetches and parses the muted conversations list (`ZolaMuteList`).
    public func fetchMuteList() async throws -> ZolaMuteList {
        let raw = try await getMute()
        return ZolaMuteList.fromServerDict(raw)
    }

    /// Mutes or unmutes a conversation (`api.setMute(params, threadId, type)`).
    @discardableResult
    public func setMute(
        threadId: Int64,
        durationSeconds: Int = -1,
        unmute: Bool = false,
        type: ZolaThreadType = .user,
        dryRun: Bool = false
    ) async throws -> Bool {
        try assertSessionAlive()
        guard threadId > 0 else { throw ZolaError.invalidArgument("Invalid threadId \(threadId)") }
        if dryRun { return true }
        _ = try await encryptedServiceCall(
            baseURL: Self.defaultProfileHost,
            endpoint: "api/conv/setmute",
            params: [
                "toid": String(threadId),
                "duration": durationSeconds,
                "action": unmute ? 3 : 1,
                "startTime": Int(Date().timeIntervalSince1970),
                "muteType": type == .user ? 1 : 2,
            ],
            method: "POST"
        )
        return true
    }

    /// Fetches Zalo Business / personal conversation labels (`api.getLabels()`).
    public func getLabels() async throws -> [String: Any] {
        try await encryptedServiceCall(
            baseURL: Self.defaultLabelHost,
            endpoint: "api/convlabel/get",
            params: [:],
            method: "GET",
            serviceKey: "label"
        ).data
    }

    /// Fetches and parses Zalo conversation labels (`ZolaLabelsResponse`).
    public func fetchLabels() async throws -> ZolaLabelsResponse {
        let raw = try await getLabels()
        return ZolaLabelsResponse.fromServerDict(raw)
    }

    /// Updates Zalo conversation labels (`api.updateLabels(payload)`).
    public func updateLabels(
        labelData: [ZolaLabel],
        version: Int,
        dryRun: Bool = false
    ) async throws -> ZolaLabelsResponse {
        try assertSessionAlive()
        if dryRun {
            return ZolaLabelsResponse(
                labelData: labelData,
                version: version + 1,
                lastUpdateTime: Int64(Date().timeIntervalSince1970 * 1000)
            )
        }
        let encodedLabelsData = try JSONSerialization.data(withJSONObject: labelData.map { $0.toServerDict() })
        let encodedLabelsString = String(data: encodedLabelsData, encoding: .utf8) ?? "[]"
        let data = try await encryptedServiceCall(
            baseURL: Self.defaultLabelHost,
            endpoint: "api/convlabel/update",
            params: [
                "labelData": encodedLabelsString,
                "version": version,
            ],
            method: "POST",
            serviceKey: "label"
        ).data
        return ZolaLabelsResponse.fromServerDict(data)
    }

    /// Fetches quick message templates (`api.getQuickMessageList()`).
    public func getQuickMessageList() async throws -> [String: Any] {
        try await encryptedServiceCall(
            baseURL: Self.defaultQuickMsgHost,
            endpoint: "api/quickmessage/list",
            params: ["version": 0, "lang": 0],
            method: "GET",
            serviceKey: "quick_message"
        ).data
    }

    /// Fetches Zalo Business auto-reply rules (`api.getAutoReplyList()`).
    public func getAutoReplyList() async throws -> [String: Any] {
        try await encryptedServiceCall(
            baseURL: Self.defaultAutoReplyHost,
            endpoint: "api/autoreply/list",
            params: ["version": 0, "cliLang": "vi"],
            method: "GET",
            serviceKey: "auto_reply"
        ).data
    }

    /// Fetches Zalo QR links for one or more users (`api.getQR(userId)`).
    /// Returns a map of `uid -> qrUrl` (e.g. `"https://zaloapp.com/qr/p/..."`).
    public func getQR(_ userIds: [Int64]) async throws -> [Int64: String] {
        let validIds = userIds.filter { $0 > 0 }
        guard !validIds.isEmpty else { return [:] }
        let raw = try await friendServiceCall(
            "mget-qr",
            params: ["fids": validIds.map { String($0) }],
            method: "POST"
        ).data
        let sources = (raw["sources"] as? [String: Any]) ?? raw
        var out: [Int64: String] = [:]
        for uid in validIds {
            if let qr = sources[String(uid)] as? String, !qr.isEmpty {
                out[uid] = qr
            }
        }
        return out
    }

    /// Executes a custom ZCID-encrypted Zalo API request (`api.custom(...)`).
    public func custom(
        url: String,
        params: [String: Any] = [:],
        method: String = "GET",
        allowedCodes: Set<Int> = []
    ) async throws -> [String: Any] {
        try await encryptedServiceCall(
            baseURL: url,
            endpoint: "",
            params: params,
            method: method,
            allowedCodes: allowedCodes
        ).data
    }
}
