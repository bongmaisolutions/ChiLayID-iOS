import Foundation
import Security

/// Secure Apple Keychain storage for `ZolaSession` on iOS & macOS (`ThisDeviceOnly`).
/// On Mac Catalyst (`targetEnvironment(macCatalyst)`), where unprovisioned local builds return
/// `errSecMissingEntitlement` (`-34018`) from Data Protection Keychain and CDHash changes across
/// rebuilds would trigger modal `SecurityAgent` prompts, sessions are persisted atomically as
/// POSIX `0600` owner-only files under `Application Support/ZolaKit/KeychainVault/`.
public struct ZolaKeychainSessionStore: Sendable {
    public let service: String

    public init(service: String = "com.zolakit.session") {
        self.service = service
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    #if targetEnvironment(macCatalyst) || os(macOS)
    private static func safeVaultComponent(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let cleaned = String(raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        return cleaned.isEmpty ? "default" : cleaned
    }

    internal func macVaultFileURL(account: String) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("ZolaKit", isDirectory: true)
            .appendingPathComponent("KeychainVault", isDirectory: true)
            .appendingPathComponent(Self.safeVaultComponent(service), isDirectory: true)
            .appendingPathComponent("\(Self.safeVaultComponent(account)).json")
    }
    #endif

    private static func decodeAndSanitizeSession(_ data: Data) throws -> ZolaSession {
        var session = try JSONDecoder().decode(ZolaSession.self, from: data)
        session.friendHost = ZolaSession.normalizeFriendHost(session.friendHost)
        if let hosts = session.serviceHosts {
            var clean: [String: String] = [:]
            for (k, v) in hosts where !ZolaClient.isForbiddenWebWpaURL(v) {
                clean[k] = (k == "friend") ? ZolaSession.normalizeFriendHost(v) : v
            }
            session.serviceHosts = clean.isEmpty ? nil : clean
        }
        return session
    }

    public func save(_ session: ZolaSession, account: String? = nil) throws {
        let acct = account ?? String(session.uid)
        let data = try JSONEncoder().encode(session)
        #if targetEnvironment(macCatalyst)
        try ZolaFileSessionStore.writeData0600(data, to: macVaultFileURL(account: acct))
        #else
        let query = baseQuery(account: acct)
        let attrs: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        var finalStatus = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if finalStatus == errSecItemNotFound {
            var addQuery = query
            for (k, v) in attrs { addQuery[k] = v }
            finalStatus = SecItemAdd(addQuery as CFDictionary, nil)
        }
        if finalStatus != errSecSuccess {
            #if os(macOS)
            if finalStatus == errSecMissingEntitlement
                || finalStatus == errSecInteractionNotAllowed
                || finalStatus == errSecAuthFailed
                || finalStatus == errSecNoSuchKeychain
            {
                try ZolaFileSessionStore.writeData0600(data, to: macVaultFileURL(account: acct))
                return
            }
            #endif
            throw ZolaError.keychain(finalStatus)
        }
        #endif
    }

    public func load(account: String) throws -> ZolaSession? {
        #if targetEnvironment(macCatalyst)
        let vaultURL = macVaultFileURL(account: account)
        if FileManager.default.fileExists(atPath: vaultURL.path) {
            let data = try Data(contentsOf: vaultURL)
            return try Self.decodeAndSanitizeSession(data)
        }
        #endif

        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data {
            return try Self.decodeAndSanitizeSession(data)
        }
        #if os(macOS)
        let vaultURL = macVaultFileURL(account: account)
        if FileManager.default.fileExists(atPath: vaultURL.path) {
            let data = try Data(contentsOf: vaultURL)
            return try Self.decodeAndSanitizeSession(data)
        }
        #endif
        if status == errSecItemNotFound { return nil }
        #if targetEnvironment(macCatalyst) || os(macOS)
        if status == errSecMissingEntitlement
            || status == errSecInteractionNotAllowed
            || status == errSecAuthFailed
            || status == errSecNoSuchKeychain
        {
            return nil
        }
        #endif
        throw ZolaError.keychain(status)
    }

    public func delete(account: String) throws {
        #if targetEnvironment(macCatalyst) || os(macOS)
        let vaultURL = macVaultFileURL(account: account)
        if FileManager.default.fileExists(atPath: vaultURL.path) {
            try? FileManager.default.removeItem(at: vaultURL)
        }
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        if status != errSecSuccess
            && status != errSecItemNotFound
            && status != errSecMissingEntitlement
            && status != errSecInteractionNotAllowed
            && status != errSecAuthFailed
            && status != errSecNoSuchKeychain
        {
            throw ZolaError.keychain(status)
        }
        #else
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw ZolaError.keychain(status)
        }
        #endif
    }
}

/// POSIX `0600` JSON file reader/writer compatible with Python's `session-<uid>.local.json` and external session exporters (`{"ok": true, "sessions": [...]}`).
public enum ZolaFileSessionStore {
    public static func loadInteropJSON(from url: URL) throws -> ZolaSession {
        let data = try Data(contentsOf: url)
        guard let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ZolaError.invalidArgument("Session file is not a JSON object")
        }
        return try loadInteropObject(raw)
    }

    public static func loadInteropObject(_ raw: [String: Any]) throws -> ZolaSession {
        let uid = ZolaJSON.int64(raw["uid"])
        let sk = ZolaJSON.string(raw["session_key"]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard uid > 0, !sk.isEmpty else {
            throw ZolaError.invalidArgument("Session JSON missing uid or session_key")
        }
        let ckB64 = ZolaJSON.string(raw["crypt_key_b64"] ?? raw["cryptKeyB64"])
        let ck = Data(base64Encoded: ckB64) ?? Data()
        let nativeZcid = ZolaJSON.string(raw["login_identifier"] ?? raw["native_zcid"])
        let zcid = nativeZcid.isEmpty ? ZolaJSON.string(raw["zcid"]) : nativeZcid
        let isNative = !nativeZcid.isEmpty || ((raw["zcid_is_native"] as? Bool) == true)

        var gids: [Int64] = []
        if let arr = (raw["group_ids"] ?? raw["joined_group_ids"]) as? [Any] {
            gids = arr.map { ZolaJSON.int64($0) }.filter { $0 > 0 }.sorted()
        }

        var sbTokens: [String: ZolaSessionBoxToken] = [:]
        if let sb = raw["session_box_tokens"] as? [String: [String: Any]] {
            for (dom, meta) in sb {
                let name = ZolaJSON.string(meta["name"])
                let val = ZolaJSON.string(meta["value"])
                if !name.isEmpty && !val.isEmpty {
                    sbTokens[dom] = ZolaSessionBoxToken(
                        name: name,
                        value: val,
                        domain: dom,
                        expiresAtMs: ZolaJSON.int64(meta["expires_at_ms"])
                    )
                }
            }
        }

        let loginInfo = raw["loginInfo"] as? [String: Any] ?? raw["login_info"] as? [String: Any]
        let hosts = ZolaSession.serviceHosts(
            fromServiceMap: raw["service_hosts"] ?? raw["zpw_service_map_v3"] ?? raw["service_map"]
                ?? loginInfo?["zpw_service_map_v3"] ?? loginInfo?["zpw_service_map_new"]
        )

        let keySetDict = raw["keySet"] as? [String: Any] ?? raw["key_set"] as? [String: Any] ?? loginInfo?["keySet"] as? [String: Any]
        var servers: [ZolaSocketServer] = []
        if let arr = (raw["socket_servers"] ?? raw["socketServers"] ?? loginInfo?["socketServers"]) as? [Any] {
            for item in arr {
                guard let dict = item as? [String: Any] else { continue }
                let srv = ZolaSocketServer.fromServerDict(dict)
                if !srv.hostName.isEmpty { servers.append(srv) }
            }
        }

        let rawKeySetId = ZolaJSON.string(raw["key_set_id"] ?? raw["keySetId"] ?? keySetDict?["keySetId"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let rawAccessToken = ZolaJSON.string(raw["access_token"] ?? raw["accessToken"] ?? loginInfo?["token"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let rawLoginPhone = ZolaJSON.string(raw["login_phone"] ?? raw["loginPhone"] ?? raw["phone_num"] ?? loginInfo?["phone_num"])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return try ZolaSession(
            uid: uid,
            sessionKey: sk,
            cryptKey: ck,
            zcid: zcid,
            zcidIsNative: isNative,
            friendHost: ZolaSession.normalizeFriendHost(ZolaJSON.string(raw["friend_host"] ?? raw["friendHost"])),
            sendToMeId: ZolaJSON.int64(raw["send_to_me_id"] ?? raw["sendToMeId"], default: ZolaConstants.defaultSendToMeId),
            groupIds: gids,
            sessionBoxTokens: sbTokens,
            serviceHosts: hosts.isEmpty ? nil : hosts,
            socketServers: servers.isEmpty ? nil : servers,
            keySetId: (!rawKeySetId.isEmpty && rawKeySetId != "0") ? rawKeySetId : nil,
            keySetValue: ZolaJSON.string(raw["key_set_value"] ?? raw["keySetValue"] ?? keySetDict?["keySetValue"]),
            aesPublicId: ZolaJSON.int64(raw["aes_public_id"] ?? raw["aesPublicId"] ?? keySetDict?["aesPublicId"]),
            aesPrivateId: ZolaJSON.int64(raw["aes_private_id"] ?? raw["aesPrivateId"] ?? keySetDict?["aesPrivateId"]),
            accessToken: rawAccessToken.isEmpty ? nil : rawAccessToken,
            loginPhone: rawLoginPhone.isEmpty ? nil : rawLoginPhone
        )
    }

    /// Parses an exporter JSON payload (`{"ok": true, "sessions": [...]}`) or a single session object.
    public static func loadInteropSessionsFromBridgeData(_ data: Data) throws -> [ZolaSession] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ZolaError.invalidArgument("Phản hồi từ session bridge không phải đối tượng JSON")
        }
        if let arr = root["sessions"] as? [[String: Any]] {
            var sessions: [ZolaSession] = []
            for item in arr {
                if let s = try? loadInteropObject(item) {
                    sessions.append(s)
                }
            }
            return sessions
        }
        if root["uid"] != nil && root["session_key"] != nil {
            return [try loadInteropObject(root)]
        }
        return []
    }

    public static func writeData0600(_ data: Data, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: Int16(0o600))], ofItemAtPath: url.path)
    }

    public static func saveWatermark(_ state: ZolaWatermarkState, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try writeData0600(try encoder.encode(state), to: url)
    }

    public static func loadWatermark(from url: URL) throws -> ZolaWatermarkState {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return ZolaWatermarkState()
        }
        return try JSONDecoder().decode(ZolaWatermarkState.self, from: Data(contentsOf: url))
    }
}
