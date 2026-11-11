import Foundation

internal enum ZolaJSON {
    static func int64(_ value: Any?, default fallback: Int64 = 0) -> Int64 {
        if let n = value as? NSNumber {
            return n.int64Value
        }
        if let i = value as? Int64 { return i }
        if let i = value as? Int { return Int64(i) }
        if let s = value as? String {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if let head = trimmed.split(separator: "_").first, let parsed = Int64(head) {
                return parsed
            }
            if let parsed = Int64(trimmed) {
                return parsed
            }
        }
        return fallback
    }

    static func int(_ value: Any?, default fallback: Int = 0) -> Int {
        Int(int64(value, default: Int64(fallback)))
    }

    static func string(_ value: Any?) -> String {
        if let s = value as? String { return s }
        if let n = value as? NSNumber { return n.stringValue }
        return ""
    }

    /// Returns the first candidate that converts to a non-empty trimmed string (avoiding `Optional<Any>` `??` short-circuiting on `""`).
    static func firstNonEmptyString(_ candidates: Any?...) -> String {
        for candidate in candidates {
            let s = string(candidate).trimmingCharacters(in: .whitespacesAndNewlines)
            if !s.isEmpty && s.lowercased() != "null" {
                return s
            }
        }
        return ""
    }

    static func double(_ value: Any?) -> Double? {
        if let n = value as? NSNumber {
            let d = n.doubleValue
            return d.isFinite ? d : nil
        }
        if let d = value as? Double {
            return d.isFinite ? d : nil
        }
        if let s = value as? String {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if let d = Double(trimmed), d.isFinite {
                return d
            }
        }
        return nil
    }

    /// Returns the first candidate that parses to a finite `Double` (avoiding `Optional<Any>` `??` stopping on `""`).
    static func firstDouble(_ candidates: Any?...) -> Double? {
        for candidate in candidates {
            if let d = double(candidate) {
                return d
            }
        }
        return nil
    }
}

public struct ZolaSessionBoxToken: Codable, Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public let name: String
    public let value: String
    public let domain: String
    public let expiresAtMs: Int64

    public init(name: String, value: String, domain: String = "", expiresAtMs: Int64 = 0) {
        self.name = name
        self.value = value
        self.domain = domain
        self.expiresAtMs = expiresAtMs
    }

    public var description: String {
        let fp = ZolaCrypto.sha256Hex8(Data(value.utf8))
        return "ZolaSessionBoxToken(name: \(name), domain: \(domain), valSha256_8: \(fp))"
    }

    public var debugDescription: String { description }
}

/// `SocketEntity` from the `data.socketServers` array of the iOS Native login response —
/// one TCP endpoint of the encrypted socket channel `2001` (`UXSocket`/`UXVoipSocket`).
/// `pubKey` is a 44-char base64 string = the server's 32-byte Curve25519 public key; never log it.
public struct ZolaSocketServer: Codable, Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public var hostName: String
    public var hostPort: Int
    /// `SocketEntity.key` — NSString on the wire but only ever consumed via `intValue`.
    public var key: Int
    public var pubKey: String
    public var tagName: String
    public var aesKey: String

    public init(
        hostName: String,
        hostPort: Int,
        key: Int = 0,
        pubKey: String = "",
        tagName: String = "",
        aesKey: String = ""
    ) {
        self.hostName = hostName
        self.hostPort = hostPort
        self.key = key
        self.pubKey = pubKey
        self.tagName = tagName
        self.aesKey = aesKey
    }

    public var description: String {
        let pkFp = pubKey.isEmpty ? "none" : ZolaCrypto.sha256Hex8(Data(pubKey.utf8))
        return "ZolaSocketServer(host='\(hostName):\(hostPort)', key=\(key), pubKey_sha256_8='\(pkFp)')"
    }

    public var debugDescription: String { description }

    public static func fromServerDict(_ raw: [String: Any]) -> ZolaSocketServer {
        ZolaSocketServer(
            hostName: ZolaJSON.string(raw["hostName"] ?? raw["host"]).trimmingCharacters(in: .whitespacesAndNewlines),
            hostPort: ZolaJSON.int(raw["hostPort"] ?? raw["port"]),
            key: ZolaJSON.int(raw["key"]),
            pubKey: ZolaJSON.string(raw["pubKey"]).trimmingCharacters(in: .whitespacesAndNewlines),
            tagName: ZolaJSON.string(raw["tagName"]).trimmingCharacters(in: .whitespacesAndNewlines),
            aesKey: ZolaJSON.string(raw["aesKey"]).trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// Validated 32-byte Curve25519 public key decoded from `pubKey`, or `nil` when missing/malformed.
    public var decodedPubKey32: Data? {
        let trimmed = pubKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let decoded = Data(base64Encoded: trimmed), decoded.count == 32 else {
            return nil
        }
        return decoded
    }

    public var effectivePort: UInt16 {
        (hostPort > 0 && hostPort <= Int(UInt16.max)) ? UInt16(hostPort) : 443
    }
}

public struct ZolaSession: Codable, Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public var uid: Int64
    public var sessionKey: String
    public var cryptKey: Data
    public var zcid: String
    public var zcidIsNative: Bool
    public var apiKey: String
    public var apiSecret: String
    public var femcHost: String
    public var mfetchHost: String
    public var groupApiHost: String
    public var tapiHost: String
    public var friendHost: String
    public var failoverUrl: String
    public var failoverUrlE2ee: String
    public var sendToMeId: Int64
    public var groupIds: [Int64]
    public var sessionBoxTokens: [String: ZolaSessionBoxToken]
    /// Zalo-assigned WPA service hosts (`zpw_service_map_v3`/`zpw_service_map_new`), service key -> base URL.
    /// Optional so sessions persisted before this field existed still decode.
    public var serviceHosts: [String: String]?
    /// `SocketEntity` list from `data.socketServers` (login response) — endpoints of socket channel `2001`.
    public var socketServers: [ZolaSocketServer]?
    /// `EncryptProtocolVer2` 16-char ASCII key id from `data.keySet.keySetId`; refreshed via `/api/helper/getKeySet?` on `-67`.
    public var keySetId: String?
    /// `EncryptProtocolVer2` key material from `data.keySet.keySetValue`. Secret — never log.
    public var keySetValue: String?
    /// `AuthenV3Aes` ids (`setParamsAuthenV3Aes:withPrivateKey:` needs both `>= 1`).
    public var aesPublicId: Int64?
    public var aesPrivateId: Int64?
    /// Login access token (`data.token`) used strictly to authenticate `POST /api/helper/getKeySet?`. Secret — never log.
    public var accessToken: String?
    /// Normalized E.164 phone (`+84...`) paired with `accessToken` for `POST /api/helper/getKeySet?`. Secret — never log.
    public var loginPhone: String?
    public var expiredCode: Int?
    public var expiredReason: String?

    public init(
        uid: Int64,
        sessionKey: String,
        cryptKey: Data = Data(),
        zcid: String = "",
        zcidIsNative: Bool = false,
        apiKey: String = ZolaConstants.defaultApiKey,
        apiSecret: String = ZolaConstants.defaultApiSecret,
        femcHost: String = ZolaConstants.defaultFemcHost,
        mfetchHost: String = ZolaConstants.defaultMfetchHost,
        groupApiHost: String = ZolaConstants.defaultGroupApiHost,
        tapiHost: String = ZolaConstants.defaultTapiHost,
        friendHost: String = ZolaConstants.defaultFriendHost,
        failoverUrl: String = ZolaConstants.defaultFailoverHost,
        failoverUrlE2ee: String = ZolaConstants.defaultFailoverUrlE2ee,
        sendToMeId: Int64 = ZolaConstants.defaultSendToMeId,
        groupIds: [Int64] = [],
        sessionBoxTokens: [String: ZolaSessionBoxToken] = [:],
        serviceHosts: [String: String]? = nil,
        socketServers: [ZolaSocketServer]? = nil,
        keySetId: String? = nil,
        keySetValue: String? = nil,
        aesPublicId: Int64? = nil,
        aesPrivateId: Int64? = nil,
        accessToken: String? = nil,
        loginPhone: String? = nil
    ) throws {
        self.uid = uid
        self.sessionKey = sessionKey
        self.cryptKey = cryptKey
        if zcid.isEmpty {
            let platform = ZolaCrypto.platformString(
                shortModel: ZolaConstants.defaultShortModel,
                osVersion: ZolaConstants.defaultIOSVersion,
                jailbroken: false
            )
            let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
            self.zcid = try ZolaCrypto.generateZCID(idfa: ZolaConstants.defaultIDFA, platform: platform, timestampMs: nowMs)
            self.zcidIsNative = false
        } else {
            self.zcid = zcid
            self.zcidIsNative = zcidIsNative
        }
        self.apiKey = apiKey
        self.apiSecret = apiSecret
        self.femcHost = femcHost
        self.mfetchHost = mfetchHost
        self.groupApiHost = groupApiHost
        self.tapiHost = tapiHost
        self.friendHost = Self.normalizeFriendHost(friendHost)
        self.failoverUrl = failoverUrl
        self.failoverUrlE2ee = failoverUrlE2ee
        self.sendToMeId = sendToMeId > 0 ? sendToMeId : ZolaConstants.defaultSendToMeId
        self.groupIds = groupIds
        self.sessionBoxTokens = sessionBoxTokens
        if let serviceHosts, !serviceHosts.isEmpty {
            var clean: [String: String] = [:]
            for (k, v) in serviceHosts where !ZolaClient.isForbiddenWebWpaURL(v) {
                clean[k] = (k == "friend") ? Self.normalizeFriendHost(v) : v
            }
            self.serviceHosts = clean.isEmpty ? nil : clean
        } else {
            self.serviceHosts = nil
        }
        if let socketServers, !socketServers.isEmpty {
            self.socketServers = socketServers.filter { !$0.hostName.isEmpty }
            if self.socketServers?.isEmpty == true { self.socketServers = nil }
        } else {
            self.socketServers = nil
        }
        let trimmedKeySetId = keySetId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.keySetId = (!trimmedKeySetId.isEmpty && trimmedKeySetId != "0") ? trimmedKeySetId : nil
        let trimmedKeySetValue = keySetValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.keySetValue = !trimmedKeySetValue.isEmpty ? trimmedKeySetValue : nil
        self.aesPublicId = (aesPublicId ?? 0) >= 1 ? aesPublicId : nil
        self.aesPrivateId = (aesPrivateId ?? 0) >= 1 ? aesPrivateId : nil
        let trimmedAccessToken = accessToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.accessToken = !trimmedAccessToken.isEmpty ? trimmedAccessToken : nil
        let trimmedLoginPhone = loginPhone?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.loginPhone = !trimmedLoginPhone.isEmpty ? trimmedLoginPhone : nil
        self.expiredCode = nil
        self.expiredReason = nil
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.uid = try c.decode(Int64.self, forKey: .uid)
        self.sessionKey = try c.decode(String.self, forKey: .sessionKey)
        self.cryptKey = try c.decodeIfPresent(Data.self, forKey: .cryptKey) ?? Data()
        self.zcid = try c.decodeIfPresent(String.self, forKey: .zcid) ?? ""
        self.zcidIsNative = try c.decodeIfPresent(Bool.self, forKey: .zcidIsNative) ?? false
        self.apiKey = try c.decodeIfPresent(String.self, forKey: .apiKey) ?? ZolaConstants.defaultApiKey
        self.apiSecret = try c.decodeIfPresent(String.self, forKey: .apiSecret) ?? ZolaConstants.defaultApiSecret
        self.femcHost = try c.decodeIfPresent(String.self, forKey: .femcHost) ?? ZolaConstants.defaultFemcHost
        self.mfetchHost = try c.decodeIfPresent(String.self, forKey: .mfetchHost) ?? ZolaConstants.defaultMfetchHost
        self.groupApiHost = try c.decodeIfPresent(String.self, forKey: .groupApiHost) ?? ZolaConstants.defaultGroupApiHost
        self.tapiHost = try c.decodeIfPresent(String.self, forKey: .tapiHost) ?? ZolaConstants.defaultTapiHost
        let rawFriendHost = try c.decodeIfPresent(String.self, forKey: .friendHost) ?? ZolaConstants.defaultFriendHost
        self.friendHost = Self.normalizeFriendHost(rawFriendHost)
        self.failoverUrl = try c.decodeIfPresent(String.self, forKey: .failoverUrl) ?? ZolaConstants.defaultFailoverHost
        self.failoverUrlE2ee = try c.decodeIfPresent(String.self, forKey: .failoverUrlE2ee) ?? ZolaConstants.defaultFailoverUrlE2ee
        let decodedSendToMeId = try c.decodeIfPresent(Int64.self, forKey: .sendToMeId) ?? ZolaConstants.defaultSendToMeId
        self.sendToMeId = decodedSendToMeId > 0 ? decodedSendToMeId : ZolaConstants.defaultSendToMeId
        self.groupIds = try c.decodeIfPresent([Int64].self, forKey: .groupIds) ?? []
        self.sessionBoxTokens = try c.decodeIfPresent([String: ZolaSessionBoxToken].self, forKey: .sessionBoxTokens) ?? [:]
        if let rawHosts = try c.decodeIfPresent([String: String].self, forKey: .serviceHosts), !rawHosts.isEmpty {
            var clean: [String: String] = [:]
            for (k, v) in rawHosts where !ZolaClient.isForbiddenWebWpaURL(v) {
                clean[k] = (k == "friend") ? Self.normalizeFriendHost(v) : v
            }
            self.serviceHosts = clean.isEmpty ? nil : clean
        } else {
            self.serviceHosts = nil
        }
        self.socketServers = try c.decodeIfPresent([ZolaSocketServer].self, forKey: .socketServers)
        if let strKeySetId = try? c.decodeIfPresent(String.self, forKey: .keySetId) {
            let trimmed = strKeySetId.trimmingCharacters(in: .whitespacesAndNewlines)
            self.keySetId = (!trimmed.isEmpty && trimmed != "0") ? trimmed : nil
        } else if let intKeySetId = try? c.decodeIfPresent(Int.self, forKey: .keySetId), intKeySetId > 0 {
            self.keySetId = String(intKeySetId)
        } else {
            self.keySetId = nil
        }
        let decodedKsVal = (try c.decodeIfPresent(String.self, forKey: .keySetValue))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.keySetValue = !decodedKsVal.isEmpty ? decodedKsVal : nil
        self.aesPublicId = try c.decodeIfPresent(Int64.self, forKey: .aesPublicId)
        self.aesPrivateId = try c.decodeIfPresent(Int64.self, forKey: .aesPrivateId)
        let decodedAccessTok = (try c.decodeIfPresent(String.self, forKey: .accessToken))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.accessToken = !decodedAccessTok.isEmpty ? decodedAccessTok : nil
        let decodedPhone = (try c.decodeIfPresent(String.self, forKey: .loginPhone))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.loginPhone = !decodedPhone.isEmpty ? decodedPhone : nil
        self.expiredCode = try c.decodeIfPresent(Int.self, forKey: .expiredCode)
        self.expiredReason = try c.decodeIfPresent(String.self, forKey: .expiredReason)
    }

    /// Returns `true` when `accessToken` and `loginPhone` are both available to authenticate `POST /api/helper/getKeySet?`.
    public var canRefreshKeySet: Bool {
        guard let tok = accessToken?.trimmingCharacters(in: .whitespacesAndNewlines), !tok.isEmpty,
              let ph = loginPhone?.trimmingCharacters(in: .whitespacesAndNewlines), !ph.isEmpty
        else {
            return false
        }
        return true
    }

    /// Validated 32-byte `AES-256-GCM` symmetric key decoded from `keySetValue` (`0x103b5b99c` / `0x103ea0e4c`).
    public var decodedKeySetValue32: Data? {
        guard let raw = keySetValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              let decoded = Data(base64Encoded: raw),
              decoded.count == 32
        else {
            return nil
        }
        return decoded
    }

    /// Returns `true` when both `keySetId` (1..255 ASCII bytes) and `keySetValue` (32-byte Base64) are ready for `EncryptProtocolVer2`.
    public var hasValidKeySet: Bool {
        guard let ksId = keySetId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !ksId.isEmpty,
              ksId.utf8.count <= 255,
              decodedKeySetValue32 != nil
        else {
            return false
        }
        return true
    }

    /// Endpoints from `socketServers` that carry a valid 32-byte Curve25519 `pubKey`.
    public var encryptedSocketEndpoints: [(host: String, port: UInt16, serverPubKeyBase64: String)] {
        guard let servers = socketServers else { return [] }
        return servers.compactMap { srv in
            let host = srv.hostName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !host.isEmpty, srv.decodedPubKey32 != nil else { return nil }
            return (host: host, port: srv.effectivePort, serverPubKeyBase64: srv.pubKey.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    public var hasValidSocketServers: Bool {
        !encryptedSocketEndpoints.isEmpty
    }

    public var hasSocketEncryptionMaterial: Bool {
        hasValidKeySet && hasValidSocketServers
    }

    /// Normalizes legacy `friend.talk.zing.vn` or empty friend hosts onto `friend.api.zaloapp.com` (`service_map.bin`).
    public static func normalizeFriendHost(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        if trimmed.isEmpty || trimmed.lowercased().contains("friend.talk.zing.vn") {
            return ZolaConstants.defaultFriendHost
        }
        return trimmed
    }

    /// Normalizes a `zpw_service_map_*` payload into `service key -> base URL`.
    /// Handles both `{key: ["url1", "url2"]}` (v3) and `{key: "url"}` (`_new`) shapes.
    /// Entries pointing at forbidden Zalo Web `*-wpa.chat.zalo.me` hosts are dropped.
    public static func serviceHosts(fromServiceMap raw: Any?) -> [String: String] {
        guard let dict = raw as? [String: Any] else { return [:] }
        var out: [String: String] = [:]
        for (key, value) in dict {
            if let arr = value as? [Any] {
                if let first = arr.lazy.compactMap({ $0 as? String }).first(where: { !$0.isEmpty && !ZolaClient.isForbiddenWebWpaURL($0) }) {
                    out[key] = (key == "friend") ? normalizeFriendHost(first) : first
                }
            } else if let s = value as? String, !s.isEmpty, !ZolaClient.isForbiddenWebWpaURL(s) {
                out[key] = (key == "friend") ? normalizeFriendHost(s) : s
            }
        }
        return out
    }

    public var isExpired: Bool { expiredCode != nil }
    /// `true` when the session still carries a non-empty `sessionKey` and has not tripped the
    /// circuit breaker — the minimum precondition before opening a live `UXChatSocket` (`0x7d0`).
    public var canConnectLiveVoipSocket: Bool {
        !isExpired && !sessionKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    public var cryptKeySha256_8: String { ZolaCrypto.sha256Hex8(cryptKey) }
    public var sessionKeySha256_8: String { ZolaCrypto.sha256Hex8(Data(sessionKey.utf8)) }

    public mutating func markExpired(code: Int, reason: String) {
        expiredCode = code
        expiredReason = reason
    }

    public func sessionBoxToken(for urlString: String) -> ZolaSessionBoxToken? {
        guard let host = URL(string: urlString)?.host?.lowercased() else {
            return sessionBoxTokens["*"]
        }
        if let exact = sessionBoxTokens[host] { return exact }
        for (dom, tok) in sessionBoxTokens where dom != "*" && host.hasSuffix(dom.lowercased()) {
            return tok
        }
        return sessionBoxTokens["*"]
    }

    public var description: String {
        let state = isExpired ? "expired(\(expiredCode ?? 0))" : "active"
        return "ZolaSession(uid: \(uid), state: \(state), zcidNative: \(zcidIsNative), ckLen: \(cryptKey.count), ckSha256_8: \(cryptKeySha256_8), skSha256_8: \(sessionKeySha256_8))"
    }

    public var debugDescription: String { description }
}

public struct ZolaUser: Codable, Sendable, Identifiable, Equatable {
    public var id: Int64 { uid }
    public let uid: Int64
    public let displayName: String
    public let zaloName: String
    public let avatarUrl: String
    public let fullAvatarUrl: String
    public let phone: String
    public let gender: Int
    public let statusText: String
    public let globalId: String
    public let isFriend: Bool
    /// Profile cover photo (`cover` in native `getProfile`). Optional so older cached users decode.
    public let coverUrl: String?
    /// Birthday as Zalo shares it (`sdob`, e.g. "dd/MM/yyyy" or "dd/MM" when the year is hidden).
    public let birthday: String?

    public init(
        uid: Int64,
        displayName: String,
        zaloName: String = "",
        avatarUrl: String = "",
        fullAvatarUrl: String = "",
        phone: String = "",
        gender: Int = 0,
        statusText: String = "",
        globalId: String = "",
        isFriend: Bool = false,
        coverUrl: String? = nil,
        birthday: String? = nil
    ) {
        self.uid = uid
        self.displayName = displayName
        self.zaloName = zaloName
        self.avatarUrl = avatarUrl
        self.fullAvatarUrl = fullAvatarUrl
        self.phone = phone
        self.gender = gender
        self.statusText = statusText
        self.globalId = globalId
        self.isFriend = isFriend
        self.coverUrl = coverUrl
        self.birthday = birthday
    }

    public static func fromServerDict(_ raw: [String: Any], isFriend defaultFriend: Bool = false) -> ZolaUser {
        let uid = ZolaJSON.int64(raw["userId"] ?? raw["uid"] ?? raw["id"] ?? raw["zaloId"])
        let dName = [
            raw["displayName"],
            raw["dName"],
            raw["dpn"],
            raw["dname"],
            raw["display_name"],
            raw["zaloName"],
            raw["zalo_name"],
            raw["uname"],
            raw["username"],
            raw["name"],
        ]
            .compactMap { ZolaJSON.string($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? (uid > 0 ? "UID \(uid)" : "")
        let zName = ZolaJSON.string(raw["zaloName"] ?? raw["zalo_name"] ?? raw["uname"] ?? raw["username"])
        let avt = ZolaJSON.string(raw["avatar"] ?? raw["avt"])
        // `cover` is the profile cover photo (verified on a live native getProfile), never a larger avatar.
        let fullAvt = ZolaJSON.string(raw["fullAvt"]).isEmpty ? avt : ZolaJSON.string(raw["fullAvt"])
        let cover = [raw["cover"], raw["bgavatar"], raw["bgavatarurl"], raw["coverUrl"]]
            .compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        // Native getProfile carries the bio as `stt`; numeric flags are never shown as text.
        let bio = [raw["status"], raw["stt"]]
            .compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""
        let birthday = (raw["sdob"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let isFr = raw["isFr"] != nil ? (ZolaJSON.int(raw["isFr"]) != 0) : defaultFriend
        let resolvedPhone = [
            raw["phoneNumber"],
            raw["phonenumber"],
            raw["phone"],
            raw["mobile"],
            raw["last_mobile"],
            raw["contactPhoneNumber"],
            raw["e64PhoneNumber"],
        ]
            .compactMap { ZolaJSON.string($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""
        return ZolaUser(
            uid: uid,
            displayName: dName,
            zaloName: zName,
            avatarUrl: avt,
            fullAvatarUrl: fullAvt,
            phone: resolvedPhone,
            gender: ZolaJSON.int(raw["gender"] ?? raw["ged"]),
            statusText: bio,
            globalId: ZolaJSON.string(raw["globalId"]),
            isFriend: isFr,
            coverUrl: cover,
            birthday: (birthday?.isEmpty ?? true) ? nil : birthday
        )
    }

    public var isLockedAccount: Bool {
        let lower = displayName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return lower.contains("tài khoản bị khóa")
            || lower.contains("tai khoan bi khoa")
            || lower.contains("tài khoản đã khóa")
            || lower.contains("account locked")
    }

    /// Extracts the integer `?time=<epoch>` (or `?t=<epoch>`) query parameter from a Zalo CDN avatar URL.
    public static func avatarTimestamp(from urlString: String) -> Int64? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let comps = URLComponents(string: trimmed),
           let item = comps.queryItems?.first(where: {
               let name = $0.name.lowercased()
               return name == "time" || name == "t"
           }),
           let value = item.value,
           let parsed = Int64(value),
           parsed > 0 {
            return parsed
        }
        if let range = trimmed.range(of: #"(?:[?&](?:time|t)=)(\d+)"#, options: [.regularExpression, .caseInsensitive]) {
            let digits = trimmed[range].filter(\.isNumber)
            if let parsed = Int64(digits), parsed > 0 {
                return parsed
            }
        }
        return nil
    }

    /// Resolves between an existing cached avatar URL and an incoming avatar URL by comparing `?time=` freshness.
    public static func preferFresherAvatarUrl(existing: String, incoming: String) -> String {
        let cleanExisting = existing.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanIncoming = incoming.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanIncoming.isEmpty { return cleanExisting }
        if cleanExisting.isEmpty { return cleanIncoming }
        if cleanExisting == cleanIncoming { return cleanIncoming }
        let existingTs = avatarTimestamp(from: cleanExisting)
        let incomingTs = avatarTimestamp(from: cleanIncoming)
        if let eTs = existingTs, let iTs = incomingTs {
            return iTs >= eTs ? cleanIncoming : cleanExisting
        }
        if existingTs != nil && incomingTs == nil {
            let baseExisting = cleanExisting.split(separator: "?", maxSplits: 1).first.map(String.init) ?? cleanExisting
            let baseIncoming = cleanIncoming.split(separator: "?", maxSplits: 1).first.map(String.init) ?? cleanIncoming
            if baseExisting == baseIncoming {
                return cleanExisting
            }
        }
        return cleanIncoming
    }
}

public struct ZolaGroup: Codable, Sendable, Identifiable, Equatable {
    public var id: Int64 { gid }
    public let gid: Int64
    public let name: String
    public let desc: String
    public let avatarUrl: String
    public let fullAvatarUrl: String
    public let totalMembers: Int
    public let creatorId: Int64
    public let adminIds: [Int64]
    public let memberIds: [Int64]
    public let members: [ZolaUser]
    public let isE2ee: Bool
    public let groupType: Int
    public let versionTs: Int64
    /// `setting` flags (`0x100d6a2dc`); `nil` when the server response did not carry the key.
    public let lockSendMsg: Bool?
    public let lockViewMember: Bool?
    public let joinAppr: Int?
    public let signAdminMsg: Bool?
    public let setTopicOnly: Bool?
    /// `extraInfo.mentionAll` (`GroupEntity _ruleMentionAll`): `1` everyone, `2` owner/admins (`0x100984cb0`).
    public let ruleMentionAll: Int?

    public init(
        gid: Int64,
        name: String,
        desc: String = "",
        avatarUrl: String = "",
        fullAvatarUrl: String = "",
        totalMembers: Int = 0,
        creatorId: Int64 = 0,
        adminIds: [Int64] = [],
        memberIds: [Int64] = [],
        members: [ZolaUser] = [],
        isE2ee: Bool = false,
        groupType: Int = 0,
        versionTs: Int64 = 0,
        lockSendMsg: Bool? = nil,
        lockViewMember: Bool? = nil,
        joinAppr: Int? = nil,
        signAdminMsg: Bool? = nil,
        setTopicOnly: Bool? = nil,
        ruleMentionAll: Int? = nil
    ) {
        self.gid = gid
        self.name = name
        self.desc = desc
        self.avatarUrl = avatarUrl
        self.fullAvatarUrl = fullAvatarUrl
        self.totalMembers = totalMembers
        self.creatorId = creatorId
        self.adminIds = adminIds
        self.memberIds = memberIds
        self.members = members
        self.isE2ee = isE2ee
        self.groupType = groupType
        self.versionTs = versionTs
        self.lockSendMsg = lockSendMsg
        self.lockViewMember = lockViewMember
        self.joinAppr = joinAppr
        self.signAdminMsg = signAdminMsg
        self.setTopicOnly = setTopicOnly
        self.ruleMentionAll = ruleMentionAll
    }

    /// Group sub-objects arrive either as a dictionary or as a JSON string (`0x100d67e34`).
    private static func dictionaryValue(_ value: Any?) -> [String: Any]? {
        if let dict = value as? [String: Any] { return dict }
        guard let text = value as? String, let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    public static func fromServerDict(_ raw: [String: Any]) -> ZolaGroup {
        let gid = ZolaJSON.int64(raw["groupId"] ?? raw["id"] ?? raw["gid"])
        let name = ZolaJSON.string(raw["name"]).isEmpty ? "Nhóm \(gid)" : ZolaJSON.string(raw["name"])
        let avt = ZolaJSON.string(raw["avt"] ?? raw["avatar"])
        let fullAvt = ZolaJSON.string(raw["fullAvt"]).isEmpty ? avt : ZolaJSON.string(raw["fullAvt"])

        var adminSet = Set<Int64>()
        if let admins = (raw["adminIds"] ?? raw["admins"]) as? [Any] {
            for item in admins {
                let aid = (item as? [String: Any]).map { ZolaJSON.int64($0["id"]) } ?? ZolaJSON.int64(item)
                if aid > 0 { adminSet.insert(aid) }
            }
        }

        var membersMap: [Int64: ZolaUser] = [:]
        for key in ["currentMems", "updateMems", "members"] {
            if let arr = raw[key] as? [[String: Any]] {
                for dict in arr {
                    let u = ZolaUser.fromServerDict(dict)
                    if u.uid > 0 { membersMap[u.uid] = u }
                }
            }
        }

        var memIdSet = Set(membersMap.keys)
        if let mids = raw["memberIds"] as? [Any] {
            for item in mids {
                let mid = (item as? [String: Any]).map { ZolaJSON.int64($0["id"]) } ?? ZolaJSON.int64(item)
                if mid > 0 { memIdSet.insert(mid) }
            }
        }

        let total = max(ZolaJSON.int(raw["totalMembers"] ?? raw["numMember"]), memIdSet.count)
        let setting = dictionaryValue(raw["setting"] ?? raw["groupSetting"]) ?? [:]
        let extraInfo = dictionaryValue(raw["extraInfo"]) ?? [:]
        func settingFlag(_ key: String) -> Bool? {
            setting[key].map { ZolaJSON.int($0) != 0 }
        }
        return ZolaGroup(
            gid: gid,
            name: name,
            desc: ZolaJSON.string(raw["desc"]),
            avatarUrl: avt,
            fullAvatarUrl: fullAvt,
            totalMembers: total,
            creatorId: ZolaJSON.int64(raw["creatorId"]),
            adminIds: adminSet.sorted(),
            memberIds: memIdSet.sorted(),
            members: membersMap.keys.sorted().compactMap { membersMap[$0] },
            isE2ee: ZolaJSON.int(raw["isE2ee"]) != 0,
            groupType: ZolaJSON.int(raw["type"]),
            versionTs: ZolaJSON.int64(raw["ts"] ?? raw["version"]),
            lockSendMsg: settingFlag("lockSendMsg"),
            lockViewMember: settingFlag("lockViewMember"),
            joinAppr: setting["joinAppr"].map { ZolaJSON.int($0) },
            signAdminMsg: settingFlag("signAdminMsg"),
            setTopicOnly: settingFlag("setTopicOnly"),
            ruleMentionAll: extraInfo["mentionAll"].map { ZolaJSON.int($0) }
        )
    }
}

public struct ZolaAttachment: Codable, Sendable, Equatable {
    public let kind: String
    public let url: String
    public let thumbUrl: String
    public let title: String
    public let descriptionText: String
    public let width: Int
    public let height: Int
    public let durationMs: Int
    public let fileSize: Int
    public let stickerId: Int64
    public let cateId: Int64
    public let fileExt: String
    /// Native photo album identity/position; nil for single photos and old caches.
    public let mediaGroup: ZolaMediaGroupLayout?

    public init(
        kind: String,
        url: String = "",
        thumbUrl: String = "",
        title: String = "",
        descriptionText: String = "",
        width: Int = 0,
        height: Int = 0,
        durationMs: Int = 0,
        fileSize: Int = 0,
        stickerId: Int64 = 0,
        cateId: Int64 = 0,
        fileExt: String = "",
        mediaGroup: ZolaMediaGroupLayout? = nil
    ) {
        self.kind = kind
        self.url = url
        self.thumbUrl = thumbUrl
        self.title = title
        self.descriptionText = descriptionText
        self.width = width
        self.height = height
        self.durationMs = durationMs
        self.fileSize = fileSize
        self.stickerId = stickerId
        self.cateId = cateId
        self.fileExt = fileExt
        self.mediaGroup = kind == "photo" ? mediaGroup : nil
    }

    public static func stickerCdnUrl(stickerId: Int64, cateId: Int64 = 0) -> String {
        guard stickerId > 0 else { return "" }
        if cateId == 0 && (1...30).contains(stickerId) {
            return "https://stc-chat.zdn.vn/images/stickers/default/thumb/\(stickerId).png"
        }
        return "https://zalo-api.zadn.vn/api/emoticon/sticker/webpc?eid=\(stickerId)&size=130"
    }

    /// Returns `true` when the URL points at Zalo's emoticon/sticker CDN (including classic Onion default stickers).
    public static func isEmoticonStickerURL(_ raw: String) -> Bool {
        let lower = raw.lowercased()
        return lower.contains("/emoticon/")
            || lower.contains("emoticon.zadn.vn")
            || lower.contains("stc-chat.zdn.vn/images/stickers/default/")
    }

    /// Extracts the `eid=<id>` query parameter or classic default sticker ID (`1...30`) from a sticker CDN URL.
    public static func extractStickerEid(from raw: String) -> Int64 {
        if let comps = URLComponents(string: raw),
           let v = comps.queryItems?.first(where: { $0.name.lowercased() == "eid" })?.value {
            let n = ZolaJSON.int64(v)
            if n > 0 { return n }
        }
        if let range = raw.range(of: #"eid=(\d+)"#, options: .regularExpression) {
            return ZolaJSON.int64(raw[range].dropFirst(4))
        }
        if let range = raw.range(of: #"images/stickers/default/(?:thumb/)?(\d+)\.(?:png|gif)"#, options: [.regularExpression, .caseInsensitive]) {
            let matched = String(raw[range])
            let digits = matched.split(separator: "/").last?.split(separator: ".").first.map(String.init) ?? ""
            let n = ZolaJSON.int64(digits)
            if (1...30).contains(n) { return n }
        }
        return 0
    }

    private static let documentExtensions: Set<String> = [
        "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx",
        "zip", "rar", "7z", "tar", "gz", "csv", "txt", "rtf",
        "json", "xml", "apk", "ipa", "dmg", "pages", "numbers", "key",
    ]

    public static func normalizeMediaUrl(_ raw: String) -> String {
        var result = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { return "" }
        if result.hasPrefix("//") {
            result = "https:" + result
        } else if result.lowercased().hasPrefix("http://") {
            let lower = result.lowercased()
            if lower.contains("zdn.vn") || lower.contains("zadn.vn") || lower.contains("zalo") {
                result = "https://" + String(result.dropFirst("http://".count))
            }
        }
        let lowerResult = result.lowercased()
        if (lowerResult.contains("zpg") || lowerResult.contains("group.zp")) && lowerResult.contains(".zdn.vn/jpg/") {
            result = result.replacingOccurrences(of: ".zdn.vn/jpg/", with: ".zdn.vn/")
        }
        return result
    }

    public static func fromRaw(msgType: String, attach: [String: Any]) -> ZolaAttachment {
        let mt = msgType.lowercased()
        var paramsDict: [String: Any]?
        if let pd = attach["params"] as? [String: Any] {
            paramsDict = pd
        } else if let ps = attach["params"] as? String,
                  let pdata = ps.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: pdata) as? [String: Any] {
            paramsDict = parsed
        }

        let action = ZolaJSON.firstNonEmptyString(attach["action"], paramsDict?["action"]).lowercased()
        let rawTitle = ZolaJSON.firstNonEmptyString(
            attach["title"],
            attach["fileName"],
            paramsDict?["fileName"],
            paramsDict?["title"],
            paramsDict?["mediaTitle"],
            paramsDict?["linkTitle"]
        )
        let rawDesc = ZolaJSON.firstNonEmptyString(
            attach["description"],
            attach["desc"],
            paramsDict?["description"],
            paramsDict?["desc"],
            paramsDict?["caption"],
            paramsDict?["subtitle"],
            paramsDict?["notifyTxt"],
            paramsDict?["msg"],
            paramsDict?["phone"]
        )

        if action == "recommened.calltime" || action == "recommend.calltime" || action.contains("misscall") || rawTitle == "sendBubbleMessage" || mt.contains("call") {
            let durationSec = ZolaJSON.int(paramsDict?["duration"] ?? attach["duration"])
            let callType = ZolaJSON.int(paramsDict?["calltype"] ?? paramsDict?["callType"] ?? attach["calltype"])
            let isCaller = ZolaJSON.int(paramsDict?["isCaller"] ?? attach["isCaller"])
            let isVideo = callType == 1
            let isMissed = durationSec <= 0 || action.contains("misscall")
            let kindLabel = isVideo ? "video" : "thoại"
            let callTitle: String
            if isMissed {
                callTitle = isCaller == 1 ? "Cuộc gọi \(kindLabel) đi · không trả lời" : "Cuộc gọi \(kindLabel) nhỡ"
            } else {
                let mins = durationSec / 60
                let secs = durationSec % 60
                let durStr = mins > 0 ? "\(mins) phút \(secs) giây" : "\(secs) giây"
                callTitle = "Cuộc gọi \(kindLabel) \(isCaller == 1 ? "đi" : "đến") · \(durStr)"
            }
            return ZolaAttachment(
                kind: "call",
                url: isVideo ? "video" : "audio",
                thumbUrl: "",
                title: callTitle,
                descriptionText: isMissed ? "missed" : (isCaller == 1 ? "outgoing" : "incoming"),
                width: 0,
                height: 0,
                durationMs: max(0, durationSec * 1000)
            )
        }

        let candidateMapHref = ZolaJSON.firstNonEmptyString(attach["href"], paramsDict?["href"], attach["url"], paramsDict?["url"]).lowercased()
        let isAppleMapsPinCard = candidateMapHref.contains("maps.apple.com/?ll=")
        if mt == "chat.location.new" || mt.contains("location") || action.contains("location") || isAppleMapsPinCard {
            let lat = ZolaJSON.firstDouble(paramsDict?["lat"], paramsDict?["latitude"], attach["lat"], attach["latitude"])
            let lon = ZolaJSON.firstDouble(paramsDict?["lon"], paramsDict?["lng"], paramsDict?["longitude"], attach["lon"], attach["lng"], attach["longitude"])
            let hasCoords = lat != nil && lon != nil && (abs(lat ?? 0) > 0.00001 || abs(lon ?? 0) > 0.00001)
            let locUrl: String
            if let lat, let lon, hasCoords {
                locUrl = String(format: "geo:%.6f,%.6f", lat, lon)
            } else {
                locUrl = Self.normalizeMediaUrl(
                    ZolaJSON.firstNonEmptyString(attach["href"], paramsDict?["href"], attach["url"], paramsDict?["url"])
                )
            }
            let locThumb = Self.normalizeMediaUrl(
                ZolaJSON.firstNonEmptyString(attach["thumb"], attach["thumbUrl"], paramsDict?["thumb"], paramsDict?["thumbUrl"])
            )
            let locTitle = (rawTitle.isEmpty || rawTitle == "sendBubbleMessage") ? "Vị trí đã chia sẻ" : rawTitle
            let locDesc: String = {
                let clean = rawDesc == "sendBubbleMessage" ? "" : rawDesc
                if !clean.isEmpty && clean != locTitle { return clean }
                if let lat, let lon, hasCoords {
                    return String(format: "%.5f, %.5f", lat, lon)
                }
                return ""
            }()
            return ZolaAttachment(
                kind: "location",
                url: locUrl,
                thumbUrl: locThumb,
                title: locTitle,
                descriptionText: locDesc
            )
        }

        let stickerCandidateUrls: [Any?] = [
            attach["href"], attach["thumb"], attach["hd"], attach["hdUrl"], attach["normalUrl"],
            attach["oriUrl"], attach["rawUrl"], attach["url"], attach["stickerUrl"], attach["webpUrl"],
            paramsDict?["href"], paramsDict?["thumb"], paramsDict?["hd"], paramsDict?["hdUrl"], paramsDict?["normalUrl"],
            paramsDict?["oriUrl"], paramsDict?["rawUrl"], paramsDict?["url"], paramsDict?["stickerUrl"], paramsDict?["webpUrl"],
        ]
        let hasEmoticonStickerURL = stickerCandidateUrls.contains { Self.isEmoticonStickerURL(ZolaJSON.string($0)) }
        let explicitFileExt = ZolaJSON.firstNonEmptyString(attach["fileExt"], paramsDict?["fileExt"])
            .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
            .lowercased()
        let nonEmptyHrefCandidate = ZolaJSON.firstNonEmptyString(
            attach["href"],
            attach["hdUrl"],
            attach["normalUrl"],
            attach["url"],
            paramsDict?["hd"],
            paramsDict?["hdUrl"],
            paramsDict?["rawUrl"],
            paramsDict?["href"],
            paramsDict?["normalUrl"],
            paramsDict?["url"]
        )
        let isSystemAction = action == "show.profile"
            || action.hasPrefix("msginfo")
            || action == "recommened.fst"
            || action == "recommend.fst"
            || action == "chat.tip"

        let explicitCardUid: Int64 = [attach["uid"], paramsDict?["uid"]]
            .map { ZolaJSON.int64($0) }
            .first(where: { $0 > 0 }) ?? 0

        var kind: String
        if hasEmoticonStickerURL || mt.contains("sticker") || mt.contains("emoticon") || attach["stickerId"] != nil || (attach["catId"] != nil && attach["id"] != nil) || (attach["cateId"] != nil && attach["stickerId"] != nil) {
            kind = "sticker"
        } else if action == "chat.video.msg" || mt.contains("video") || (!nonEmptyHrefCandidate.isEmpty && (paramsDict?["video_width"] != nil || paramsDict?["video_height"] != nil)) {
            kind = "video"
        } else if mt.contains("voice") || mt.contains("audio") {
            kind = "voice"
        } else if action == "share.file" || mt.contains("file") || (!explicitFileExt.isEmpty && Self.documentExtensions.contains(explicitFileExt)) {
            kind = "file"
        } else if mt.contains("ecard") || action.contains("ecard") {
            kind = "ecard"
        } else if mt.contains("photo") || mt.contains("image") || mt.contains("gif") || mt.contains("doodle") {
            kind = "photo"
        } else if action == "recommened.user" || action == "recommend.user" || mt.contains("card") || mt.contains("contact") || (!isSystemAction && mt.contains("recommend") && explicitCardUid > 0) {
            kind = "card"
        } else if isSystemAction {
            kind = "unknown"
        } else if action == "recommened.link" || action == "recommend.link" || mt == "chat.link" {
            kind = "link"
        } else if !nonEmptyHrefCandidate.isEmpty {
            let hrefStr = nonEmptyHrefCandidate.lowercased()
            let hrefExt = ((hrefStr.split(separator: "?").first.map(String.init) ?? hrefStr) as NSString).pathExtension.lowercased()
            if hrefStr.hasSuffix(".mp4") || hrefStr.hasSuffix(".mov") || hrefExt == "mp4" || hrefExt == "mov" {
                kind = "video"
            } else if hrefStr.hasSuffix(".aac") || hrefStr.hasSuffix(".m4a") || hrefStr.hasSuffix(".mp3") || hrefStr.hasSuffix(".amr") || ["aac", "m4a", "mp3", "amr"].contains(hrefExt) {
                kind = "voice"
            } else if hrefStr.hasSuffix(".jpg") || hrefStr.hasSuffix(".jpeg") || hrefStr.hasSuffix(".png") || hrefStr.hasSuffix(".webp") || hrefStr.hasSuffix(".gif") || ["jpg", "jpeg", "png", "webp", "gif"].contains(hrefExt) {
                kind = "photo"
            } else if Self.documentExtensions.contains(hrefExt) {
                kind = "file"
            } else if hrefStr.hasPrefix("http://") || hrefStr.hasPrefix("https://") || hrefStr.hasPrefix("//") || hrefStr.hasPrefix("www.") || hrefStr.contains("://") {
                kind = "link"
            } else if Int64(nonEmptyHrefCandidate) != nil && (mt.contains("recommend") || action.contains("user")) {
                kind = "card"
            } else {
                kind = "unknown"
            }
        } else {
            kind = "unknown"
        }

        let cardUid: Int64 = kind == "card"
            ? [
                attach["uid"],
                paramsDict?["uid"],
                attach["id"],
                paramsDict?["id"],
                attach["href"],
                paramsDict?["href"],
                attach["params"] as? String,
            ]
                .map { ZolaJSON.int64($0) }
                .first(where: { $0 > 0 }) ?? 0
            : 0

        var sid = kind == "sticker"
            ? ([attach["id"], attach["stickerId"], attach["eid"], paramsDict?["id"], paramsDict?["stickerId"]].map { ZolaJSON.int64($0) }.first(where: { $0 > 0 }) ?? 0)
            : cardUid
        if kind == "sticker", sid == 0 {
            for v in stickerCandidateUrls {
                let eid = Self.extractStickerEid(from: ZolaJSON.string(v))
                if eid > 0 { sid = eid; break }
            }
        }
        let cid = kind == "sticker"
            ? ZolaJSON.int64(attach["catId"] ?? attach["cateId"] ?? attach["cid"] ?? paramsDict?["catId"] ?? paramsDict?["cateId"])
            : 0

        let defaultUrlCandidates: [Any?] = [
            attach["m4a"],
            attach["aac"],
            attach["m4aUrl"],
            attach["voiceUrl"],
            paramsDict?["m4a"],
            paramsDict?["aac"],
            paramsDict?["m4aUrl"],
            paramsDict?["voiceUrl"],
            attach["hdUrl"],
            attach["oriUrl"],
            attach["rawUrl"],
            attach["hd"],
            attach["href"],
            attach["normalUrl"],
            attach["url"],
            attach["stickerUrl"],
            attach["webpUrl"],
            paramsDict?["hdUrl"],
            paramsDict?["oriUrl"],
            paramsDict?["rawUrl"],
            paramsDict?["hd"],
            paramsDict?["href"],
            paramsDict?["normalUrl"],
            paramsDict?["url"],
            paramsDict?["redirect_url"],
        ]
        var resolvedUrl = defaultUrlCandidates
            .compactMap { Self.normalizeMediaUrl(ZolaJSON.string($0)) }
            .first { !$0.isEmpty } ?? ""

        let allowsUrlAsThumb = (kind == "photo" || kind == "ecard" || kind == "sticker" || kind == "voice")
        var resolvedThumb = [
            attach["thumb"],
            attach["thumbUrl"],
            attach["smallUrl"],
            attach["stickerThumbUrl"],
            paramsDict?["avatar"],
            attach["avatar"],
            allowsUrlAsThumb ? attach["normalUrl"] : nil,
            kind == "voice" ? attach["href"] : nil,
            paramsDict?["thumb"],
            paramsDict?["thumbUrl"],
            paramsDict?["smallUrl"],
            allowsUrlAsThumb ? paramsDict?["normalUrl"] : nil,
            allowsUrlAsThumb ? paramsDict?["hd"] : nil,
            allowsUrlAsThumb ? paramsDict?["rawUrl"] : nil,
            allowsUrlAsThumb ? paramsDict?["href"] : nil,
        ]
            .compactMap { Self.normalizeMediaUrl(ZolaJSON.string($0)) }
            .first { !$0.isEmpty && (kind != "link" || !ZolaLinkMetadata.isPlaceholderThumb($0)) } ?? ""

        if kind == "sticker", sid > 0 {
            let cdn = stickerCdnUrl(stickerId: sid, cateId: cid)
            let lowerUrl = resolvedUrl.lowercased()
            if resolvedUrl.isEmpty
                || lowerUrl.contains("/emoticon/sprite")
                || (lowerUrl.contains("/emoticon/sticker?") && !lowerUrl.contains("/emoticon/sticker/webpc")) {
                resolvedUrl = cdn
                resolvedThumb = cdn
            }
        }

        if kind == "card" {
            if cardUid > 0 {
                resolvedUrl = String(cardUid)
            }
        } else {
            if allowsUrlAsThumb, resolvedThumb.isEmpty && !resolvedUrl.isEmpty {
                resolvedThumb = resolvedUrl
            }
            if resolvedUrl.isEmpty && !resolvedThumb.isEmpty {
                resolvedUrl = resolvedThumb
            }
        }

        if kind == "voice" {
            // Zalo voice attachments carry a playable AAC/M4A URL plus a raw `href` fallback
            // (often `.amr` or an extensionless `*.dlmd.me` / `voice-*.zadn.vn` path). Always pin a
            // playable extension onto extensionless CDN URLs so `AVPlayer` recognizes the container,
            // and keep the *distinct* raw fallback URL inside `thumbUrl` instead of duplicating `url`.
            resolvedUrl = ZolaClient.ensureAudioPathExtension(resolvedUrl, fileName: "voice.aac")
            if resolvedThumb.isEmpty || resolvedThumb == resolvedUrl {
                let fallbackCandidates: [Any?] = [
                    attach["href"], attach["normalUrl"], attach["oriUrl"], attach["rawUrl"],
                    attach["hd"], attach["hdUrl"], attach["url"],
                    paramsDict?["href"], paramsDict?["normalUrl"], paramsDict?["oriUrl"],
                    paramsDict?["rawUrl"], paramsDict?["hd"], paramsDict?["url"],
                ]
                if let fallback = fallbackCandidates
                    .compactMap({ Self.normalizeMediaUrl(ZolaJSON.string($0)) })
                    .first(where: { !$0.isEmpty && $0 != resolvedUrl })
                {
                    resolvedThumb = fallback
                }
            }
            if !resolvedThumb.isEmpty {
                resolvedThumb = ZolaClient.ensureAudioPathExtension(resolvedThumb, fileName: "voice.aac")
            }
        }

        var cleanTitle = rawTitle == "sendBubbleMessage" ? "" : rawTitle
        if cleanTitle.isEmpty, let mediaTitle = paramsDict?["mediaTitle"] ?? paramsDict?["linkTitle"] {
            let candidate = ZolaJSON.string(mediaTitle)
            if candidate != "sendBubbleMessage" {
                cleanTitle = candidate
            }
        }
        var cleanDesc = rawDesc == "sendBubbleMessage" ? "" : rawDesc
        if kind == "card", cleanDesc.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{"),
           let dData = cleanDesc.data(using: .utf8),
           let dJson = try? JSONSerialization.jsonObject(with: dData) as? [String: Any] {
            cleanDesc = ZolaJSON.firstNonEmptyString(dJson["phone"], dJson["description"], dJson["title"])
        }
        if kind == "ecard" && cleanTitle.isEmpty && cleanDesc.isEmpty {
            cleanTitle = "Thiệp chúc mừng Zalo"
            cleanDesc = "Các bạn đã được kết nối trên Zalo"
        }
        if kind == "link" {
            let hasOpenableWebURL = resolvedUrl.lowercased().hasPrefix("http://")
                || resolvedUrl.lowercased().hasPrefix("https://")
                || resolvedThumb.lowercased().hasPrefix("http://")
                || resolvedThumb.lowercased().hasPrefix("https://")
            if !hasOpenableWebURL && cleanTitle.isEmpty && cleanDesc.isEmpty {
                kind = "unknown"
            }
        }
        let w = ZolaJSON.int(attach["width"] ?? paramsDict?["width"] ?? paramsDict?["video_width"])
        let h = ZolaJSON.int(attach["height"] ?? paramsDict?["height"] ?? paramsDict?["video_height"])
        let rawDurValue = attach["duration"] ?? paramsDict?["duration"]
        // Voice `duration` arrives in seconds (int `4`, real `4.3`) or milliseconds (`4300`):
        // normalize every supported unit to milliseconds (`< 500` means seconds).
        let dur: Int
        if kind == "voice" {
            let rawDouble: Double
            if let num = rawDurValue as? NSNumber {
                rawDouble = num.doubleValue
            } else if let str = rawDurValue as? String {
                rawDouble = Double(str.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            } else {
                rawDouble = 0
            }
            dur = (rawDouble > 0 && rawDouble < 500) ? Int((rawDouble * 1_000).rounded()) : Int(rawDouble)
        } else {
            dur = ZolaJSON.int(rawDurValue)
        }
        let fsize = ZolaJSON.int(attach["fileSize"] ?? attach["size"] ?? paramsDict?["fileSize"] ?? paramsDict?["size"])
        var ext = explicitFileExt
        if ext.isEmpty, !cleanTitle.isEmpty {
            let pathExt = (cleanTitle as NSString).pathExtension
            if !pathExt.isEmpty { ext = pathExt }
        }

        return ZolaAttachment(
            kind: kind,
            url: resolvedUrl,
            thumbUrl: resolvedThumb,
            title: cleanTitle,
            descriptionText: cleanDesc,
            width: w,
            height: h,
            durationMs: dur,
            fileSize: fsize,
            stickerId: sid,
            cateId: cid,
            fileExt: ext.lowercased(),
            mediaGroup: kind == "photo" ? paramsDict.flatMap(ZolaMediaGroupLayout.fromPhotoParam) : nil
        )
    }
}

/// Resolved OpenGraph / link-preview card metadata for `subCmd = 38` (`action = "recommened.link"`).
public struct ZolaLinkMetadata: Codable, Sendable, Equatable {
    public let url: String
    public let title: String
    public let descriptionText: String
    public let thumbUrl: String
    public let domain: String

    public init(
        url: String,
        title: String,
        descriptionText: String = "",
        thumbUrl: String = "",
        domain: String = ""
    ) {
        self.url = url
        self.title = title
        self.descriptionText = descriptionText
        self.thumbUrl = Self.isPlaceholderThumb(thumbUrl) ? "" : thumbUrl
        if !domain.isEmpty {
            self.domain = domain
        } else {
            self.domain = URL(string: url)?.host?.replacingOccurrences(of: "^www\\.", with: "", options: .regularExpression) ?? ""
        }
    }

    /// Returns `true` when `raw` is one of Zalo's generic placeholder thumbnails (`feed_thumb_link`, `im_parselink`).
    public static func isPlaceholderThumb(_ raw: String) -> Bool {
        let lower = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lower.isEmpty else { return false }
        return lower.contains("feed_thumb_link") || lower.contains("im_parselink")
    }
}

public struct ZolaQuote: Codable, Sendable, Equatable {
    public let ownerId: Int64
    public let cliMsgId: Int64
    public let globalMsgId: Int64
    public let msgType: String
    public let text: String
    public let tsMs: Int64
    public var senderName: String
    public let serverMsgType: Int16
    public let attachJson: String
    public let ttl: Int64

    public init(
        ownerId: Int64,
        cliMsgId: Int64 = 0,
        globalMsgId: Int64 = 0,
        msgType: String = "webchat",
        text: String,
        tsMs: Int64 = 0,
        senderName: String = "",
        serverMsgType: Int16 = 0,
        attachJson: String = "",
        ttl: Int64 = 0
    ) {
        self.ownerId = ownerId
        self.cliMsgId = cliMsgId
        self.globalMsgId = globalMsgId
        let normalizedType = msgType.isEmpty ? Self.msgTypeFromServerMsgType(serverMsgType) : msgType
        self.msgType = normalizedType
        self.text = text
        self.tsMs = tsMs
        self.senderName = senderName
        self.serverMsgType = serverMsgType > 0 ? serverMsgType : Self.wireServerMsgType(forMsgType: normalizedType)
        self.attachJson = attachJson
        self.ttl = ttl
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ownerId = try c.decode(Int64.self, forKey: .ownerId)
        cliMsgId = try c.decodeIfPresent(Int64.self, forKey: .cliMsgId) ?? 0
        globalMsgId = try c.decodeIfPresent(Int64.self, forKey: .globalMsgId) ?? 0
        let decodedMsgType = try c.decodeIfPresent(String.self, forKey: .msgType) ?? "webchat"
        text = try c.decode(String.self, forKey: .text)
        tsMs = try c.decodeIfPresent(Int64.self, forKey: .tsMs) ?? 0
        senderName = try c.decodeIfPresent(String.self, forKey: .senderName) ?? ""
        let decodedSrvType = try c.decodeIfPresent(Int16.self, forKey: .serverMsgType) ?? 0
        msgType = decodedMsgType.isEmpty ? Self.msgTypeFromServerMsgType(decodedSrvType) : decodedMsgType
        serverMsgType = decodedSrvType > 0 ? decodedSrvType : Self.wireServerMsgType(forMsgType: msgType)
        attachJson = try c.decodeIfPresent(String.self, forKey: .attachJson) ?? ""
        ttl = try c.decodeIfPresent(Int64.self, forKey: .ttl) ?? 0
    }

    /// Maps Zalo string `msgType` / `kind` to the exact `Int16LE` `serverMsgType` in `QuoteData` (`TLV tag = 2`, `0x100d33a78`).
    public static func wireServerMsgType(forMsgType msgType: String, kind: String = "", explicit: Int16 = 0) -> Int16 {
        if explicit > 0 { return explicit }
        let mt = msgType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let kd = kind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if mt == "chat.voice" || mt.contains("voice") || kd == "voice" { return 31 }
        if mt == "chat.gif" || mt.hasSuffix(".gif") { return 49 }
        if mt == "chat.photo" || mt.contains("photo") || mt.contains("image") || kd == "photo" { return 32 }
        if mt == "chat.sticker" || mt.contains("sticker") || mt.contains("emoticon") || kd == "sticker" { return 36 }
        if mt == "chat.doodle" || mt.contains("doodle") { return 37 }
        if mt == "chat.recommended" || mt.contains("recommend") || kd == "card" || kd == "call" { return 38 }
        if mt == "chat.livelocation" { return 59 }
        if mt.contains("location") { return 43 }
        if mt == "chat.video.msg" || mt.contains("video") || kd == "video" { return 44 }
        if mt == "chat.undo" { return 45 }
        if mt == "share.file" || mt.contains("file") || kd == "file" { return 46 }
        if mt == "chat.webcontent.v2" { return 61 }
        if mt == "chat.webcontent" || mt == "chat.link" || kd == "link" { return 52 }
        return 1
    }

    public static func msgTypeFromServerMsgType(_ code: Int16) -> String {
        switch code {
        case 31: return "chat.voice"
        case 32: return "chat.photo"
        case 36: return "chat.sticker"
        case 37: return "chat.doodle"
        case 38: return "chat.recommended"
        case 43: return "chat.location.new"
        case 44: return "chat.video.msg"
        case 45: return "chat.undo"
        case 46: return "share.file"
        case 49: return "chat.gif"
        case 52: return "chat.webcontent"
        case 59: return "chat.livelocation"
        case 61: return "chat.webcontent.v2"
        default: return "webchat"
        }
    }

    /// Builds `QuoteData.attachData` JSON (`0x100d501f4`) when quoting a media/voice/sticker/file/link message.
    public static func buildAttachJson(for message: ZolaMessage) -> String {
        guard let att = message.attachments.first else { return "" }
        var obj: [String: Any] = ["msgBubbleLayoutType": 0]
        if !att.url.isEmpty { obj["href"] = att.url }
        if !att.thumbUrl.isEmpty { obj["thumb"] = att.thumbUrl }
        if !att.title.isEmpty { obj["title"] = att.title }
        if !att.descriptionText.isEmpty { obj["description"] = att.descriptionText }
        switch att.kind {
        case "voice":
            obj["action"] = "chat.voice"
            var p: [String: Any] = ["duration": max(1_000, att.durationMs)]
            if att.fileSize > 0 { p["fileSize"] = att.fileSize }
            if !att.url.isEmpty { p["m4a"] = att.url }
            if let pd = try? JSONSerialization.data(withJSONObject: p, options: [.sortedKeys, .withoutEscapingSlashes]) {
                obj["params"] = String(decoding: pd, as: UTF8.self)
            }
        case "sticker":
            if att.stickerId > 0 { obj["id"] = att.stickerId }
            if att.cateId > 0 { obj["catId"] = att.cateId }
        case "photo", "video":
            var p: [String: Any] = [:]
            if att.width > 0 { p["width"] = att.width }
            if att.height > 0 { p["height"] = att.height }
            if att.durationMs > 0 { p["duration"] = att.durationMs }
            if !p.isEmpty,
               let pd = try? JSONSerialization.data(withJSONObject: p, options: [.sortedKeys, .withoutEscapingSlashes]) {
                obj["params"] = String(decoding: pd, as: UTF8.self)
            }
        case "file":
            var p: [String: Any] = [:]
            if att.fileSize > 0 { p["fileSize"] = att.fileSize }
            if !att.fileExt.isEmpty { p["fileExt"] = att.fileExt }
            if !p.isEmpty,
               let pd = try? JSONSerialization.data(withJSONObject: p, options: [.sortedKeys, .withoutEscapingSlashes]) {
                obj["params"] = String(decoding: pd, as: UTF8.self)
            }
        default:
            break
        }
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes]) else {
            return ""
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Creates a wire-complete `ZolaQuote` from an existing `ZolaMessage`.
    public static func fromMessage(_ message: ZolaMessage, fallbackSenderName: String = "") -> ZolaQuote {
        let resolvedCliId = message.cliMsgId > 0 ? message.cliMsgId : message.tsMs
        let resolvedTs = message.tsMs > 0 ? message.tsMs : resolvedCliId
        let resolvedName = !message.senderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? message.senderName.trimmingCharacters(in: .whitespacesAndNewlines)
            : fallbackSenderName.trimmingCharacters(in: .whitespacesAndNewlines)
        let srvType = wireServerMsgType(forMsgType: message.msgType, kind: message.kind)
        return ZolaQuote(
            ownerId: message.senderId,
            cliMsgId: resolvedCliId,
            globalMsgId: message.id,
            msgType: message.msgType,
            text: message.text == "sendBubbleMessage" ? "" : message.text,
            tsMs: resolvedTs,
            senderName: resolvedName,
            serverMsgType: srvType,
            attachJson: buildAttachJson(for: message),
            ttl: 0
        )
    }

    public var previewSummary: String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty && trimmed != "sendBubbleMessage" {
            return ZolaEmoticon.expandingZaloShortcodes(in: trimmed)
        }
        if !attachJson.isEmpty,
           let data = attachJson.data(using: .utf8),
           let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            let title = ZolaJSON.string(obj["title"]).trimmingCharacters(in: .whitespacesAndNewlines)
            if serverMsgType == 46, !title.isEmpty { return "[Tệp] \(title)" }
            if serverMsgType == 52 || serverMsgType == 61, !title.isEmpty { return title }
        }
        switch serverMsgType {
        case 31: return "[Tin nhắn thoại]"
        case 32, 37, 49: return "[Hình ảnh]"
        case 36: return "[Sticker]"
        case 38: return "[Danh thiếp]"
        case 43, 59: return "[Vị trí]"
        case 44: return "[Video]"
        case 46: return "[Tệp]"
        case 52, 61: return "[Liên kết]"
        default:
            let mt = msgType.lowercased()
            if mt.contains("voice") { return "[Tin nhắn thoại]" }
            if mt.contains("photo") || mt.contains("image") { return "[Hình ảnh]" }
            if mt.contains("sticker") { return "[Sticker]" }
            if mt.contains("video") { return "[Video]" }
            if mt.contains("file") { return "[Tệp]" }
            return "[Tin nhắn]"
        }
    }

    public static func fromRaw(_ raw: [String: Any]) -> ZolaQuote {
        let rawCliType = raw["cliMsgType"]
        let explicitSrv: Int16
        if let num = rawCliType as? NSNumber {
            explicitSrv = Int16(clamping: num.intValue)
        } else if let s = rawCliType as? String, let parsed = Int16(s) {
            explicitSrv = parsed
        } else {
            explicitSrv = 0
        }
        let rawMsgTypeStr: String
        if let s = raw["msgType"] as? String, !s.isEmpty {
            rawMsgTypeStr = s
        } else if let s = rawCliType as? String, Int16(s) == nil, !s.isEmpty {
            rawMsgTypeStr = s
        } else {
            rawMsgTypeStr = msgTypeFromServerMsgType(explicitSrv)
        }
        let attachVal: String
        if let s = raw["attach"] as? String {
            attachVal = s
        } else if let d = raw["attach"] as? [String: Any],
                  let jd = try? JSONSerialization.data(withJSONObject: d, options: [.sortedKeys, .withoutEscapingSlashes]) {
            attachVal = String(decoding: jd, as: UTF8.self)
        } else {
            attachVal = ""
        }
        return ZolaQuote(
            ownerId: ZolaJSON.int64(raw["ownerId"] ?? raw["uidFrom"]),
            cliMsgId: ZolaJSON.int64(raw["cliMsgId"]),
            globalMsgId: ZolaJSON.int64(raw["globalMsgId"] ?? raw["msgId"]),
            msgType: rawMsgTypeStr,
            text: ZolaJSON.string(raw["msg"] ?? raw["content"]),
            tsMs: ZolaJSON.int64(raw["ts"]),
            senderName: ZolaJSON.string(raw["fromD"] ?? raw["senderName"] ?? raw["dName"]),
            serverMsgType: explicitSrv,
            attachJson: attachVal,
            ttl: ZolaJSON.int64(raw["ttl"])
        )
    }
}

/// Built-in Zalo iOS text emoticon shortcode table (`ZAEmoticonHandlerDomain`, e.g. `/-strong` -> `👍`).
/// Designed strictly for display-layer rendering while keeping wire `message.text` untouched and protecting URLs/paths.
public enum ZolaEmoticon {
    private static let exactMap: [String: String] = [
        // Slash word shortcodes (`/-...`)
        "/-strong": "👍",
        "/-weak": "👎",
        "/-bad": "👎",
        "/-heart": "❤️",
        "/-break": "💔",
        "/-ok": "👌",
        "/-v": "✌️",
        "/-thanks": "🙏",
        "/-li": "⚡",
        "/-beer": "🍺",
        "/-coffee": "☕",
        "/-rose": "🌹",
        "/-fade": "🥀",
        "/-bd": "🎂",
        "/-cake": "🎂",
        "/-bome": "💣",
        "/-shit": "💩",
        "/-flag": "🇻🇳",
        "/-punch": "👊",
        "/-share": "🤝",
        "/-no": "🙅",
        "/-loveu": "🤟",
        "/-showlove": "🥰",
        "_()_": "🙏",
        // Classic Zalo smiley shortcodes
        ":handclap": "👏",
        ":-bye": "👋",
        ":wipe": "😅",
        ":-dig": "🤭",
        ":--|": "😓",
        ":-((": "😢",
        ":((": "😭",
        ":))": "😂",
        ":')": "🥹",
        ":-*": "😘",
        ":-h": "😡",
        ":-o": "😮",
        ";-)": "😉",
        ";-d": "😄",
        ";-x": "🤫",
        ";-s": "😖",
        ";-/": "😕",
        ";-!": "😤",
        ";-a": "😏",
        ":-<": "🥺",
        ":-f": "💪",
        ":-l": "😒",
        ":-r": "🤬",
        "8-)": "😎",
        "b-)": "😎",
        "$-)": "🤑",
        "x-)": "😆",
        "|-)": "😪",
        "p-(": "🤢",
        "&-(": "😣",
        ">-|": "😠",
        "--b": "😓",
        "8*)": "🤪",
        ";xx": "😵",
        ":>": "😆",
        ":d": "😁",
        ":o": "😮",
        ":p": "😛",
        ";p": "😜",
        ":)": "🙂",
        ":(": "🙁",
        ":|": "😐",
        ":3": "😺",
        ":$": "😳",
        ":~": "😖",
        ":b": "😋",
        ":*": "😘",
        ":x": "😍",
        ":v": "✌️",
        ";d": "😄",
        ";o": "😱",
        ";g": "😏",
        ";?": "🤨",
        ";!": "😤",
        ";f": "🙏",
        "8*": "😘",
        ":q": "👎",
        ":t": "🤢",
        ":z": "😴",
        ":l": "😶",
        ":!": "😨",
        ":;": "😰",
    ]

    /// Sorted longest-first so concatenated slash shortcodes (`/-strong/-heart`) decompose deterministically.
    private static let sortedSlashCodes: [(code: String, emoji: String)] = exactMap
        .filter { $0.key.hasPrefix("/-") }
        .sorted { $0.key.count > $1.key.count }
        .map { (code: $0.key, emoji: $0.value) }

    private static let leadingWrappers: Set<Character> = ["(", "[", "{", "\"", "'", "“", "‘"]
    private static let trailingPunctuation: Set<Character> = [")", "]", "}", "\"", "'", "”", "’", ",", ".", "!", "?", "…"]

    /// Expands Zalo emoticon shortcodes (`/-strong` -> `👍`, `/-heart` -> `❤️`, `:))` -> `😂`, ...)
    /// only at clean token boundaries, never modifying URLs (`https://.../-strong`), file paths, or times (`10:30`).
    public static func expandingZaloShortcodes(in text: String) -> String {
        guard !text.isEmpty,
              text.contains("/") || text.contains(":") || text.contains(";") || text.contains("_") || text.contains("-") || text.contains("*")
        else {
            return text
        }

        var output = String()
        output.reserveCapacity(text.count)
        var index = text.startIndex

        while index < text.endIndex {
            if text[index].isWhitespace {
                let wsStart = index
                while index < text.endIndex && text[index].isWhitespace {
                    index = text.index(after: index)
                }
                output.append(contentsOf: text[wsStart..<index])
            } else {
                let tokStart = index
                while index < text.endIndex && !text[index].isWhitespace {
                    index = text.index(after: index)
                }
                let token = String(text[tokStart..<index])
                output.append(expandSingleToken(token))
            }
        }
        return output
    }

    /// Returns `true` when `text` (after shortcode expansion) consists strictly of 1 to 3 standalone emojis.
    public static func isStandaloneEmojiText(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 3 else { return false }
        return trimmed.allSatisfy { ch in
            ch.unicodeScalars.contains { scalar in
                scalar.properties.isEmojiPresentation || scalar.properties.isEmoji && scalar.value >= 0x2600
            }
        }
    }

    private static func expandSingleToken(_ token: String) -> String {
        let lowerTok = token.lowercased()
        if lowerTok.hasPrefix("http://")
            || lowerTok.hasPrefix("https://")
            || lowerTok.hasPrefix("www.")
            || lowerTok.hasPrefix("ftp://")
            || lowerTok.hasPrefix("mailto:")
            || lowerTok.contains("://")
        {
            return token
        }

        var leadEnd = token.startIndex
        var peeledCount = 0
        while leadEnd < token.endIndex, peeledCount < 2, leadingWrappers.contains(token[leadEnd]) {
            leadEnd = token.index(after: leadEnd)
            peeledCount += 1
        }
        let prefix = String(token[token.startIndex..<leadEnd])
        let remainder = String(token[leadEnd..<token.endIndex])
        guard !remainder.isEmpty else { return token }

        if let matched = matchCore(remainder) {
            return prefix + matched
        }

        var working = remainder
        var suffix = ""
        for _ in 0..<3 {
            guard let last = working.last, trailingPunctuation.contains(last) else { break }
            working.removeLast()
            suffix = String(last) + suffix
            guard !working.isEmpty else { break }
            if let matched = matchCore(working) {
                return prefix + matched + suffix
            }
        }
        return token
    }

    private static func matchCore(_ core: String) -> String? {
        let lower = core.lowercased()
        if let direct = exactMap[lower] {
            return direct
        }
        guard lower.hasPrefix("/-") else { return nil }
        var cursor = lower.startIndex
        var acc = ""
        while cursor < lower.endIndex {
            let slice = lower[cursor...]
            guard let hit = sortedSlashCodes.first(where: { slice.hasPrefix($0.code) }) else {
                return nil
            }
            acc.append(hit.emoji)
            cursor = lower.index(cursor, offsetBy: hit.code.count)
        }
        return acc.isEmpty ? nil : acc
    }
}

/// One `@mention` range. `pos`/`len` are UTF-16 code units; `@All` is `type = 1, uid = -1`.
public struct ZolaMention: Codable, Sendable, Equatable {
    public let type: Int8
    public let uid: Int64
    public let pos: Int
    public let len: Int

    public init(type: Int8, uid: Int64, pos: Int, len: Int) {
        self.type = type
        self.uid = uid
        self.pos = pos
        self.len = len
    }

    /// Reads a `{type, uid, gUid, pos, len}` item (`0x100d2e410`). Encrypted `gUid`-only entries are skipped.
    static func fromRaw(_ raw: [String: Any]) -> ZolaMention? {
        guard let type = Int8(exactly: ZolaJSON.int(raw["type"])) else { return nil }
        let pos = ZolaJSON.int(raw["pos"], default: -1)
        let len = ZolaJSON.int(raw["len"])
        // The wire carries `i16` offsets; larger values are corrupt and would overflow range math downstream.
        guard pos >= 0, len > 0, pos <= Int(Int16.max), len <= Int(Int16.max) else { return nil }
        if type != 0 {
            return ZolaMention(type: type, uid: -1, pos: pos, len: len)
        }
        let uid = ZolaJSON.int64(raw["uid"])
        return uid > 0 ? ZolaMention(type: type, uid: uid, pos: pos, len: len) : nil
    }

    /// Prefers the `mentions` array, then the legacy keyed `mention` dictionary (`0x100d2e35c`, `0x100d2e79c`).
    static func listFromRaw(mentions: Any?, legacyMention: Any?) -> [ZolaMention] {
        func decoded(_ value: Any?) -> Any? {
            guard let text = value as? String, let data = text.data(using: .utf8) else { return value }
            return try? JSONSerialization.jsonObject(with: data)
        }
        var items: [Any] = (decoded(mentions) as? [Any]) ?? []
        if items.isEmpty {
            let legacy = decoded(legacyMention)
            items = (legacy as? [Any]) ?? (legacy as? [String: Any]).map { Array($0.values) } ?? []
        }
        return items
            .compactMap { ($0 as? [String: Any]).flatMap(fromRaw) }
            .sorted { ($0.pos, $0.len) < ($1.pos, $1.len) }
    }
}

/// Official Account bubble carried by `chat.webcontent` (wire `52`) and `chat.webcontent.v2` (wire `61`).
///
/// Zalo iOS `261002` maps `chat.webcontent` → internal type `53` and `chat.webcontent.v2` → `61` (`0x100d33da8`, `0x100d33dd0`),
/// then `-[RichMessageContent parseParamsAttachWithMessageType:]` (jump table at `0x10010c720`) routes them to
/// `_parseParamsForZInstantWithDataDecryptor:` (`0x10010c848`, v1: `params` JSON string) and
/// `_parseParamsForZInstantV2WithDataDecryptor:` (`0x100d935ac`, v2: `zinstant_data` dict + `zinstant_msg` JSON string).
/// `InstantChatInfo` keeps the ZInstant `item` (`zinstantdata_id`, `checksum`, `data_url`, `data_base64`, `bundle_data`, …)
/// which `ZInstantChatBaseView` renders with the native ZINS layout engine (`ZINSIOSParser`, `0x10175a3b4`), not a web view.
/// ZolaKit cannot render that template, so it keeps the readable fields plus a sanitized copy of the original attach.
public struct ZolaWebContent: Codable, Sendable, Equatable {
    /// `1` = `chat.webcontent`, `2` = `chat.webcontent.v2`.
    public let version: Int
    public let title: String
    public let descriptionText: String
    public let thumbUrl: String
    public let href: String
    public let action: String
    /// `customMsg.msg` (`vi`/`en`) from the ZInstant message info (`_parseZInstantMsgInfoWithDict:` `0x100d7f174`).
    public let noticeText: String
    /// `params.customTitle.msg` / `params.customDesc.msg` (`_prepareCustomTitleIfNeed` `0x10010ce60`).
    public let customTitle: String
    public let customDesc: String
    /// ZInstant `item.zinstantdata_id` and `item.data_url` (`-[ZINSIOSDataModel initWithDictionary:]` `0x10483e764`).
    public let templateId: String
    public let layoutDataUrl: String
    /// Original attach JSON with token/cookie/session-like keys and query items removed; empty when too large.
    public let rawJson: String

    public init(
        version: Int,
        title: String = "",
        descriptionText: String = "",
        thumbUrl: String = "",
        href: String = "",
        action: String = "",
        noticeText: String = "",
        customTitle: String = "",
        customDesc: String = "",
        templateId: String = "",
        layoutDataUrl: String = "",
        rawJson: String = ""
    ) {
        self.version = version
        self.title = title
        self.descriptionText = descriptionText
        self.thumbUrl = thumbUrl
        self.href = href
        self.action = action
        self.noticeText = noticeText
        self.customTitle = customTitle
        self.customDesc = customDesc
        self.templateId = templateId
        self.layoutDataUrl = layoutDataUrl
        self.rawJson = rawJson
    }

    private enum CodingKeys: String, CodingKey {
        case version, title, descriptionText, thumbUrl, href, action, noticeText
        case customTitle, customDesc, templateId, layoutDataUrl, rawJson
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        self.title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        self.descriptionText = try c.decodeIfPresent(String.self, forKey: .descriptionText) ?? ""
        self.thumbUrl = try c.decodeIfPresent(String.self, forKey: .thumbUrl) ?? ""
        self.href = try c.decodeIfPresent(String.self, forKey: .href) ?? ""
        self.action = try c.decodeIfPresent(String.self, forKey: .action) ?? ""
        self.noticeText = try c.decodeIfPresent(String.self, forKey: .noticeText) ?? ""
        self.customTitle = try c.decodeIfPresent(String.self, forKey: .customTitle) ?? ""
        self.customDesc = try c.decodeIfPresent(String.self, forKey: .customDesc) ?? ""
        self.templateId = try c.decodeIfPresent(String.self, forKey: .templateId) ?? ""
        self.layoutDataUrl = try c.decodeIfPresent(String.self, forKey: .layoutDataUrl) ?? ""
        self.rawJson = try c.decodeIfPresent(String.self, forKey: .rawJson) ?? ""
    }

    public var displayTitle: String {
        Self.cleanText(!customTitle.isEmpty ? customTitle : title)
    }

    public var displayDescription: String {
        let desc = Self.cleanText(!customDesc.isEmpty ? customDesc : descriptionText)
        if !desc.isEmpty { return desc }
        let notice = Self.cleanText(noticeText)
        return notice == displayTitle ? "" : notice
    }

    /// `https` link only; anything else (`zalo://`, `javascript:`, plain `http`) is never opened.
    public var safeHref: String { Self.httpsOnly(href) }
    public var safeThumbUrl: String { Self.httpsOnly(thumbUrl) }

    public var hasCardContent: Bool {
        !displayTitle.isEmpty || !displayDescription.isEmpty || !safeThumbUrl.isEmpty || !safeHref.isEmpty
    }

    public var hasRawJson: Bool { !rawJson.isEmpty }

    /// Readable line for inbox previews and notifications; empty when the template carries no text.
    public var previewText: String {
        !displayTitle.isEmpty ? displayTitle : displayDescription
    }

    /// Card attachment (`kind = "webcontent"`) built only from readable fields.
    public var cardAttachment: ZolaAttachment {
        ZolaAttachment(
            kind: "webcontent",
            url: safeHref,
            thumbUrl: safeThumbUrl,
            title: displayTitle,
            descriptionText: displayDescription
        )
    }

    /// Parses an OA `chat.webcontent` / `chat.webcontent.v2` attach. Returns `nil` for other types or an empty attach.
    public static func parse(msgType: String, attach: [String: Any]) -> ZolaWebContent? {
        let mt = msgType.lowercased()
        guard mt.contains("webcontent"), !attach.isEmpty else { return nil }
        let version = mt.hasSuffix(".v2") ? 2 : 1

        let params = jsonDict(attach["params"])
        // v1 message info lives in `params` itself; v2 sends it as the `zinstant_msg` JSON string.
        let msgInfo = jsonDict(attach["zinstant_msg"]) ?? params
        let v2Item = decodeV2Item(attach["zinstant_data"])
        let item = (params?["item"] as? [String: Any]) ?? v2Item

        let customMsg = msgInfo?["customMsg"] as? [String: Any]
        let content = ZolaWebContent(
            version: version,
            title: ZolaJSON.firstNonEmptyString(attach["title"]),
            descriptionText: ZolaJSON.firstNonEmptyString(attach["description"]),
            thumbUrl: ZolaAttachment.normalizeMediaUrl(ZolaJSON.firstNonEmptyString(attach["thumb"])),
            href: ZolaAttachment.normalizeMediaUrl(ZolaJSON.firstNonEmptyString(attach["href"])),
            action: ZolaJSON.firstNonEmptyString(attach["action"]),
            noticeText: localizedText(customMsg?["msg"]),
            customTitle: localizedText((params?["customTitle"] as? [String: Any])?["msg"] ?? params?["customTitle"]),
            customDesc: localizedText((params?["customDesc"] as? [String: Any])?["msg"] ?? params?["customDesc"]),
            templateId: ZolaJSON.firstNonEmptyString(item?["zinstantdata_id"]),
            layoutDataUrl: httpsOnly(ZolaJSON.firstNonEmptyString(item?["data_url"])),
            rawJson: sanitizedRawJson(attach)
        )
        return content
    }

    // MARK: - Helpers

    static let maxRawJsonBytes = 256 * 1024

    private static func cleanText(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t == "sendBubbleMessage" || t.hasPrefix("{") || t.hasPrefix("[") { return "" }
        return t
    }

    static func httpsOnly(_ raw: String) -> String {
        let normalized = ZolaAttachment.normalizeMediaUrl(raw)
        guard let comps = URLComponents(string: normalized),
              comps.scheme?.lowercased() == "https",
              let host = comps.host, !host.isEmpty
        else { return "" }
        return normalized
    }

    static func jsonDict(_ value: Any?) -> [String: Any]? {
        if let d = value as? [String: Any] { return d }
        guard let s = value as? String,
              s.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{"),
              let data = s.data(using: .utf8)
        else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// `customMsg.msg` / `customTitle.msg` is `{ "vi": …, "en": … }` (`parseStringHighlightV2WithDictionary:` `0x101a091d0`).
    static func localizedText(_ value: Any?) -> String {
        if let s = value as? String { return cleanText(s) }
        guard let d = value as? [String: Any] else { return "" }
        for key in ["vi", "en"] {
            let s = cleanText(ZolaJSON.string(d[key]))
            if !s.isEmpty { return s }
        }
        if let nested = d["msg"] { return localizedText(nested) }
        return ""
    }

    /// v2 `zinstant_data = { "type": 0, "data": base64(gzip(JSON {"item": …, "bundle_data": …})) }`
    /// (`-[InstantChatInfo _parseZInstantItemV2WithDict:]` `0x100d7ef80`; any `type != 0` is unsupported there).
    static func decodeV2Item(_ value: Any?) -> [String: Any]? {
        guard let decoded = decodeV2Payload(value) else { return nil }
        return decoded["item"] as? [String: Any]
    }

    static func decodeV2Payload(_ value: Any?) -> [String: Any]? {
        guard let zdata = value as? [String: Any],
              ZolaJSON.int(zdata["type"], default: -1) == 0,
              let b64 = zdata["data"] as? String, !b64.isEmpty,
              let packed = Data(base64Encoded: b64, options: .ignoreUnknownCharacters)
        else { return nil }
        let unpacked = ZolaCrypto.gunzipOrInflate(packed) ?? packed
        return (try? JSONSerialization.jsonObject(with: unpacked)) as? [String: Any]
    }

    private static let sensitiveKeyFragments = [
        "token", "cookie", "secret", "session", "zpw", "password", "passwd",
        "cryptkey", "signature", "zcid", "apikey", "api_key", "authorization", "credential",
    ]

    static func isSensitiveKey(_ key: String) -> Bool {
        let lower = key.lowercased()
        return sensitiveKeyFragments.contains { lower.contains($0) }
    }

    static func sanitizedRawJson(_ attach: [String: Any]) -> String {
        var cleaned = sanitize(attach) as? [String: Any] ?? [:]
        // The gzip blob cannot be inspected for tokens; keep its decoded (sanitized) form instead.
        if var zdata = cleaned["zinstant_data"] as? [String: Any], zdata["data"] != nil {
            if let decoded = decodeV2Payload(attach["zinstant_data"]) {
                zdata["data_decoded"] = sanitize(decoded)
            } else {
                zdata["data_omitted_chars"] = ZolaJSON.string(zdata["data"]).count
            }
            zdata.removeValue(forKey: "data")
            cleaned["zinstant_data"] = zdata
        }
        guard JSONSerialization.isValidJSONObject(cleaned),
              let data = try? JSONSerialization.data(withJSONObject: cleaned, options: [.sortedKeys, .withoutEscapingSlashes]),
              data.count <= maxRawJsonBytes
        else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    static func sanitize(_ value: Any) -> Any {
        if let d = value as? [String: Any] {
            var out: [String: Any] = [:]
            for (k, v) in d where !isSensitiveKey(k) {
                out[k] = sanitize(v)
            }
            return out
        }
        if let a = value as? [Any] {
            return a.map { sanitize($0) }
        }
        if let s = value as? String {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("{") || trimmed.hasPrefix("["),
               let data = trimmed.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: data),
               let reencoded = try? JSONSerialization.data(withJSONObject: sanitize(parsed), options: [.sortedKeys, .withoutEscapingSlashes]) {
                return String(decoding: reencoded, as: UTF8.self)
            }
            if trimmed.contains("://") || trimmed.hasPrefix("//"),
               var comps = URLComponents(string: trimmed),
               let items = comps.queryItems, !items.isEmpty {
                let kept = items.filter { !isSensitiveKey($0.name) }
                if kept.count != items.count {
                    comps.queryItems = kept.isEmpty ? nil : kept
                    return comps.string ?? ""
                }
            }
            return s
        }
        return value
    }
}

/// Parsed `group.*` wire event (member add/remove/leave, admin grant/revoke, rename,
/// avatar change, settings change) carried on `ZolaMessage.groupEvent` when `kind == "system"`.
public struct ZolaGroupEventInfo: Codable, Equatable, Sendable {
    /// Original `msgType`/`action` seen on the wire, e.g. `"group.join"`, `"group.update"`.
    public var action: String
    public var actorUid: Int64?
    public var actorName: String?
    public var memberUids: [Int64]
    public var memberNames: [String]
    /// Extra detail when the event carries one (e.g. the new group name after a rename).
    public var detail: String?

    public init(
        action: String,
        actorUid: Int64? = nil,
        actorName: String? = nil,
        memberUids: [Int64] = [],
        memberNames: [String] = [],
        detail: String? = nil
    ) {
        self.action = action
        self.actorUid = actorUid
        self.actorName = actorName
        self.memberUids = memberUids
        self.memberNames = memberNames
        self.detail = detail
    }
}

/// One answer option inside a group poll (`ZolaBoardCard.kind == .poll`).
public struct ZolaPollOption: Codable, Equatable, Sendable {
    public var label: String
    public var votes: Int?
    public var votedBySelf: Bool?

    public init(label: String, votes: Int? = nil, votedBySelf: Bool? = nil) {
        self.label = label
        self.votes = votes
        self.votedBySelf = votedBySelf
    }
}

/// Read-only board card (poll / pinned note / reminder) extracted from `group.*` wire
/// messages. Present on `ZolaMessage.boardCard` when `kind == "board"`; the app only
/// displays these cards — there is no send/vote flow.
public struct ZolaBoardCard: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case poll
        case note
        case reminder
    }

    public var kind: Kind
    /// Native poll identity, retained independently of the chat message ID.
    public var pollId: String?
    /// True when a native note event contains only a truncated preview, not its full body.
    public var isPreviewOnly: Bool?
    /// Poll: the question. Reminder: event title. Note: first line of the note body.
    public var title: String
    /// Poll: description. Note: full note text. Reminder: description.
    public var body: String?
    public var options: [ZolaPollOption]
    public var totalVotes: Int?
    public var isAnonymous: Bool?
    public var isClosed: Bool?
    public var allowMultiChoice: Bool?
    /// Reminder start time in milliseconds (wire values in seconds are normalised).
    public var startMs: Int64?
    public var repeatText: String?
    public var locationText: String?
    public var creatorUid: Int64?
    public var creatorName: String?
    /// Vietnamese action phrase for the card footer, e.g. `"đã tạo bình chọn"`.
    public var actionText: String?

    public init(
        kind: Kind,
        title: String,
        body: String? = nil,
        options: [ZolaPollOption] = [],
        totalVotes: Int? = nil,
        isAnonymous: Bool? = nil,
        isClosed: Bool? = nil,
        allowMultiChoice: Bool? = nil,
        startMs: Int64? = nil,
        repeatText: String? = nil,
        locationText: String? = nil,
        creatorUid: Int64? = nil,
        creatorName: String? = nil,
        actionText: String? = nil,
        pollId: String? = nil,
        isPreviewOnly: Bool? = nil
    ) {
        self.kind = kind
        self.title = title
        self.body = body
        self.options = options
        self.totalVotes = totalVotes
        self.isAnonymous = isAnonymous
        self.isClosed = isClosed
        self.allowMultiChoice = allowMultiChoice
        self.startMs = startMs
        self.repeatText = repeatText
        self.locationText = locationText
        self.creatorUid = creatorUid
        self.creatorName = creatorName
        self.actionText = actionText
        self.pollId = pollId
        self.isPreviewOnly = isPreviewOnly
    }
}

public struct ZolaMessage: Codable, Sendable, Identifiable, Equatable {
    public let id: Int64
    public let cliMsgId: Int64
    public let threadId: Int64
    public let isGroup: Bool
    public let senderId: Int64
    public let senderName: String
    public let toId: Int64
    public let tsMs: Int64
    public let msgType: String
    public let kind: String
    public let text: String
    public let attachments: [ZolaAttachment]
    public let quote: ZolaQuote?
    public let isSelf: Bool
    public let isCloud: Bool
    public let mcrypt: Int
    public let source: String
    public let reactions: [String]
    /// Distinguishes an authoritative empty reaction snapshot from omitted metadata.
    public let hasReactionSnapshot: Bool
    public let mentions: [ZolaMention]
    /// Readable fields + sanitized original attach of `chat.webcontent` / `chat.webcontent.v2`; `nil` for other types and old caches.
    public let webContent: ZolaWebContent?
    /// Sanitized raw JSON of the original wire item, kept for messages rendered as
    /// `[Tin nhắn chưa hỗ trợ hiển thị]` and for every `group.*` wire message (whose payload
    /// shape is still being reverse engineered), so the chat UI can offer a local-only
    /// "copy raw data" action. Empty ("") for every other normal/known message.
    public let rawDebugJson: String
    /// Parsed `group.*` membership/admin/setting event; non-nil only when `kind == "system"`
    /// and the wire item is a group event (`text` is already a complete Vietnamese sentence).
    public let groupEvent: ZolaGroupEventInfo?
    /// Read-only board card (poll/note/reminder) parsed from `group.*` wire messages;
    /// non-nil only when `kind == "board"`.
    public let boardCard: ZolaBoardCard?

    /// `true` when `id` is a real Zalo server global message id — not an optimistic client id
    /// (`id == cliMsgId`) nor a timestamp echo (`id == tsMs`). Use this when deriving a backward
    /// history cursor so self-sent / unreconciled messages don't poison `beforeGlobalMsgId`.
    public var hasRealServerGlobalId: Bool {
        guard id > 0 else { return false }
        if cliMsgId > 0 && id == cliMsgId { return false }
        if tsMs > 1 && id == tsMs { return false }
        return true
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case cliMsgId
        case threadId
        case isGroup
        case senderId
        case senderName
        case toId
        case tsMs
        case msgType
        case kind
        case text
        case attachments
        case quote
        case isSelf
        case isCloud
        case mcrypt
        case source
        case reactions
        case hasReactionSnapshot
        case mentions
        case webContent
        case rawDebugJson
        case groupEvent
        case boardCard
    }

    public init(
        id: Int64,
        cliMsgId: Int64,
        threadId: Int64,
        isGroup: Bool = false,
        senderId: Int64,
        senderName: String = "",
        toId: Int64,
        tsMs: Int64,
        msgType: String = "webchat",
        kind: String = "text",
        text: String,
        attachments: [ZolaAttachment] = [],
        quote: ZolaQuote? = nil,
        isSelf: Bool,
        isCloud: Bool = false,
        mcrypt: Int = 0,
        source: String = "femc",
        reactions: [String] = [],
        hasReactionSnapshot: Bool? = nil,
        mentions: [ZolaMention] = [],
        webContent: ZolaWebContent? = nil,
        rawDebugJson: String = "",
        groupEvent: ZolaGroupEventInfo? = nil,
        boardCard: ZolaBoardCard? = nil
    ) {
        self.id = id
        self.cliMsgId = cliMsgId
        self.threadId = threadId
        self.isGroup = isGroup
        self.senderId = senderId
        self.senderName = senderName
        self.toId = toId
        self.tsMs = tsMs
        self.msgType = msgType
        self.kind = kind
        self.text = text
        self.attachments = attachments
        self.quote = quote
        self.isSelf = isSelf
        self.isCloud = isCloud
        self.mcrypt = mcrypt
        self.source = source
        self.reactions = reactions
        self.hasReactionSnapshot = hasReactionSnapshot ?? !reactions.isEmpty
        self.mentions = mentions
        self.webContent = webContent
        self.rawDebugJson = rawDebugJson
        self.groupEvent = groupEvent
        self.boardCard = boardCard
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(Int64.self, forKey: .id)
        self.cliMsgId = try c.decodeIfPresent(Int64.self, forKey: .cliMsgId) ?? 0
        self.threadId = try c.decode(Int64.self, forKey: .threadId)
        self.isGroup = try c.decodeIfPresent(Bool.self, forKey: .isGroup) ?? false
        self.senderId = try c.decodeIfPresent(Int64.self, forKey: .senderId) ?? 0
        self.senderName = try c.decodeIfPresent(String.self, forKey: .senderName) ?? ""
        self.toId = try c.decodeIfPresent(Int64.self, forKey: .toId) ?? 0
        self.tsMs = try c.decodeIfPresent(Int64.self, forKey: .tsMs) ?? 0
        self.msgType = try c.decodeIfPresent(String.self, forKey: .msgType) ?? "webchat"
        self.kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "text"
        self.text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        self.attachments = try c.decodeIfPresent([ZolaAttachment].self, forKey: .attachments) ?? []
        self.quote = try c.decodeIfPresent(ZolaQuote.self, forKey: .quote)
        self.isSelf = try c.decodeIfPresent(Bool.self, forKey: .isSelf) ?? false
        self.isCloud = try c.decodeIfPresent(Bool.self, forKey: .isCloud) ?? false
        self.mcrypt = try c.decodeIfPresent(Int.self, forKey: .mcrypt) ?? 0
        self.source = try c.decodeIfPresent(String.self, forKey: .source) ?? "femc"
        self.reactions = try c.decodeIfPresent([String].self, forKey: .reactions) ?? []
        self.hasReactionSnapshot = try c.decodeIfPresent(Bool.self, forKey: .hasReactionSnapshot) ?? !reactions.isEmpty
        self.mentions = try c.decodeIfPresent([ZolaMention].self, forKey: .mentions) ?? []
        self.webContent = try c.decodeIfPresent(ZolaWebContent.self, forKey: .webContent)
        self.rawDebugJson = try c.decodeIfPresent(String.self, forKey: .rawDebugJson) ?? ""
        self.groupEvent = try c.decodeIfPresent(ZolaGroupEventInfo.self, forKey: .groupEvent)
        self.boardCard = try c.decodeIfPresent(ZolaBoardCard.self, forKey: .boardCard)
    }

    /// Copy of this message carrying `webContent` (callers that rebuild a message field by field drop it otherwise).
    public func withWebContent(_ content: ZolaWebContent?) -> ZolaMessage {
        ZolaMessage(
            id: id,
            cliMsgId: cliMsgId,
            threadId: threadId,
            isGroup: isGroup,
            senderId: senderId,
            senderName: senderName,
            toId: toId,
            tsMs: tsMs,
            msgType: msgType,
            kind: kind,
            text: text,
            attachments: attachments,
            quote: quote,
            isSelf: isSelf,
            isCloud: isCloud,
            mcrypt: mcrypt,
            source: source,
            reactions: reactions,
            hasReactionSnapshot: hasReactionSnapshot,
            mentions: mentions,
            webContent: content,
            rawDebugJson: rawDebugJson,
            groupEvent: groupEvent,
            boardCard: boardCard
        )
    }

    /// Replaces the authoritative display snapshot while preserving every other message field.
    public func withReactionSnapshot(_ emojis: [String]) -> ZolaMessage {
        ZolaMessage(id: id, cliMsgId: cliMsgId, threadId: threadId, isGroup: isGroup,
                    senderId: senderId, senderName: senderName, toId: toId, tsMs: tsMs,
                    msgType: msgType, kind: kind, text: text, attachments: attachments, quote: quote,
                    isSelf: isSelf, isCloud: isCloud, mcrypt: mcrypt, source: source,
                    reactions: emojis, hasReactionSnapshot: true, mentions: mentions,
                    webContent: webContent, rawDebugJson: rawDebugJson,
                    groupEvent: groupEvent, boardCard: boardCard)
    }

    /// Merges repeated native/history representations of the same message without losing rich content.
    /// An explicit recall is terminal; omitted metadata never means deletion.
    public static func merging(existing: ZolaMessage, incoming: ZolaMessage) -> ZolaMessage {
        guard existing.threadId == incoming.threadId, existing.isGroup == incoming.isGroup,
              existing.id == incoming.id || (existing.cliMsgId > 0 && existing.cliMsgId == incoming.cliMsgId)
        else { return incoming }
        if incoming.kind == "recalled" { return incoming }
        if existing.kind == "recalled" { return existing }
        let incomingTextMissing = incoming.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || incoming.text == "[Tin nhắn chưa hỗ trợ hiển thị]"
        let existingHasContent = !existing.attachments.isEmpty || existing.webContent != nil
            || (!existing.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && existing.text != "[Tin nhắn chưa hỗ trợ hiển thị]")
        let preserveContent = incoming.attachments.isEmpty && incoming.webContent == nil
            && (incomingTextMissing && existingHasContent
                || (!existing.attachments.isEmpty && incoming.kind == "text"))
        let content = preserveContent ? existing : incoming
        let resolvedText = incomingTextMissing && existingHasContent ? existing.text : incoming.text
        return ZolaMessage(
            id: incoming.id, cliMsgId: incoming.cliMsgId > 0 ? incoming.cliMsgId : existing.cliMsgId,
            threadId: incoming.threadId, isGroup: incoming.isGroup,
            senderId: incoming.senderId > 0 ? incoming.senderId : existing.senderId,
            senderName: incoming.senderName.isEmpty ? existing.senderName : incoming.senderName,
            toId: incoming.toId > 0 ? incoming.toId : existing.toId,
            tsMs: incoming.tsMs > 0 ? incoming.tsMs : existing.tsMs,
            msgType: content.msgType, kind: content.kind,
            text: resolvedText,
            attachments: incoming.attachments.isEmpty ? existing.attachments : incoming.attachments,
            quote: incoming.quote ?? existing.quote,
            isSelf: incoming.senderId > 0 ? incoming.isSelf : existing.isSelf,
            isCloud: incoming.isCloud || existing.isCloud,
            mcrypt: content.mcrypt, source: incoming.source,
            reactions: incoming.hasReactionSnapshot ? incoming.reactions : existing.reactions,
            hasReactionSnapshot: incoming.hasReactionSnapshot || existing.hasReactionSnapshot,
            mentions: incoming.mentions.isEmpty && resolvedText == existing.text ? existing.mentions : incoming.mentions,
            webContent: incoming.webContent ?? existing.webContent,
            rawDebugJson: preserveContent ? existing.rawDebugJson : incoming.rawDebugJson,
            groupEvent: incoming.groupEvent ?? existing.groupEvent,
            boardCard: incoming.boardCard ?? existing.boardCard
        )
    }

    /// Maps a Zalo reaction code (`/-heart`, `/-strong`, `:>`...) or emoji to the canonical display emoji.
    public static func displayEmojiForZaloReaction(_ rawIcon: String) -> String? {
        ZolaReactionCatalog.displayEmoji(for: rawIcon)
    }

    internal static func parseReactionEmojis(from raw: Any?) -> [String] {
        guard let raw else { return [] }
        var out: [String] = []
        func appendEmoji(_ icon: String) {
            if let mapped = displayEmojiForZaloReaction(icon), !out.contains(mapped) {
                out.append(mapped)
            }
        }
        func scan(_ node: Any) {
            if let str = node as? String {
                let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.hasPrefix("{") || trimmed.hasPrefix("["),
                   let d = trimmed.data(using: .utf8),
                   let parsed = try? JSONSerialization.jsonObject(with: d) {
                    scan(parsed)
                } else {
                    appendEmoji(trimmed)
                }
            } else if let dict = node as? [String: Any] {
                if let rIcon = dict["rIcon"] as? String {
                    appendEmoji(rIcon)
                }
                if let icon = dict["icon"] as? String {
                    appendEmoji(icon)
                }
                for key in ["reactions", "reacts", "list", "data", "content", "msg"] {
                    if let sub = dict[key] { scan(sub) }
                }
            } else if let arr = node as? [Any] {
                for el in arr { scan(el) }
            }
        }
        scan(raw)
        return out
    }

    public var articleCards: [ZolaAttachment] { attachments.filter { $0.kind == "article" } }

    public var previewText: String {
        if kind == "recalled" { return "Tin nhắn đã được thu hồi" }
        if kind == "board", let card = boardCard {
            let prefix: String
            switch card.kind {
            case .poll: prefix = "[Bình chọn]"
            case .note: prefix = "[Ghi chú]"
            case .reminder: prefix = "[Nhắc hẹn]"
            }
            return card.title.isEmpty ? prefix : "\(prefix) \(card.title)"
        }
        if !text.isEmpty && text != "sendBubbleMessage" { return ZolaEmoticon.expandingZaloShortcodes(in: text) }
        guard let att = attachments.first else {
            return text == "sendBubbleMessage" ? "[Cuộc gọi]" : ""
        }
        switch att.kind {
        case "call": return att.title.isEmpty ? "[Cuộc gọi]" : att.title
        case "photo": return "[Hình ảnh]"
        case "sticker": return "[Sticker]"
        case "voice": return "[Tin nhắn thoại]"
        case "video": return "[Video]"
        case "file": return att.title.isEmpty ? "[Tệp]" : "[Tệp] \(att.title)"
        case "card": return att.title.isEmpty ? "[Danh thiếp]" : "[Danh thiếp] \(att.title)"
        case "ecard": return att.title.isEmpty ? "[Thiệp chúc mừng]" : "[Thiệp] \(att.title)"
        case "location": return att.title.isEmpty ? "[Vị trí]" : "📍 \(att.title)"
        case "link": return att.title.isEmpty ? (att.url.isEmpty ? "[Thông báo]" : "[Liên kết]") : att.title
        case "webcontent": return !att.title.isEmpty ? att.title : (!att.descriptionText.isEmpty ? att.descriptionText : "[Thông báo]")
        case "article": return !att.title.isEmpty ? att.title : (!att.descriptionText.isEmpty ? att.descriptionText : "[Bài viết]")
        default: return "[Đính kèm]"
        }
    }

    public static func fromRawItem(
        _ rawItem: [String: Any],
        selfUid: Int64,
        sendToMeId: Int64 = ZolaConstants.defaultSendToMeId,
        knownGroupIds: Set<Int64> = [],
        cryptKey: Data = Data(),
        defaultSource: String = "femc"
    ) -> ZolaMessage {
        let tsOuter = ZolaJSON.int64(rawItem["ts"])
        let txtWrap = rawItem["text"] as? [String: Any]
        let inner = (txtWrap?["data"] as? [String: Any]) ?? rawItem
        let rawMsgType = ZolaJSON.string(txtWrap?["type"] ?? inner["msgType"] ?? rawItem["msgType"])
        let msgType = rawMsgType.isEmpty ? "webchat" : rawMsgType
        let mtLower = msgType.lowercased()
        let mcryptFlag = ZolaJSON.int(inner["mcrypt"] ?? rawItem["mcrypt"])

        let glbId = ZolaJSON.int64(inner["id"] ?? inner["msgId"] ?? inner["globalMsgId"] ?? inner["gmi"] ?? rawItem["id"] ?? rawItem["msgId"] ?? rawItem["gmi"])
        let cliId = ZolaJSON.int64(inner["cliMsgId"] ?? inner["cmi"] ?? rawItem["cliMsgId"] ?? rawItem["cmi"])
        let uidFrom = ZolaJSON.int64(inner["fromU"] ?? inner["uidFrom"] ?? inner["src"] ?? inner["si"] ?? rawItem["fromU"] ?? rawItem["uidFrom"] ?? rawItem["si"])
        var idTo = ZolaJSON.int64(inner["to"] ?? inner["idTo"] ?? inner["des"] ?? inner["gId"] ?? inner["groupId"] ?? inner["di"] ?? rawItem["to"] ?? rawItem["idTo"] ?? rawItem["di"])
        if idTo == 0 && uidFrom > 0 && uidFrom != selfUid {
            idTo = selfUid
        }
        let tsMs = ZolaJSON.int64(inner["ts"], default: tsOuter)
        let resolvedId = glbId > 0 ? glbId : (cliId > 0 ? cliId : max(1, tsMs))

        let isSelf = uidFrom == selfUid
        let isGroup = knownGroupIds.contains(idTo) || defaultSource == "mfetch"
        let isCloud = !isGroup && (
            idTo == sendToMeId
                || uidFrom == sendToMeId
                || (isSelf && selfUid > 0 && (idTo == 0 || idTo == selfUid))
        )
        let threadId: Int64
        if isGroup { threadId = idTo }
        else if isCloud { threadId = sendToMeId }
        else { threadId = isSelf ? idTo : uidFrom }
        let rawSenderName = ZolaJSON.string(inner["fromD"] ?? inner["dName"] ?? rawItem["fromD"] ?? rawItem["dName"])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var attachDict: [String: Any]?
        if let d = inner["attach"] as? [String: Any], !d.isEmpty {
            attachDict = d
        } else if let s = inner["attach"] as? String,
                  let data = s.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  !parsed.isEmpty {
            attachDict = parsed
        } else if let d = inner["content"] as? [String: Any], !d.isEmpty {
            attachDict = d
        } else if let d = inner["msg"] as? [String: Any], !d.isEmpty {
            attachDict = d
        }

        var textVal = ""
        if let s = inner["msg"] as? String { textVal = s }
        else if let s = inner["content"] as? String { textVal = s }

        var mcryptQuote: ZolaQuote?
        if mcryptFlag == 1, !cryptKey.isEmpty, !textVal.isEmpty {
            let unpacked = ZolaCrypto.decryptMessageTextAndQuoteIfNeeded(
                rawText: textVal,
                ivValue: inner["iv"] ?? rawItem["iv"],
                mcrypt: mcryptFlag,
                cryptKey: cryptKey
            )
            textVal = unpacked.text
            mcryptQuote = unpacked.quote
        }

        // If `msg`/`content` itself is a JSON object for media/sticker/file/link/card/call/system-notice when `attachDict` is nil or `{}`
        if attachDict == nil {
            let trimmedText = textVal.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedText.hasPrefix("{"),
               let data = trimmedText.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               !parsed.isEmpty,
               (mtLower != "webchat"
                || parsed["action"] != nil
                || parsed["notifyTxt"] != nil
                || parsed["eCardHeaderString"] != nil
                || parsed["href"] != nil
                || parsed["hdUrl"] != nil
                || parsed["catId"] != nil
                || parsed["stickerId"] != nil
                || parsed["hd"] != nil
                || parsed["thumb"] != nil)
            {
                attachDict = parsed
                let pTitle = ZolaJSON.string(parsed["title"])
                textVal = (pTitle != "sendBubbleMessage" && !pTitle.isEmpty) ? pTitle : ZolaJSON.string(parsed["description"])
            } else if let pDict = inner["params"] as? [String: Any], !pDict.isEmpty, mtLower != "webchat" {
                attachDict = pDict
            } else if let pStr = inner["params"] as? String,
                      mtLower != "webchat",
                      let pData = pStr.data(using: .utf8),
                      let parsed = try? JSONSerialization.jsonObject(with: pData) as? [String: Any],
                      !parsed.isEmpty {
                attachDict = parsed
            } else if mtLower.contains("sticker") {
                let sid = ZolaJSON.int64(inner["stickerId"] ?? inner["id"] ?? trimmedText)
                let cid = ZolaJSON.int64(inner["catId"] ?? inner["cateId"])
                if sid > 0 {
                    attachDict = ["id": sid, "catId": cid]
                }
            } else if ZolaAttachment.isEmoticonStickerURL(trimmedText) {
                let eid = ZolaAttachment.extractStickerEid(from: trimmedText)
                let cdn = ZolaAttachment.stickerCdnUrl(stickerId: eid)
                attachDict = ["id": eid, "href": cdn.isEmpty ? trimmedText : cdn]
                textVal = ""
            } else if (mtLower.contains("photo") || mtLower.contains("image")),
                      (trimmedText.hasPrefix("http://") || trimmedText.hasPrefix("https://") || trimmedText.hasPrefix("//")) {
                attachDict = ["href": trimmedText, "thumb": trimmedText]
                textVal = ""
            } else if let urlRange = trimmedText.range(of: #"https?://[^\s]+\.(?:m4a|mp3|aac|amr)"#, options: [.regularExpression, .caseInsensitive]) {
                let audioUrl = String(trimmedText[urlRange])
                var parsedDurMs = 5_000
                if let durRange = trimmedText.range(of: #"\((\d+):(\d{2})\)"#, options: .regularExpression) {
                    let durToken = trimmedText[durRange].dropFirst().dropLast()
                    let parts = durToken.split(separator: ":")
                    if parts.count == 2, let m = Int(parts[0]), let s = Int(parts[1]) {
                        parsedDurMs = max(1_000, (m * 60 + s) * 1_000)
                    }
                }
                attachDict = [
                    "href": audioUrl,
                    "title": "Tin nhắn thoại",
                    "duration": parsedDurMs,
                    "fileExt": audioUrl.lowercased().hasSuffix(".aac") ? "aac" : "m4a",
                ]
                textVal = ""
            } else if let emptyAttach = inner["attach"] as? [String: Any], emptyAttach.isEmpty, mtLower != "webchat" {
                attachDict = emptyAttach
            }
        }

        var overrideKind: String?
        var resolvedMsgType = msgType
        var attachments: [ZolaAttachment] = []
        var groupEvent: ZolaGroupEventInfo?
        var boardCard: ZolaBoardCard?
        var keepGroupWireDebug = false
        // Zalo routes 52/61 to the ZInstant parser regardless of `action`, so friend/system heuristics never apply here.
        let webContent = mtLower.contains("webcontent") ? attachDict.flatMap { ZolaWebContent.parse(msgType: msgType, attach: $0) } : nil
        let nativeBoardNotice = isGroup ? attachDict.flatMap {
            ZolaNativeGroupBoardNotice.parse(msgType: msgType, attach: $0, senderUid: uidFrom, senderName: rawSenderName)
        } : nil
        if mtLower == "chat.undo" || mtLower == "undo" {
            overrideKind = "recalled"
            textVal = "Tin nhắn đã được thu hồi"
        } else if let notice = nativeBoardNotice {
            overrideKind = notice.kind
            boardCard = notice.card
            if let readableText = notice.text { textVal = readableText }
            if let nativeType = notice.resolvedMsgType { resolvedMsgType = nativeType }
            keepGroupWireDebug = true
        } else if mtLower == "chat.list.action" {
            attachments = ZolaArticleList.parse([inner])
            if !attachments.isEmpty {
                overrideKind = "article"
                textVal = ""
            } else {
                // Do not expose serialized templates or executable action strings as message text.
                let readable = textVal.trimmingCharacters(in: .whitespacesAndNewlines)
                if readable.isEmpty || readable.hasPrefix("{") || readable.hasPrefix("[") || readable == "sendBubbleMessage" {
                    textVal = "[Danh sách bài viết]"
                }
            }
        } else if let webContent {
            // Stays `system` (as before) so OA broadcasts never count as conversations awaiting a reply;
            // the readable part travels as a `webcontent` attachment.
            overrideKind = "system"
            if webContent.hasCardContent {
                attachments.append(webContent.cardAttachment)
                textVal = ""
            } else {
                textVal = "Thông báo hệ thống Zalo"
            }
        } else if let attachDict {
            var paramsDict: [String: Any]?
            if let pd = attachDict["params"] as? [String: Any] {
                paramsDict = pd
            } else if let ps = attachDict["params"] as? String,
                      let pdata = ps.data(using: .utf8),
                      let parsed = try? JSONSerialization.jsonObject(with: pdata) as? [String: Any] {
                paramsDict = parsed
            }
            let dataSubDict: [String: Any]? = {
                if let dd = attachDict["data"] as? [String: Any] { return dd }
                if let ds = attachDict["data"] as? String,
                   let ddata = ds.data(using: .utf8),
                   let parsed = try? JSONSerialization.jsonObject(with: ddata) as? [String: Any] {
                    return parsed
                }
                return nil
            }()
            let action = ZolaJSON.firstNonEmptyString(
                attachDict["action"],
                paramsDict?["action"],
                dataSubDict?["action"]
            ).lowercased()
            let rawTitle = ZolaJSON.firstNonEmptyString(
                attachDict["title"],
                paramsDict?["title"],
                paramsDict?["mediaTitle"],
                paramsDict?["linkTitle"],
                paramsDict?["header"],
                paramsDict?["eCardHeaderString"],
                dataSubDict?["title"],
                dataSubDict?["header"]
            )
            var rawDesc = ZolaJSON.firstNonEmptyString(
                attachDict["description"],
                attachDict["desc"],
                paramsDict?["description"],
                paramsDict?["desc"],
                paramsDict?["caption"],
                paramsDict?["subtitle"],
                paramsDict?["subTitle"],
                paramsDict?["msg"],
                dataSubDict?["description"],
                dataSubDict?["subTitle"]
            )
            if rawDesc.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{"),
               let descData = rawDesc.data(using: .utf8),
               let descJson = try? JSONSerialization.jsonObject(with: descData) as? [String: Any] {
                rawDesc = ZolaJSON.firstNonEmptyString(
                    descJson["notifyTxt"],
                    descJson["message"],
                    descJson["text"],
                    descJson["content"],
                    descJson["header"],
                    descJson["eCardHeaderString"],
                    descJson["title"],
                    descJson["description"],
                    descJson["desc"]
                )
            }
            let notifyTxt = ZolaJSON.firstNonEmptyString(
                paramsDict?["notifyTxt"],
                attachDict["notifyTxt"],
                dataSubDict?["notifyTxt"],
                paramsDict?["message"],
                paramsDict?["text"],
                dataSubDict?["message"],
                dataSubDict?["text"]
            )

            let hasGroupContext = isGroup
                || inner["gId"] != nil || inner["groupId"] != nil || inner["grid"] != nil
                || attachDict["gId"] != nil || attachDict["groupId"] != nil
                || paramsDict?["gId"] != nil || paramsDict?["groupId"] != nil
            let peerNameCandidate: String = {
                let rawPeer = ZolaJSON.firstNonEmptyString(
                    paramsDict?["friendName"],
                    attachDict["friendName"],
                    dataSubDict?["friendName"],
                    !isSelf ? rawSenderName : "",
                    paramsDict?["dName"],
                    paramsDict?["displayName"]
                ).trimmingCharacters(in: .whitespacesAndNewlines)
                if rawPeer.isEmpty || rawPeer == "Cloud của tôi" || rawPeer.hasPrefix("UID ") {
                    return ""
                }
                return rawPeer
            }()
            let isExplicitNonFriendAction = action.hasPrefix("msginfo")
                || action.contains("pin")
                || action.contains("ttl")
                || action.contains("undo")
            let isFriendConnectNotice = !hasGroupContext && !isCloud && !isExplicitNonFriendAction && (
                action == "show.profile"
                    || action == "recommened.fst"
                    || action == "recommend.fst"
                    || action == "chat.tip"
                    || action.hasPrefix("receive_friend")
                    || action.contains("friend")
                    || mtLower.contains("recommend")
                    || mtLower.contains("tip")
                    || mtLower.contains("friend")
            )
            let defaultFriendNoticeText = peerNameCandidate.isEmpty
                ? "Các bạn đã được kết nối trên Zalo"
                : "Bạn vừa kết bạn với \(peerNameCandidate)"

            let isSystemNoticeAction = action == "show.profile"
                || action.hasPrefix("msginfo")
                || action == "recommened.fst"
                || action == "recommend.fst"
                || action == "chat.tip"
                || action.hasPrefix("receive_friend")

            if isGroup || mtLower.hasPrefix("group."),
               mtLower.hasPrefix("group.") || ZolaJSON.string(attachDict["href"]).isEmpty,
               let groupWire = Self.parseGroupWireItem(
                msgType: msgType,
                attach: attachDict,
                params: paramsDict,
                dataSub: dataSubDict,
                inner: inner,
                senderUid: uidFrom,
                senderName: rawSenderName
            ) {
                overrideKind = groupWire.kind
                resolvedMsgType = groupWire.resolvedMsgType
                textVal = groupWire.text
                groupEvent = groupWire.groupEvent
                boardCard = groupWire.boardCard
                keepGroupWireDebug = true
            } else if isSystemNoticeAction {
                overrideKind = "system"
                if !action.isEmpty && (mtLower == "webchat" || isExplicitNonFriendAction) {
                    resolvedMsgType = action
                }
                if !notifyTxt.isEmpty {
                    textVal = notifyTxt
                } else if !rawTitle.isEmpty && rawTitle != "sendBubbleMessage" {
                    textVal = rawTitle
                } else if !rawDesc.isEmpty && rawDesc != "sendBubbleMessage" && !rawDesc.hasPrefix("{") {
                    textVal = rawDesc
                } else if textVal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || textVal == "sendBubbleMessage"
                    || textVal.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{")
                {
                    if isFriendConnectNotice {
                        textVal = defaultFriendNoticeText
                    } else if action.contains("pin") {
                        textVal = "Đã ghim một tin nhắn"
                    } else {
                        textVal = "Thông báo hệ thống Zalo"
                    }
                }
            } else {
                let att = ZolaAttachment.fromRaw(msgType: msgType, attach: attachDict)
                if att.kind == "call" {
                    overrideKind = "call"
                    attachments.append(att)
                    textVal = att.title
                } else if att.kind == "location" {
                    overrideKind = "location"
                    attachments.append(att)
                    if textVal == "sendBubbleMessage" {
                        textVal = ""
                    }
                } else if att.kind == "ecard" {
                    if att.url.isEmpty && att.thumbUrl.isEmpty && !hasGroupContext && !isCloud && (att.title.isEmpty || att.title == "Thiệp chúc mừng Zalo") {
                        overrideKind = "system"
                        textVal = !notifyTxt.isEmpty ? notifyTxt : defaultFriendNoticeText
                    } else {
                        overrideKind = "ecard"
                        attachments.append(att)
                        if textVal == "sendBubbleMessage" || textVal == att.title {
                            textVal = ""
                        }
                    }
                } else if att.kind == "sticker" || att.kind == "card" {
                    attachments.append(att)
                    textVal = ""
                } else if att.kind == "unknown" && att.url.isEmpty {
                    let recoveredText: String = {
                        if !notifyTxt.isEmpty { return notifyTxt }
                        let cleanCurrent = textVal.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !cleanCurrent.isEmpty && cleanCurrent != "sendBubbleMessage" && !cleanCurrent.hasPrefix("{") {
                            return cleanCurrent
                        }
                        if !rawTitle.isEmpty && rawTitle != "sendBubbleMessage" { return rawTitle }
                        if !rawDesc.isEmpty && rawDesc != "sendBubbleMessage" && !rawDesc.hasPrefix("{") { return rawDesc }
                        return ""
                    }()
                    if !recoveredText.isEmpty {
                        overrideKind = (isFriendConnectNotice || mtLower.contains("sys")) ? "system" : "text"
                        textVal = recoveredText
                    } else {
                        overrideKind = "system"
                        textVal = isFriendConnectNotice
                            ? defaultFriendNoticeText
                            : "Thông báo hệ thống Zalo"
                    }
                } else {
                    attachments.append(att)
                    if textVal.isEmpty || textVal == "sendBubbleMessage" {
                        if att.kind == "photo" || att.kind == "voice" || att.kind == "video" {
                            textVal = (!rawDesc.isEmpty && rawDesc != "sendBubbleMessage" && !rawDesc.hasPrefix("{")) ? rawDesc : ""
                        } else {
                            textVal = (!rawTitle.isEmpty && rawTitle != "sendBubbleMessage") ? rawTitle : (rawDesc == "sendBubbleMessage" ? "" : rawDesc)
                        }
                    }
                }
            }
        } else if isGroup || mtLower.hasPrefix("group."), let groupWire = Self.parseGroupWireItem(
            msgType: msgType,
            attach: nil,
            params: nil,
            dataSub: nil,
            inner: inner,
            senderUid: uidFrom,
            senderName: rawSenderName
        ) {
            overrideKind = groupWire.kind
            resolvedMsgType = groupWire.resolvedMsgType
            textVal = groupWire.text
            groupEvent = groupWire.groupEvent
            boardCard = groupWire.boardCard
            keepGroupWireDebug = true
        } else if mtLower.contains("sticker") {
            let sid = ZolaJSON.int64(textVal)
            let cdn = ZolaAttachment.stickerCdnUrl(stickerId: sid)
            attachments.append(
                ZolaAttachment(
                    kind: "sticker",
                    url: cdn,
                    thumbUrl: cdn,
                    stickerId: sid
                )
            )
            textVal = ""
        }

        if textVal == "sendBubbleMessage" {
            overrideKind = "call"
            textVal = "Cuộc gọi Zalo"
            if attachments.isEmpty {
                attachments.append(
                    ZolaAttachment(
                        kind: "call",
                        url: "audio",
                        title: "Cuộc gọi Zalo",
                        descriptionText: "missed"
                    )
                )
            }
        }

        let rawQuoteField = inner["quote"] ?? rawItem["quote"]
        var parsedQuoteDict: [String: Any]? = rawQuoteField as? [String: Any]
        if parsedQuoteDict == nil,
           let qStr = rawQuoteField as? String,
           let qData = qStr.data(using: .utf8),
           let qJson = (try? JSONSerialization.jsonObject(with: qData)) as? [String: Any] {
            parsedQuoteDict = qJson
        }
        var quoteObj = mcryptQuote ?? parsedQuoteDict.map(ZolaQuote.fromRaw)
        if quoteObj == nil, textVal.hasPrefix("❝ "),
           let nl = textVal.firstIndex(of: "\n") {
            let quotedSnippet = String(textVal.dropFirst(2)[..<nl])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let actualBody = String(textVal[textVal.index(after: nl)...])
            if !quotedSnippet.isEmpty, !actualBody.isEmpty {
                quoteObj = ZolaQuote(ownerId: 0, text: quotedSnippet)
                textVal = actualBody
            }
        }

        let parsedReactions = Self.parseReactionEmojis(
            from: inner["reaction"] ?? inner["reactions"] ?? rawItem["reaction"] ?? rawItem["reactions"]
        )
        // Official Account broadcasts can arrive as `chat.webcontent` with no readable body at all.
        if overrideKind == nil, attachments.isEmpty, mtLower.contains("webcontent"),
           textVal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            overrideKind = "system"
            textVal = "Thông báo hệ thống Zalo"
        }
        // Any other message type we cannot render (e.g. `chat.list.action` article pushes, undecryptable
        // bodies) would otherwise show as an empty bubble with no hint of who sent it. Give it a readable
        // placeholder and keep it a normal bubble so the sender name/avatar still appear.
        var rawDebugJson = ""
        if mtLower == "chat.list.action", attachments.isEmpty {
            // Older versions discarded this payload, making future parser upgrades impossible.
            rawDebugJson = Self.wireDebugJson(rawItem)
        }
        if overrideKind == nil, attachments.isEmpty, quoteObj == nil,
           textVal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if mtLower.contains("list") {
                textVal = "[Danh sách bài viết]"
            } else {
                textVal = "[Tin nhắn chưa hỗ trợ hiển thị]"
                // Keep the original wire item so the chat UI can offer a local-only "copy raw data"
                // action to reverse-engineer this unknown message type later.
                rawDebugJson = Self.wireDebugJson(rawItem)
            }
        }
        // Every `group.*` wire message keeps its raw payload for later reverse engineering —
        // real `group.*` samples have not been captured yet so the parser stays multi-key.
        if keepGroupWireDebug, rawDebugJson.isEmpty {
            rawDebugJson = Self.wireDebugJson(rawItem)
        }
        let kind = overrideKind ?? attachments.first?.kind ?? (mtLower.contains("sys") ? "system" : "text")
        return ZolaMessage(
            id: resolvedId,
            cliMsgId: cliId,
            threadId: threadId,
            isGroup: isGroup,
            senderId: uidFrom,
            senderName: rawSenderName,
            toId: idTo,
            tsMs: tsMs,
            msgType: resolvedMsgType,
            kind: kind,
            text: textVal,
            attachments: attachments,
            quote: quoteObj,
            isSelf: isSelf,
            isCloud: isCloud,
            mcrypt: mcryptFlag,
            source: defaultSource,
            reactions: parsedReactions,
            hasReactionSnapshot: [inner["reaction"], inner["reactions"], rawItem["reaction"], rawItem["reactions"]].contains { $0 != nil && !($0 is NSNull) },
            mentions: ZolaMention.listFromRaw(
                mentions: inner["mentions"] ?? rawItem["mentions"],
                legacyMention: inner["mention"] ?? rawItem["mention"]
            ),
            webContent: webContent,
            rawDebugJson: rawDebugJson,
            groupEvent: groupEvent,
            boardCard: boardCard
        )
    }

    /// Sorted-keys JSON snapshot of a raw wire item for the local-only "copy raw data" debug
    /// affordance. Size-capped to avoid bloating the on-disk message cache; chat envelopes
    /// carry no session secrets.
    internal static func wireDebugJson(_ rawItem: [String: Any]) -> String {
        let cleaned = ZolaWebContent.sanitize(rawItem) as? [String: Any] ?? [:]
        guard JSONSerialization.isValidJSONObject(cleaned),
              let data = try? JSONSerialization.data(withJSONObject: cleaned, options: [.sortedKeys]),
              data.count <= 64 * 1024,
              let s = String(data: data, encoding: .utf8) else {
            return ""
        }
        return s
    }

    /// Parses `group.*` wire items (membership/admin/setting/name/avatar events and board
    /// objects: poll / pinned note / reminder). Returns `nil` when the item carries no
    /// `group.*` `msgType`/`action`. Wire field names are best-effort multi-key guesses — no
    /// real `group.*` payload sample has been captured yet, so every lookup tolerates missing
    /// keys, string-typed numbers and string-wrapped JSON; nothing is force-unwrapped.
    private static func parseGroupWireItem(
        msgType: String,
        attach: [String: Any]?,
        params: [String: Any]?,
        dataSub: [String: Any]?,
        inner: [String: Any],
        senderUid: Int64,
        senderName: String
    ) -> (kind: String, text: String, resolvedMsgType: String, groupEvent: ZolaGroupEventInfo?, boardCard: ZolaBoardCard?)? {
        func dictOrJSON(_ value: Any?) -> [String: Any]? {
            if let d = value as? [String: Any], !d.isEmpty { return d }
            if let s = value as? String {
                let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if t.hasPrefix("{"), let data = t.data(using: .utf8),
                   let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any], !d.isEmpty {
                    return d
                }
            }
            return nil
        }
        func arrOrJSON(_ value: Any?) -> [Any]? {
            if let a = value as? [Any], !a.isEmpty { return a }
            if let s = value as? String {
                let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if t.hasPrefix("["), let data = t.data(using: .utf8),
                   let a = try? JSONSerialization.jsonObject(with: data) as? [Any], !a.isEmpty {
                    return a
                }
            }
            return nil
        }

        let innerParams = dictOrJSON(inner["params"])
        let innerContent = dictOrJSON(inner["content"])
        let innerData = dictOrJSON(inner["data"])
        let innerAttach = dictOrJSON(inner["attach"])

        // The effective `group.*` action can hide inside `msgType`, `action`/`type`/`mt` of any
        // nesting level, or inside a string-wrapped JSON object.
        var groupAction = ""
        let actionCandidates: [Any?] = [
            msgType,
            attach?["action"], attach?["msgType"], attach?["type"], attach?["mt"],
            params?["action"], params?["msgType"], params?["type"], params?["mt"],
            dataSub?["action"], dataSub?["msgType"], dataSub?["type"], dataSub?["mt"],
            inner["action"], inner["msgType"], inner["type"], inner["mt"],
            innerParams?["action"], innerParams?["msgType"], innerParams?["type"], innerParams?["mt"],
            innerContent?["action"], innerContent?["msgType"], innerContent?["type"], innerContent?["mt"],
            innerData?["action"], innerData?["msgType"], innerData?["type"], innerData?["mt"],
            innerAttach?["action"], innerAttach?["msgType"], innerAttach?["type"], innerAttach?["mt"],
        ]
        // Container values may carry a string-wrapped JSON object holding the action. Only the
        // wrapped form counts here: a bare "group.x" string in `content` could be user text.
        let wrappedOnlyCandidates: [Any?] = [
            attach?["content"], attach?["topic"], attach?["data"], attach?["params"],
            params?["content"], params?["topic"], params?["data"],
        ]
        for candidate in actionCandidates {
            let s = ZolaJSON.string(candidate).trimmingCharacters(in: .whitespacesAndNewlines)
            if s.lowercased().hasPrefix("group.") { groupAction = s; break }
            if s.hasPrefix("{"), let wrapped = dictOrJSON(s) {
                for key in ["action", "msgType", "type", "mt"] {
                    let v = ZolaJSON.string(wrapped[key]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if v.lowercased().hasPrefix("group.") { groupAction = v; break }
                }
                if !groupAction.isEmpty { break }
            }
        }
        if groupAction.isEmpty {
            for candidate in wrappedOnlyCandidates {
                let s = ZolaJSON.string(candidate).trimmingCharacters(in: .whitespacesAndNewlines)
                guard s.hasPrefix("{"), let wrapped = dictOrJSON(s) else { continue }
                for key in ["action", "msgType", "type", "mt"] {
                    let v = ZolaJSON.string(wrapped[key]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if v.lowercased().hasPrefix("group.") { groupAction = v; break }
                }
                if !groupAction.isEmpty { break }
            }
        }
        guard !groupAction.isEmpty else { return nil }
        let ga = groupAction.lowercased()

        // Field lookup searches every dict we could unwrap, plus one level of container keys
        // (`boards`/`topic`/`data`...) that usually wraps the real payload.
        let baseDicts: [[String: Any]] = [
            attach, params, dataSub, innerParams, innerContent, innerData, innerAttach, inner,
        ].compactMap { $0 }
        var deepDicts = baseDicts
        let containerKeys = [
            "board", "boards", "topic", "topicInfo", "boardInfo", "poll", "pollInfo",
            "event", "eventInfo", "info", "detail", "groupInfo", "data", "params",
            "content", "msg", "body", "item", "extra",
        ]
        for d in baseDicts {
            for key in containerKeys {
                if let sub = dictOrJSON(d[key]) {
                    deepDicts.append(sub)
                } else if let arr = arrOrJSON(d[key]) {
                    for el in arr {
                        if let sub = el as? [String: Any], !sub.isEmpty { deepDicts.append(sub) }
                    }
                }
            }
        }

        func firstString(_ keys: [String]) -> String {
            for key in keys {
                for d in deepDicts {
                    let s = ZolaJSON.firstNonEmptyString(d[key])
                    if !s.isEmpty { return s }
                }
            }
            return ""
        }
        func int64OrNil(_ keys: [String]) -> Int64? {
            for key in keys {
                for d in deepDicts {
                    guard let v = d[key] else { continue }
                    if let n = v as? NSNumber { return n.int64Value }
                    if let s = v as? String {
                        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                        if let i = Int64(t) { return i }
                        if let head = t.split(separator: "_").first, let i = Int64(head) { return i }
                    }
                }
            }
            return nil
        }
        func intOrNil(_ keys: [String]) -> Int? {
            int64OrNil(keys).map { Int($0) }
        }
        func boolOrNil(_ keys: [String]) -> Bool? {
            for key in keys {
                for d in deepDicts {
                    guard let v = d[key] else { continue }
                    if let b = v as? Bool { return b }
                    if let n = v as? NSNumber { return n.boolValue }
                    if let s = v as? String {
                        let t = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                        if ["1", "true", "yes"].contains(t) { return true }
                        if ["0", "false", "no"].contains(t) { return false }
                    }
                }
            }
            return nil
        }
        func hasValue(_ keys: [String]) -> Bool {
            for key in keys {
                for d in deepDicts {
                    guard let v = d[key] else { continue }
                    if let s = v as? String, s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
                    if let a = v as? [Any], a.isEmpty { continue }
                    if let dd = v as? [String: Any], dd.isEmpty { continue }
                    return true
                }
            }
            return false
        }
        func firstArray(_ keys: [String]) -> [Any]? {
            for key in keys {
                for d in deepDicts {
                    if let a = arrOrJSON(d[key]) { return a }
                }
            }
            return nil
        }
        func strInDict(_ d: [String: Any], _ keys: [String]) -> String {
            for key in keys {
                let s = ZolaJSON.firstNonEmptyString(d[key])
                if !s.isEmpty { return s }
            }
            return ""
        }
        func intInDict(_ d: [String: Any], _ keys: [String]) -> Int? {
            for key in keys {
                guard let v = d[key] else { continue }
                if let n = v as? NSNumber { return n.intValue }
                if let s = v as? String, let i = Int(s.trimmingCharacters(in: .whitespacesAndNewlines)) { return i }
            }
            return nil
        }
        func boolInDict(_ d: [String: Any], _ keys: [String]) -> Bool? {
            for key in keys {
                guard let v = d[key] else { continue }
                if let b = v as? Bool { return b }
                if let n = v as? NSNumber { return n.boolValue }
                if let s = v as? String {
                    let t = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    if ["1", "true", "yes"].contains(t) { return true }
                    if ["0", "false", "no"].contains(t) { return false }
                }
            }
            return nil
        }

        var members: [(uid: Int64?, name: String?)] = []
        memberScan: for key in [
            "updateMems", "updateMembers", "members", "mems", "memberUids", "uIds", "ids", "uids",
            "listUids", "listUid", "addUids", "invitedUids", "newMems", "joinUids", "removeUids",
            "kickedUids", "adminIds", "grantedUids", "affectedUids",
        ] {
            for d in deepDicts {
                guard let raw = d[key] else { continue }
                var found: [(uid: Int64?, name: String?)] = []
                func addEntry(_ v: Any) {
                    if let md = v as? [String: Any] {
                        var mu: Int64?
                        for uidKey in ["uid", "id", "uId", "userId", "zaloId", "uidFrom", "memId"] {
                            guard let uv = md[uidKey] else { continue }
                            let i = ZolaJSON.int64(uv)
                            if i > 0 { mu = i; break }
                        }
                        let mn = strInDict(md, ["dName", "displayName", "zaloName", "name", "fullName", "nickname", "userName", "memName"])
                        if mu != nil || !mn.isEmpty {
                            found.append((mu, mn.isEmpty ? nil : mn))
                        }
                    } else if let n = v as? NSNumber {
                        found.append((n.int64Value, nil))
                    } else if let s = v as? String {
                        for part in s.split(separator: ",") {
                            let t = part.trimmingCharacters(in: .whitespacesAndNewlines)
                            if t.isEmpty { continue }
                            if let i = Int64(t) { found.append((i, nil)) } else { found.append((nil, t)) }
                        }
                    }
                }
                if let a = arrOrJSON(raw) {
                    a.forEach(addEntry)
                } else {
                    addEntry(raw)
                }
                if !found.isEmpty { members = found; break memberScan }
            }
        }

        let memberNames = members.compactMap { $0.name }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let memberUids = members.compactMap { $0.uid }.filter { $0 > 0 }
        let membersLabel: String = {
            if !memberNames.isEmpty {
                if memberNames.count < members.count {
                    return memberNames.joined(separator: ", ") + " và \(members.count - memberNames.count) thành viên khác"
                }
                return memberNames.joined(separator: ", ")
            }
            if members.count > 1 { return "\(members.count) thành viên" }
            if members.count == 1 { return "Một thành viên" }
            return ""
        }()
        let firstMemberLabel = memberNames.first ?? (members.isEmpty ? "" : "Một thành viên")

        let actorUid = int64OrNil([
            "createUid", "creatorId", "creatorUid", "actorUid", "updateBy", "byUid", "fromU", "uidFrom",
            "senderUid", "ownerId", "srcUid", "inviterUid", "approveUid",
        ]) ?? (senderUid > 0 ? senderUid : nil)
        let actorName = ZolaJSON.firstNonEmptyString(
            firstString([
                "actorName", "creatorName", "senderName", "byName", "updateByName", "ownerName",
                "inviterName", "fromD",
            ]),
            senderName,
            firstString(["dName", "displayName", "zaloName"])
        )
        let actorDisplay = actorName.isEmpty ? "Một thành viên" : actorName
        let resolvedType = msgType.lowercased().hasPrefix("group.") ? msgType : groupAction

        func makeEvent(detail: String? = nil) -> ZolaGroupEventInfo {
            ZolaGroupEventInfo(
                action: groupAction,
                actorUid: actorUid,
                actorName: actorName.isEmpty ? nil : actorName,
                memberUids: memberUids,
                memberNames: memberNames,
                detail: detail
            )
        }
        func makeCard(_ kind: ZolaBoardCard.Kind, title: String, body: String? = nil,
                      options: [ZolaPollOption] = [], totalVotes: Int? = nil,
                      isAnonymous: Bool? = nil, isClosed: Bool? = nil, allowMultiChoice: Bool? = nil,
                      startMs: Int64? = nil, repeatText: String? = nil, locationText: String? = nil,
                      actionText: String) -> ZolaBoardCard {
            ZolaBoardCard(
                kind: kind,
                title: title,
                body: body,
                options: options,
                totalVotes: totalVotes,
                isAnonymous: isAnonymous,
                isClosed: isClosed,
                allowMultiChoice: allowMultiChoice,
                startMs: startMs,
                repeatText: repeatText,
                locationText: locationText,
                creatorUid: actorUid,
                creatorName: actorName.isEmpty ? nil : actorName,
                actionText: actionText,
                pollId: kind == .poll ? {
                    let value = firstString(["pollId", "poll_id"])
                    return value.isEmpty ? nil : value
                }() : nil
            )
        }

        let boardTypeStr = firstString([
            "boardType", "topicType", "board_type", "topic_type", "bType", "boardKind", "topicKind",
        ]).lowercased()
        let typeFieldStr = firstString(["type", "btype"]).lowercased()
        let boardKindStr = boardTypeStr.isEmpty ? typeFieldStr : boardTypeStr

        // `group.remove.topic` (and delete-variants of board objects) stays a `system` pill.
        let isRemoveTopic = (ga.contains("remove") || ga.contains("delete") || ga.contains("cancel") || ga.hasPrefix("group.del"))
            && (ga.contains("topic") || ga.contains("board") || ga.contains("note") || ga.contains("remind") || ga.contains("poll"))
        if isRemoveTopic {
            let what = ga.contains("poll") ? "bình chọn"
                : ga.contains("remind") ? "nhắc hẹn"
                : ga.contains("note") ? "ghi chú"
                : "ghi chú/nhắc hẹn"
            return ("system", "\(actorDisplay) đã gỡ \(what)", resolvedType, makeEvent(), nil)
        }

        if ga.contains("poll") || boardKindStr == "poll" {
            let question = firstString(["question", "title", "subject", "content", "pollQuestion", "questionText"])
            var options: [ZolaPollOption] = []
            if let rawOptions = firstArray(["options", "answers", "choices", "pollOptions", "optionList", "items", "answersList"]) {
                for el in rawOptions {
                    if let od = el as? [String: Any] {
                        let label = strInDict(od, [
                            "content", "label", "text", "title", "answer", "option", "name", "value", "contentText", "desc",
                        ])
                        guard !label.isEmpty else { continue }
                        options.append(ZolaPollOption(
                            label: label,
                            votes: intInDict(od, [
                                "votes", "voteCount", "num_vote", "numVote", "count", "total", "totalVote", "voteNum", "numVotes",
                            ]),
                            votedBySelf: boolInDict(od, [
                                "isChecked", "voted", "votedBySelf", "selfVoted", "isVoted", "selected", "chosen", "voted_by_self",
                            ])
                        ))
                    } else if let s = el as? String {
                        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !t.isEmpty { options.append(ZolaPollOption(label: t)) }
                    } else if let n = el as? NSNumber {
                        options.append(ZolaPollOption(label: n.stringValue))
                    }
                }
            }
            var totalVotes = intOrNil([
                "totalVotes", "numVote", "total_votes", "voteCount", "num_votes", "totalVote", "sumVote", "totalVoteCount",
            ])
            if totalVotes == nil, !options.isEmpty, options.allSatisfy({ $0.votes != nil }) {
                totalVotes = options.reduce(0) { acc, option in
                    let v = max(0, min(option.votes ?? 0, 1_000_000_000))
                    return acc > Int.max - v ? Int.max : acc + v
                }
            }
            // Actual native201 vote-change events keep msgType=group.poll; their
            // params.msg template disambiguates the action from a generic poll card.
            let pollTemplate = dictOrJSON(params?["msg"])
            let isNativeVoteChange = ga == "group.poll" && (
                ZolaJSON.string(pollTemplate?["en"]) == "%1$s changed vote in the poll: %2$s"
                || ZolaJSON.string(pollTemplate?["vi"]) == "%1$s đổi lựa chọn trong cuộc bình chọn: %2$s"
            )
            let actionText: String
            if isNativeVoteChange {
                actionText = "đã đổi lựa chọn"
            } else if ga.contains("vote") {
                actionText = "đã bình chọn"
            } else if ga.contains("close") || ga.contains("end") || ga.contains("finish") {
                actionText = "đã kết thúc bình chọn"
            } else if ga.contains("share") {
                actionText = "đã chia sẻ bình chọn"
            } else if ga.contains("add") || ga.contains("update") || ga.contains("edit") {
                actionText = "đã cập nhật bình chọn"
            } else if ga.hasSuffix(".create") || ga.hasSuffix(".new") {
                actionText = "đã tạo bình chọn"
            } else {
                actionText = "đã cập nhật bình chọn"
            }
            let description = firstString(["desc", "description", "detail", "note"])
            let card = makeCard(
                .poll,
                title: question,
                body: description.isEmpty ? nil : description,
                options: options,
                totalVotes: totalVotes,
                isAnonymous: boolOrNil(["isAnonymous", "is_anonymous", "anonymous", "hideVoter", "hide_voter"]),
                isClosed: boolOrNil(["closed", "isClosed", "expired", "isExpired", "isEnd", "ended", "finish", "finished", "isDone"])
                    ?? intOrNil(["state"]).map { $0 == 2 },
                allowMultiChoice: boolOrNil([
                    "allowMultiChoices", "multiChoice", "allow_multi_choices", "isMultiChoice",
                    "multi_choice", "multiple", "allowMulti", "isMulti",
                ]),
                actionText: actionText
            )
            return ("board", question.isEmpty ? "Bình chọn" : "Bình chọn: \(question)", resolvedType, nil, card)
        }

        let startMsRaw = int64OrNil([
            "startTime", "remindTime", "eventTime", "start_time", "startMs", "start",
            "fromTime", "beginTime", "event_time", "remind_time", "timeStart",
        ])
        let looksLikeReminder = ga.contains("remind")
            || boardKindStr == "reminder" || boardKindStr == "remind" || boardKindStr == "event"
            || (startMsRaw != nil
                && boardKindStr != "note" && boardKindStr != "topic" && boardKindStr != "board"
                && !ga.contains("note")
                && (ga.contains("topic") || ga.contains("board") || ga.contains("event")))
        if looksLikeReminder {
            var startMs: Int64?
            if let raw = startMsRaw, raw > 0 {
                startMs = raw < 1_000_000_000_000 ? raw * 1_000 : raw
            }
            let rTitle = firstString(["title", "subject", "eventName", "remindTitle", "topicTitle", "name", "header", "text", "content"])
            let rBody = firstString(["desc", "description", "descStr", "detail", "body", "note", "subTitle"])
            let repeatStr = firstString(["repeatStr", "rrule", "repeat", "repeatText", "recurrence", "rule", "repeat_rule"])
            let locationStr = firstString(["locationStr", "location", "locationText", "place", "address", "venue"])
            let card = makeCard(
                .reminder,
                title: rTitle,
                body: rBody.isEmpty ? nil : rBody,
                startMs: startMs,
                repeatText: repeatStr.isEmpty ? nil : repeatStr,
                locationText: locationStr.isEmpty ? nil : locationStr,
                actionText: ga.contains("update") || ga.contains("edit") ? "đã cập nhật nhắc hẹn" : "đã tạo nhắc hẹn"
            )
            return ("board", rTitle.isEmpty ? "Nhắc hẹn" : "Nhắc hẹn: \(rTitle)", resolvedType, nil, card)
        }

        if ga.contains("topic") || ga.contains("board") || ga.contains("note")
            || boardKindStr == "note" || boardKindStr == "topic" || boardKindStr == "board"
            || boardKindStr == "grouptopic" || boardKindStr == "groupnote" {
            let rawContent = firstString([
                "content", "title", "text", "note", "topicContent", "desc", "description",
                "body", "msg", "detail", "subject",
            ])
            let titleLine = rawContent
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first { !$0.isEmpty } ?? ""
            let card = makeCard(
                .note,
                title: titleLine,
                body: rawContent.isEmpty ? nil : rawContent,
                actionText: "đã ghim ghi chú"
            )
            return ("board", titleLine.isEmpty ? "Ghi chú" : "Ghi chú: \(titleLine)", resolvedType, nil, card)
        }

        let newGroupName = firstString(["newName", "name", "groupName", "gName", "newTitle", "gname", "grName"])
        let hasAvatarField = hasValue(["avt", "avatar", "avatarUrl", "newAvt", "newAvatar", "avtUrl", "grpAvatar", "avatarPath"])
        // A generic `group.update` may echo the full group info (name + avt). Only trust the name as
        // a rename when the payload says so (`updateType`/`change`) or no avatar rides along.
        let updateHint = firstString(["updateType", "change", "changeType", "subType", "act"]).lowercased()
        let hintSaysAvatar = updateHint.contains("avt") || updateHint.contains("avatar") || updateHint.contains("photo")
        let hintSaysName = updateHint.contains("name") || updateHint.contains("title")
        let genericUpdateIsRename = !newGroupName.isEmpty && !hintSaysAvatar && (hintSaysName || !hasAvatarField)
        let genericUpdateIsAvatar = hasAvatarField && !hintSaysName && (hintSaysAvatar || newGroupName.isEmpty)
        let hasSettingsField = hasValue(["settings", "setting", "joinAppr", "lockSendMsg", "groupSettings", "newSetting", "approveMode"])
        let joinedViaLink = hasValue(["joinByLink", "viaLink", "inviteLink", "joinLink", "byLink", "linkJoin", "join_via_link"])
            || ga.contains("link")
        let soleMemberIsActor = members.count == 1 && actorUid != nil && members[0].uid == actorUid

        let membersText = membersLabel.isEmpty ? actorDisplay : membersLabel
        // UID-only member lists (leave / join by link) carry the person's name only in the sender
        // fields; never print "Một thành viên" when that member is the actor we already know.
        let soleUnnamedMemberIsActor = memberNames.isEmpty && members.count == 1 && !actorName.isEmpty
            && (members[0].uid == nil || members[0].uid == actorUid)
        let firstMemberText = (firstMemberLabel.isEmpty || soleUnnamedMemberIsActor) ? actorDisplay : firstMemberLabel
        var detail: String?
        let eventText: String
        if ga.contains("admin") || ga.contains("deputy") {
            if ga.contains("remove") || ga.contains("del") || ga.contains("revoke") || ga.contains("unset") {
                eventText = "\(actorDisplay) đã xoá vai trò phó nhóm của \(membersText)"
            } else {
                eventText = "\(actorDisplay) đã bổ nhiệm \(membersText) làm phó nhóm"
            }
        } else if ga.contains("force") || ga.contains("kick") || ga.contains("block")
            || ((ga.contains("remove") || ga.contains("del")) && (ga.contains("mem") || ga.contains("user"))) {
            eventText = "\(actorDisplay) đã xoá \(membersText) khỏi nhóm"
        } else if ga.contains("leave") || ga.contains("out") {
            eventText = "\(firstMemberText) đã rời nhóm"
        } else if ga.contains("appr") {
            eventText = members.isEmpty
                ? "\(actorDisplay) đã thay đổi cài đặt nhóm"
                : "\(actorDisplay) đã duyệt \(membersText) vào nhóm"
        } else if ga.contains("setting") || ga.contains("config") || hasSettingsField {
            eventText = "\(actorDisplay) đã thay đổi cài đặt nhóm"
        } else if ga.contains("join") || ga.contains("invite") || ga.contains("addmem") || ga.hasPrefix("group.add") {
            if joinedViaLink, !members.isEmpty {
                eventText = "\(firstMemberText) đã tham gia nhóm"
            } else if soleMemberIsActor || members.isEmpty {
                eventText = "\(actorDisplay) đã tham gia nhóm"
            } else {
                eventText = "\(actorDisplay) đã thêm \(membersText) vào nhóm"
            }
        } else if ga.contains("name") || ga.contains("rename") || (ga.contains("update") && genericUpdateIsRename) {
            if newGroupName.isEmpty {
                eventText = "\(actorDisplay) đã cập nhật nhóm"
            } else {
                detail = newGroupName
                eventText = "\(actorDisplay) đã đổi tên nhóm thành \(newGroupName)"
            }
        } else if ga.contains("avt") || ga.contains("avatar") || (ga.contains("update") && genericUpdateIsAvatar) {
            eventText = "\(actorDisplay) đã đổi ảnh đại diện nhóm"
        } else if genericUpdateIsRename {
            detail = newGroupName
            eventText = "\(actorDisplay) đã đổi tên nhóm thành \(newGroupName)"
        } else if genericUpdateIsAvatar {
            eventText = "\(actorDisplay) đã đổi ảnh đại diện nhóm"
        } else if !newGroupName.isEmpty && hasAvatarField {
            eventText = "\(actorDisplay) đã cập nhật thông tin nhóm"
        } else {
            eventText = "\(actorDisplay) đã cập nhật nhóm"
        }
        return ("system", eventText, resolvedType, makeEvent(detail: detail), nil)
    }
}

public struct ZolaConversation: Codable, Sendable, Identifiable, Equatable {
    public var id: Int64 { threadId }
    public let threadId: Int64
    public let isGroup: Bool
    public let isCloud: Bool
    public let title: String
    public let avatarUrl: String
    public let lastMessage: ZolaMessage?
    public let unreadCount: Int
    public let needsReply: Bool
    public let memberCount: Int
    public let messages: [ZolaMessage]

    public init(
        threadId: Int64,
        isGroup: Bool,
        isCloud: Bool = false,
        title: String,
        avatarUrl: String = "",
        lastMessage: ZolaMessage? = nil,
        unreadCount: Int = 0,
        needsReply: Bool = false,
        memberCount: Int = 2,
        messages: [ZolaMessage] = []
    ) {
        self.threadId = threadId
        self.isGroup = isGroup
        self.isCloud = isCloud
        self.title = title
        self.avatarUrl = avatarUrl
        self.lastMessage = lastMessage
        self.unreadCount = unreadCount
        self.needsReply = needsReply
        self.memberCount = memberCount
        self.messages = messages
    }
}

public struct ZolaSendReceipt: Codable, Sendable, Equatable {
    public let ok: Bool
    public let dryRun: Bool
    public let sent: Bool
    public let endpoint: String
    public let uid: Int64
    public let desId: Int64
    public let cmd: Int16
    public let innerSocketCmd: Int16
    public let subCmd: Int8
    public let clientIdMs: Int64
    public let frameSize: UInt32
    public let cryptKeySha256_8: String
    public let serverErrorCode: Int?
    public let serverGlobalMsgId: Int64?

    public init(
        ok: Bool,
        dryRun: Bool,
        sent: Bool,
        endpoint: String,
        uid: Int64,
        desId: Int64,
        cmd: Int16,
        innerSocketCmd: Int16,
        subCmd: Int8,
        clientIdMs: Int64,
        frameSize: UInt32,
        cryptKeySha256_8: String,
        serverErrorCode: Int? = nil,
        serverGlobalMsgId: Int64? = nil
    ) {
        self.ok = ok
        self.dryRun = dryRun
        self.sent = sent
        self.endpoint = endpoint
        self.uid = uid
        self.desId = desId
        self.cmd = cmd
        self.innerSocketCmd = innerSocketCmd
        self.subCmd = subCmd
        self.clientIdMs = clientIdMs
        self.frameSize = frameSize
        self.cryptKeySha256_8 = cryptKeySha256_8
        self.serverErrorCode = serverErrorCode
        self.serverGlobalMsgId = serverGlobalMsgId
    }
}

public struct ZolaEvent: Codable, Sendable, Equatable {
    public let type: String // "message.new" | "message.updated" | "message.reaction" | "session.expired"
    public let tsMs: Int64
    public let message: ZolaMessage?
    public let errorCode: Int?
    public let reaction: ZolaReactionUpdate?
    public let delivery: ZolaMessageDeliveryUpdate?
    public let typing: ZolaTypingUpdate?
    public let groupId: Int64?

    public init(type: String, tsMs: Int64, message: ZolaMessage? = nil, errorCode: Int? = nil, reaction: ZolaReactionUpdate? = nil, delivery: ZolaMessageDeliveryUpdate? = nil, typing: ZolaTypingUpdate? = nil, groupId: Int64? = nil) {
        self.type = type
        self.tsMs = tsMs
        self.message = message
        self.errorCode = errorCode
        self.reaction = reaction
        self.delivery = delivery
        self.typing = typing
        self.groupId = groupId
    }
}

public struct ZolaGroupCursor: Codable, Sendable, Equatable {
    public var glbMsgId: Int64
    public var tsJoinGroup: Int64

    public init(glbMsgId: Int64 = 1, tsJoinGroup: Int64 = 1) {
        self.glbMsgId = glbMsgId
        self.tsJoinGroup = tsJoinGroup
    }
}

public struct ZolaWatermarkState: Codable, Sendable, Equatable {
    public var initialized: Bool
    public var femcLastCliId: Int64
    public var femcLastGlbId: Int64
    public var groupCursors: [Int64: ZolaGroupCursor]
    public var singleCursors: [Int64: Int64]
    /// Recency tick per key; a repeated key is refreshed, so anything the server keeps returning stays remembered.
    private var seenTicks: [String: UInt64]
    private var seenClock: UInt64
    /// Grows past `maxSeenIds` when one snapshot is larger, so a snapshot can never evict its own keys.
    private var seenCapacity: Int

    /// Remembered keys, least recently seen first.
    public var seenIds: [String] {
        seenTicks.sorted { $0.value < $1.value }.map(\.key)
    }

    private enum CodingKeys: String, CodingKey {
        case initialized
        case femcLastCliId
        case femcLastGlbId
        case groupCursors
        case singleCursors
        case seenIds
    }

    private static func seenTickMap(from keys: [String]) -> (ticks: [String: UInt64], clock: UInt64) {
        var ticks: [String: UInt64] = [:]
        ticks.reserveCapacity(keys.count)
        var clock: UInt64 = 0
        for key in keys {
            clock += 1
            ticks[key] = clock
        }
        return (ticks, clock)
    }

    public init(
        initialized: Bool = false,
        femcLastCliId: Int64 = 0,
        femcLastGlbId: Int64 = 0,
        groupCursors: [Int64: ZolaGroupCursor] = [:],
        singleCursors: [Int64: Int64] = [:],
        seenIds: [String] = []
    ) {
        self.initialized = initialized
        self.femcLastCliId = femcLastCliId
        self.femcLastGlbId = femcLastGlbId
        self.groupCursors = groupCursors
        self.singleCursors = singleCursors
        let seen = Self.seenTickMap(from: Array(seenIds.suffix(ZolaConstants.maxSeenIds)))
        self.seenTicks = seen.ticks
        self.seenClock = seen.clock
        self.seenCapacity = ZolaConstants.maxSeenIds
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.initialized = try container.decodeIfPresent(Bool.self, forKey: .initialized) ?? false
        self.femcLastCliId = try container.decodeIfPresent(Int64.self, forKey: .femcLastCliId) ?? 0
        self.femcLastGlbId = try container.decodeIfPresent(Int64.self, forKey: .femcLastGlbId) ?? 0
        self.groupCursors = try container.decodeIfPresent([Int64: ZolaGroupCursor].self, forKey: .groupCursors) ?? [:]
        self.singleCursors = try container.decodeIfPresent([Int64: Int64].self, forKey: .singleCursors) ?? [:]
        let rawSeen = try container.decodeIfPresent([String].self, forKey: .seenIds) ?? []
        let seen = Self.seenTickMap(from: rawSeen)
        self.seenTicks = seen.ticks
        self.seenClock = seen.clock
        self.seenCapacity = max(ZolaConstants.maxSeenIds, rawSeen.count)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(initialized, forKey: .initialized)
        try container.encode(femcLastCliId, forKey: .femcLastCliId)
        try container.encode(femcLastGlbId, forKey: .femcLastGlbId)
        try container.encode(groupCursors, forKey: .groupCursors)
        try container.encode(singleCursors, forKey: .singleCursors)
        try container.encode(Array(seenIds.suffix(seenCapacity)), forKey: .seenIds)
    }

    public static func == (lhs: ZolaWatermarkState, rhs: ZolaWatermarkState) -> Bool {
        lhs.initialized == rhs.initialized
            && lhs.femcLastCliId == rhs.femcLastCliId
            && lhs.femcLastGlbId == rhs.femcLastGlbId
            && lhs.groupCursors == rhs.groupCursors
            && lhs.singleCursors == rhs.singleCursors
            && lhs.seenIds == rhs.seenIds
    }

    /// Returns `true` the first time `key` is seen. Every call refreshes the key, so eviction only reaches
    /// keys the server stopped returning: FIFO order replayed a whole snapshot once its oldest key fell out.
    public mutating func markSeen(_ key: String) -> Bool {
        seenClock += 1
        let isNew = seenTicks.updateValue(seenClock, forKey: key) == nil
        // Batched so a poll does not re-sort the table for every new key.
        if isNew, seenTicks.count > seenCapacity + Self.seenEvictionBatch {
            let staleKeys = seenTicks.sorted { $0.value < $1.value }.prefix(seenTicks.count - seenCapacity)
            for entry in staleKeys {
                seenTicks.removeValue(forKey: entry.key)
            }
        }
        return isNew
    }

    private static let seenEvictionBatch = 256

    /// Call before scanning a snapshot. Each message consumes up to two keys (`dedupeKey` + `glb:`).
    public mutating func reserveSeenCapacity(forMessages count: Int) {
        seenCapacity = max(seenCapacity, count * 2 + 256)
    }

    public mutating func registerGroups(_ gids: [Int64]) {
        for gid in gids where gid > 0 && groupCursors[gid] == nil {
            groupCursors[gid] = ZolaGroupCursor(glbMsgId: 1, tsJoinGroup: 1)
        }
    }

    public mutating func registerSingles(_ uids: [Int64]) {
        for uid in uids where uid > 0 && singleCursors[uid] == nil {
            singleCursors[uid] = 1
        }
    }
}

public enum ZolaFriendRequestDirection: String, Codable, Sendable, Equatable {
    case incoming
    case outgoing
    case suggestion
}

public enum ZolaFriendRequestStatus: String, Codable, Sendable, Equatable {
    case pending
    case accepted
    case declined
    case cancelled
}

public struct ZolaFriendRequest: Codable, Sendable, Identifiable, Equatable {
    public var id: String { "\(accountUid):\(direction.rawValue):\(uid)" }
    public let accountUid: Int64
    public let uid: Int64
    public var displayName: String
    public var zaloName: String
    public var avatarUrl: String
    public var phone: String
    public var message: String
    public var sourceLabel: String
    public var timestampMs: Int64
    public var direction: ZolaFriendRequestDirection
    public var status: ZolaFriendRequestStatus

    public init(
        accountUid: Int64,
        uid: Int64,
        displayName: String,
        zaloName: String = "",
        avatarUrl: String = "",
        phone: String = "",
        message: String = "",
        sourceLabel: String = "Từ tìm kiếm số điện thoại",
        timestampMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
        direction: ZolaFriendRequestDirection = .incoming,
        status: ZolaFriendRequestStatus = .pending
    ) {
        self.accountUid = accountUid
        self.uid = uid
        self.displayName = displayName
        self.zaloName = zaloName
        self.avatarUrl = avatarUrl
        self.phone = phone
        self.message = message
        self.sourceLabel = sourceLabel
        self.timestampMs = timestampMs
        self.direction = direction
        self.status = status
    }

    public var asUser: ZolaUser {
        ZolaUser(
            uid: uid,
            displayName: displayName,
            zaloName: zaloName,
            avatarUrl: avatarUrl,
            fullAvatarUrl: avatarUrl,
            phone: phone,
            isFriend: status == .accepted
        )
    }

    public static func fromServerDict(
        _ raw: [String: Any],
        accountUid: Int64,
        defaultDirection: ZolaFriendRequestDirection = .incoming
    ) -> ZolaFriendRequest? {
        let user = ZolaUser.fromServerDict(raw, isFriend: false)
        guard user.uid > 0, !user.isLockedAccount else { return nil }
        let recommInfo = raw["recommInfo"] as? [String: Any]
        let fReqInfo = raw["fReqInfo"] as? [String: Any]
        let recommType = ZolaJSON.int(raw["recommType"] ?? recommInfo?["recommType"])
        let isFrReq = ZolaJSON.int(raw["isFriendRequest"] ?? raw["is_friend_request"])
        let resolvedDirection: ZolaFriendRequestDirection
        if isFrReq == 1 || recommType == 2 {
            resolvedDirection = .incoming
        } else if recommType == 1 {
            resolvedDirection = .suggestion
        } else {
            resolvedDirection = defaultDirection
        }

        let msg = [
            raw["message"],
            raw["msg"],
            recommInfo?["message"],
            recommInfo?["msg"],
            fReqInfo?["message"],
            raw["friendRequestMsg"],
        ]
            .compactMap { ZolaJSON.string($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""

        let srcLabel = [
            raw["sourceLabel"],
            recommInfo?["sourceText"],
            raw["recommSrcText"],
            raw["srcText"],
        ]
            .compactMap { ZolaJSON.string($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? {
                switch resolvedDirection {
                case .incoming: return "Muốn kết bạn với bạn"
                case .outgoing: return "Đã gửi lời mời kết bạn"
                case .suggestion: return "Có thể bạn quen"
                }
            }()

        let rawTs = ZolaJSON.int64(
            raw["recommTime"] ?? recommInfo?["recommTime"] ?? fReqInfo?["time"]
                ?? raw["timestamp"] ?? raw["time"] ?? raw["createdTime"]
        )
        let tsMs: Int64
        if rawTs > 1_000_000_000_000 {
            tsMs = rawTs
        } else if rawTs > 1_000_000_000 {
            tsMs = rawTs * 1000
        } else {
            tsMs = Int64(Date().timeIntervalSince1970 * 1000)
        }

        return ZolaFriendRequest(
            accountUid: accountUid,
            uid: user.uid,
            displayName: user.displayName,
            zaloName: user.zaloName,
            avatarUrl: user.avatarUrl,
            phone: user.phone,
            message: msg,
            sourceLabel: srcLabel,
            timestampMs: tsMs,
            direction: resolvedDirection,
            status: .pending
        )
    }

    /// `api/friend/recommendsv2/list` payload: `recommItems[].dataInfo`, where `recommType` 2 = received request, 1 = suggestion.
    public static func parseRecommendations(_ data: [String: Any], accountUid: Int64) -> [ZolaFriendRequest] {
        let items = data["recommItems"] as? [[String: Any]] ?? []
        return items.compactMap { item in
            let info = (item["dataInfo"] as? [String: Any]) ?? item
            return fromServerDict(info, accountUid: accountUid, defaultDirection: .suggestion)
        }
    }

    /// `api/friend/requested/list` payload: an object keyed by userId, each value carrying `fReqInfo {message, src, time}`.
    public static func parseSentRequests(_ data: [String: Any], accountUid: Int64) -> [ZolaFriendRequest] {
        parseSocketSentRequests(data, accountUid: accountUid)
    }

    private static func extractFriendSectionItems(_ raw: Any?) -> [[String: Any]] {
        guard let raw, !(raw is NSNull) else { return [] }
        if let arr = raw as? [[String: Any]] {
            return arr.map { item in
                if let info = item["dataInfo"] as? [String: Any] {
                    var merged = info
                    for (k, v) in item where k != "dataInfo" && merged[k] == nil {
                        merged[k] = v
                    }
                    return merged
                }
                if let profile = item["profile"] as? [String: Any] {
                    var merged = profile
                    for (k, v) in item where k != "profile" && merged[k] == nil {
                        merged[k] = v
                    }
                    return merged
                }
                return item
            }
        }
        if let anyArr = raw as? [Any] {
            var collected: [[String: Any]] = []
            for el in anyArr {
                if let dict = el as? [String: Any] {
                    collected.append(contentsOf: extractFriendSectionItems([dict]))
                } else {
                    let uid = ZolaJSON.int64(el)
                    if uid > 0 {
                        collected.append(["userId": String(uid)])
                    }
                }
            }
            return collected
        }
        guard let dict = raw as? [String: Any] else { return [] }
        let sectionKeys = [
            "items", "discoverItems", "requestItems", "recommItems",
            "list", "users", "requests", "data",
        ]
        for key in sectionKeys {
            if let nested = dict[key], !(nested is NSNull) {
                let extracted = extractFriendSectionItems(nested)
                if !extracted.isEmpty {
                    return extracted
                }
            }
        }
        // Fallback: dictionary keyed by numeric UID strings (`"100000102": {...}`)
        var mapItems: [[String: Any]] = []
        for (k, v) in dict {
            guard var entry = v as? [String: Any] else { continue }
            if entry["userId"] == nil && entry["uid"] == nil && entry["id"] == nil,
               let parsedUid = Int64(k), parsedUid > 0 {
                entry["userId"] = String(parsedUid)
            }
            mapItems.append(contentsOf: extractFriendSectionItems([entry]))
        }
        return mapItems
    }

    /// Parses native `UXChatSocket` `cmd = 1584/2` (`getFriendRequestAndSuggestList` at `0x100e7d7d4`) response `data`.
    public static func parseSocketRequestAndSuggest(_ data: [String: Any], accountUid: Int64) -> [ZolaFriendRequest] {
        var out: [ZolaFriendRequest] = []
        var seenUids = Set<Int64>()

        let incomingDicts = extractFriendSectionItems(
            data["requestList"] ?? data["request_list"] ?? data["receivedList"]
        )
        for dict in incomingDicts {
            guard var fr = fromServerDict(dict, accountUid: accountUid, defaultDirection: .incoming) else { continue }
            fr.direction = .incoming
            if seenUids.insert(fr.uid).inserted {
                out.append(fr)
            }
        }

        let suggestDicts = extractFriendSectionItems(
            data["suggestList"] ?? data["suggest_list"] ?? data["recommItems"]
        )
        for dict in suggestDicts {
            guard let fr = fromServerDict(dict, accountUid: accountUid, defaultDirection: .suggestion) else { continue }
            if seenUids.insert(fr.uid).inserted {
                out.append(fr)
            }
        }

        if out.isEmpty, data["requestList"] == nil, data["suggestList"] == nil {
            for fr in parseRecommendations(data, accountUid: accountUid) where seenUids.insert(fr.uid).inserted {
                out.append(fr)
            }
        }
        return out
    }

    /// Parses native `UXChatSocket` `cmd = 376/1` (`syncSentFriendRequests` at `0x100e8dc00`) or HTTP `requested/list` response `data`.
    public static func parseSocketSentRequests(_ data: [String: Any], accountUid: Int64) -> [ZolaFriendRequest] {
        let rawItems = extractFriendSectionItems(
            data["sentList"] ?? data["requestList"] ?? data["data"] ?? data
        )
        var out: [ZolaFriendRequest] = []
        var seenUids = Set<Int64>()
        for dict in rawItems {
            guard var fr = fromServerDict(dict, accountUid: accountUid, defaultDirection: .outgoing) else { continue }
            fr.direction = .outgoing
            if seenUids.insert(fr.uid).inserted {
                out.append(fr)
            }
        }
        return out
    }
}

/// High-level 1-1 relationship state returned by `cmd = 378, subCmd = 1` (`FriendRequestManager getFriendRequestStatus:`).
public enum ZolaFriendRelationship: String, Sendable, Equatable, Codable {
    case friends
    case incomingRequest
    case outgoingRequest
    case stranger
}

/// Typed result of `ZolaClient.getPeerFriendStatus(_:)` (`UXChatSocket cmd = 378, subCmd = 1`).
///
/// Server flags are named from `uid`'s perspective (`0x100e84800`–`0x100e848fc`):
/// - `isFriend == 1`: confirmed friends (`.friends`)
/// - `isRequesting == 1`: `uid` is requesting us (`.incomingRequest`, `status = 3`)
/// - `isRequested == 1`: `uid` has been requested by us (`.outgoingRequest`, `status = 2`)
public struct ZolaPeerFriendStatus: Sendable, Equatable, Codable {
    public let uid: Int64
    public var isFriend: Bool
    public var isRequesting: Bool
    public var isRequested: Bool
    public var addFriendPrivacy: Int
    public var message: String

    public init(
        uid: Int64,
        isFriend: Bool = false,
        isRequesting: Bool = false,
        isRequested: Bool = false,
        addFriendPrivacy: Int = 0,
        message: String = ""
    ) {
        self.uid = uid
        self.isFriend = isFriend
        self.isRequesting = isRequesting
        self.isRequested = isRequested
        self.addFriendPrivacy = addFriendPrivacy
        self.message = message
    }

    public var relationship: ZolaFriendRelationship {
        if isFriend { return .friends }
        if isRequesting { return .incomingRequest }
        if isRequested { return .outgoingRequest }
        return .stranger
    }

    public static func fromServerDict(_ data: [String: Any], uid: Int64) -> ZolaPeerFriendStatus {
        func isFlagTrue(_ raw: Any?) -> Bool {
            guard let raw, !(raw is NSNull) else { return false }
            if let b = raw as? Bool { return b }
            if let s = raw as? String {
                let lower = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if lower == "true" || lower == "1" { return true }
            }
            return ZolaJSON.int(raw) == 1
        }
        let friendFlag = isFlagTrue(data["isFriend"] ?? data["is_friend"] ?? data["friendStatus"])
        let requestingFlag = isFlagTrue(
            data["isRequesting"] ?? data["is_requesting"] ?? data["isReceived"] ?? data["isFriendRequest"]
        )
        let requestedFlag = isFlagTrue(
            data["isRequested"] ?? data["is_requested"] ?? data["isSent"] ?? data["isRequestedByMe"]
        )
        let privacy = ZolaJSON.int(data["addFriendPrivacy"] ?? data["add_friend_privacy"])
        let msg = ZolaJSON.string(data["message"] ?? data["msg"] ?? data["friendRequestMsg"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return ZolaPeerFriendStatus(
            uid: uid,
            isFriend: friendFlag,
            isRequesting: requestingFlag,
            isRequested: requestedFlag,
            addFriendPrivacy: privacy,
            message: msg
        )
    }
}

/// Outcome of `api/friend/profile/get` for one phone number.
public enum ZolaPhoneLookupResult: Sendable, Equatable {
    case found(ZolaUser)
    /// Zalo answered but no account is registered (or searchable) for this number.
    case notFound
    /// Zalo refused the lookup (rate limit, privacy, invalid params…); `message` is Zalo's own text.
    case failed(code: Int, message: String)
}

// MARK: - Zalo Labels & Mute Models (`getLabels`, `updateLabels`, `getMute`, `setMute`)

/// Represents a Zalo conversation classification label (`LabelData`).
public struct ZolaLabel: Sendable, Equatable, Codable, Identifiable {
    public let id: Int
    public var text: String
    public var textKey: String
    public var conversations: [String]
    public var color: String
    public var offset: Int
    public var emoji: String
    public var createTime: Int64
    public var conversationTitles: [String]

    public init(
        id: Int,
        text: String,
        textKey: String = "",
        conversations: [String] = [],
        color: String = "#0068FF",
        offset: Int = 0,
        emoji: String = "",
        createTime: Int64 = 0,
        conversationTitles: [String] = []
    ) {
        self.id = id
        self.text = text
        self.textKey = textKey.isEmpty ? text.lowercased() : textKey
        self.conversations = conversations
        self.color = color
        self.offset = offset
        self.emoji = emoji
        self.createTime = createTime
        self.conversationTitles = conversationTitles
    }

    enum CodingKeys: String, CodingKey {
        case id, text, textKey, conversations, color, offset, emoji, createTime, conversationTitles
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = (try? c.decode(Int.self, forKey: .id)) ?? 0
        let t = (try? c.decode(String.self, forKey: .text)) ?? ""
        self.text = t
        let tk = (try? c.decode(String.self, forKey: .textKey)) ?? ""
        self.textKey = tk.isEmpty ? t.lowercased() : tk
        self.conversations = (try? c.decode([String].self, forKey: .conversations)) ?? []
        self.color = (try? c.decode(String.self, forKey: .color)) ?? "#0068FF"
        self.offset = (try? c.decode(Int.self, forKey: .offset)) ?? 0
        self.emoji = (try? c.decode(String.self, forKey: .emoji)) ?? ""
        self.createTime = (try? c.decode(Int64.self, forKey: .createTime)) ?? 0
        self.conversationTitles = (try? c.decode([String].self, forKey: .conversationTitles)) ?? []
    }

    public func matchesThread(threadId: Int64, title: String? = nil) -> Bool {
        let tid = String(threadId)
        if conversations.contains(tid) || conversations.contains("g\(tid)") {
            return true
        }
        if let title, !title.isEmpty, !conversationTitles.isEmpty {
            let normTitle = Self.normalizeTitle(title)
            if !normTitle.isEmpty {
                return conversationTitles.contains { cand in
                    let normCand = Self.normalizeTitle(cand)
                    guard !normCand.isEmpty else { return false }
                    if normCand == normTitle { return true }
                    if normCand.hasSuffix("...") {
                        let prefix = String(normCand.dropLast(3)).trimmingCharacters(in: .whitespaces)
                        if prefix.count >= 10 && normTitle.hasPrefix(prefix) { return true }
                    }
                    return false
                }
            }
        }
        return false
    }

    public static func normalizeTitle(_ raw: String) -> String {
        let folded = raw
            .replacingOccurrences(of: "đ", with: "d")
            .replacingOccurrences(of: "Đ", with: "d")
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "vi_VN"))
        return folded
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    public static func fromServerDict(_ raw: [String: Any]) -> ZolaLabel? {
        let id = ZolaJSON.int(raw["id"])
        let text = ZolaJSON.string(raw["text"]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let textKey = ZolaJSON.string(raw["textKey"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let convs: [String]
        if let arr = raw["conversations"] as? [Any] {
            convs = arr.map { ZolaJSON.string($0) }.filter { !$0.isEmpty }
        } else {
            convs = []
        }
        let titles: [String]
        if let arr = raw["conversationTitles"] as? [Any] {
            titles = arr.map { ZolaJSON.string($0) }.filter { !$0.isEmpty }
        } else {
            titles = []
        }
        let color = ZolaJSON.string(raw["color"]).trimmingCharacters(in: .whitespacesAndNewlines)
        return ZolaLabel(
            id: id,
            text: text,
            textKey: textKey.isEmpty ? text.lowercased() : textKey,
            conversations: convs,
            color: color.isEmpty ? "#0068FF" : color,
            offset: ZolaJSON.int(raw["offset"]),
            emoji: ZolaJSON.string(raw["emoji"]),
            createTime: ZolaJSON.int64(raw["createTime"]),
            conversationTitles: titles
        )
    }

    public func toServerDict() -> [String: Any] {
        [
            "id": id,
            "text": text,
            "textKey": textKey,
            "conversations": conversations,
            "color": color,
            "offset": offset,
            "emoji": emoji,
            "createTime": createTime,
        ]
    }
}

/// Response from `getLabels()` / `updateLabels(...)` (`GetLabelsResponse`).
public struct ZolaLabelsResponse: Sendable, Equatable, Codable {
    public var labelData: [ZolaLabel]
    public var version: Int
    public var lastUpdateTime: Int64

    public init(labelData: [ZolaLabel] = [], version: Int = 0, lastUpdateTime: Int64 = 0) {
        self.labelData = labelData
        self.version = version
        self.lastUpdateTime = lastUpdateTime
    }

    public static func fromServerDict(_ data: [String: Any]) -> ZolaLabelsResponse {
        var rawLabels: [[String: Any]] = []
        if let arr = data["labelData"] as? [[String: Any]] {
            rawLabels = arr
        } else if let str = data["labelData"] as? String,
                  let bytes = str.data(using: .utf8),
                  let parsed = (try? JSONSerialization.jsonObject(with: bytes)) as? [[String: Any]] {
            rawLabels = parsed
        } else if let arr = data["labels"] as? [[String: Any]] {
            rawLabels = arr
        }
        let labels = rawLabels.compactMap { ZolaLabel.fromServerDict($0) }
        return ZolaLabelsResponse(
            labelData: labels,
            version: ZolaJSON.int(data["version"]),
            lastUpdateTime: ZolaJSON.int64(data["lastUpdateTime"])
        )
    }
}

/// Mute duration options matching the native `MuteDuration`.
public enum ZolaMuteDuration: Int, Sendable, Equatable, Codable {
    case unmute = 0
    case oneHour = 3600
    case fourHours = 14400
    case forever = -1
    case until8AM = -2
}

/// Mute action selector matching the native `MuteAction`.
public enum ZolaMuteAction: Int, Sendable, Equatable, Codable {
    case mute = 1
    case unmute = 3
}

/// Represents a muted conversation entry (`MuteEntryInfo`).
public struct ZolaMuteEntry: Sendable, Equatable, Codable, Identifiable {
    public let id: String
    public var duration: Int
    public var startTime: Int64
    public var systemTime: Int64
    public var currentTime: Int64
    public var muteMode: Int
    public var title: String?

    public init(
        id: String,
        duration: Int = -1,
        startTime: Int64 = 0,
        systemTime: Int64 = 0,
        currentTime: Int64 = 0,
        muteMode: Int = 1,
        title: String? = nil
    ) {
        self.id = id
        self.duration = duration
        self.startTime = startTime
        self.systemTime = systemTime
        self.currentTime = currentTime
        self.muteMode = muteMode
        self.title = title
    }

    public static func fromServerDict(_ raw: [String: Any]) -> ZolaMuteEntry? {
        let id = ZolaJSON.string(raw["id"] ?? raw["threadId"] ?? raw["gid"] ?? raw["uid"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return nil }
        let duration = raw["duration"] != nil ? ZolaJSON.int(raw["duration"]) : -1
        let startTime = ZolaJSON.int64(raw["startTime"] ?? raw["start_time"])
        let systemTime = ZolaJSON.int64(raw["systemTime"] ?? raw["system_time"])
        let currentTime = ZolaJSON.int64(raw["currentTime"] ?? raw["current_time"])
        let muteMode = raw["muteMode"] != nil ? ZolaJSON.int(raw["muteMode"]) : 1
        let title = ZolaJSON.string(raw["title"] ?? raw["name"]).trimmingCharacters(in: .whitespacesAndNewlines)
        return ZolaMuteEntry(
            id: id,
            duration: duration,
            startTime: startTime,
            systemTime: systemTime,
            currentTime: currentTime,
            muteMode: muteMode,
            title: title.isEmpty ? nil : title
        )
    }

    public var isCurrentlyMuted: Bool {
        if duration == -1 { return true }
        if duration <= 0 { return duration == -2 }
        let nowSec = currentTime > 0 ? currentTime : Int64(Date().timeIntervalSince1970)
        if startTime > 0 {
            return (startTime + Int64(duration)) > nowSec
        }
        return true
    }
}

/// Response from `getMute()` (`GetMuteResponse`).
public struct ZolaMuteList: Sendable, Equatable, Codable {
    public var chatEntries: [ZolaMuteEntry]
    public var groupChatEntries: [ZolaMuteEntry]

    public init(chatEntries: [ZolaMuteEntry] = [], groupChatEntries: [ZolaMuteEntry] = []) {
        self.chatEntries = chatEntries
        self.groupChatEntries = groupChatEntries
    }

    public static func fromServerDict(_ data: [String: Any]) -> ZolaMuteList {
        let source = (data["mutes"] as? [String: Any]) ?? data
        let rawChats = (source["chatEntries"] as? [[String: Any]])
            ?? (source["chat"] as? [[String: Any]])
            ?? []
        let rawGroups = (source["groupChatEntries"] as? [[String: Any]])
            ?? (source["group"] as? [[String: Any]])
            ?? []
        return ZolaMuteList(
            chatEntries: rawChats.compactMap { ZolaMuteEntry.fromServerDict($0) }.filter(\.isCurrentlyMuted),
            groupChatEntries: rawGroups.compactMap { ZolaMuteEntry.fromServerDict($0) }.filter(\.isCurrentlyMuted)
        )
    }

    public var mutedUserIds: Set<Int64> {
        Set(chatEntries.compactMap { Int64($0.id) })
    }

    public var mutedGroupIds: Set<Int64> {
        Set(groupChatEntries.compactMap {
            let trimmed = $0.id.hasPrefix("g_") ? String($0.id.dropFirst(2)) : ($0.id.hasPrefix("g") ? String($0.id.dropFirst(1)) : $0.id)
            return Int64(trimmed)
        })
    }

    public func isMuted(threadId: Int64, isGroup: Bool, title: String? = nil) -> Bool {
        let tid = String(threadId)
        let entries = isGroup ? groupChatEntries : chatEntries
        if entries.contains(where: { $0.id == tid || $0.id == "g\(tid)" }) {
            return true
        }
        if let title, !title.isEmpty {
            let normTitle = ZolaLabel.normalizeTitle(title)
            if !normTitle.isEmpty {
                return entries.contains { entry in
                    guard let entryTitle = entry.title else { return false }
                    return ZolaLabel.normalizeTitle(entryTitle) == normTitle
                }
            }
        }
        return false
    }
}

/// Result returned by `ZolaClient.uploadAndSendVideo(...)` (`subCmd = 44`, `action = "chat.video.msg"`).
public struct ZolaVideoSendResult: Sendable, Equatable {
    public let videoUrl: String
    public let thumbUrl: String
    public let width: Int
    public let height: Int
    public let durationMs: Int
    public let fileSize: Int
    public let posterData: Data?
    public let receipt: ZolaSendReceipt

    public init(
        videoUrl: String,
        thumbUrl: String,
        width: Int,
        height: Int,
        durationMs: Int,
        fileSize: Int,
        posterData: Data? = nil,
        receipt: ZolaSendReceipt
    ) {
        self.videoUrl = videoUrl
        self.thumbUrl = thumbUrl
        self.width = width
        self.height = height
        self.durationMs = durationMs
        self.fileSize = fileSize
        self.posterData = posterData
        self.receipt = receipt
    }
}



