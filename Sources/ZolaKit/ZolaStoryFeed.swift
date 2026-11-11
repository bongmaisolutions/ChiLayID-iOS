import Foundation

// Stories ("Khoảnh khắc"), READ-ONLY. Decoded from Zalo iOS 261002 (UXChatSocket 0x7d0, sourceType 3, messageType 1):
//   - Story bar (users that have stories): cmd 1340 subCmd 2
//     `+[IMRequestController loadUsersHaveStoryWithPage:clientVersion:lastUserID:source:completionBlock:]` 0x10132a158
//     body = Int32 page, Int32 record(50), Int64 lastUserId, Int32 deviceType, Int32 storyVersion, Int16 source, UInt8 1
//     (27 bytes, matches a live capture byte for byte).
//   - Stories of one user: cmd 1341 subCmd 0
//     `+[SingleRequestManager getStoriesOfUser:page:nRecord:lastStoryId:...]` 0x1011dddd0 through
//     `+[UXSocketStreamManager createPackageRequest:withSourceId:withCommandType:]` (subCmd 0)
//     body = Int32 userId, Int32 page, Int32 nRecord, Int32 deviceType, Int64 lastStoryId (24 bytes).
// Native parsers read `version`, `lastUserId`, `lmore`, `listStory` (bar) and `lastStoryId`, `lmore`, `story`,
// `listStory`, `list` (user stories). Live bar reply (2026-11-06, one text story): entry keys
// `uid, dpName, avt, seen, time, utype, isIntro, listStory`; story keys `id, type, status, typo_info, typoid, url,
// urlHls, thumb, width, height, delayTime, createTime, ownerInfo{userId, displayName, avatar}, privacy, seen, viewCount`.
// Photo/video key spellings are still unconfirmed, so the item parser keeps accepting the binary's other spellings.
// Never sends a "seen"/view count (`increaseStoryView` is a separate write and is not implemented).

extension ZolaConstants {
    public static let cmdStoryUsers: Int16 = 1340
    public static let subCmdStoryUsers: Int8 = 2
    public static let cmdUserStories: Int16 = 1341
}

/// Colors and alignment of a text story (`type` 3, `typo_info`). Colors are signed 32-bit ARGB as Zalo sends them.
public struct ZolaStoryTextStyle: Codable, Equatable, Sendable {
    public let backgroundArgb: Int64
    public let textArgb: Int64
    /// 0 leading, 1 center, 2 trailing (Zalo `align`).
    public let alignment: Int

    public init(backgroundArgb: Int64, textArgb: Int64, alignment: Int = 1) {
        self.backgroundArgb = backgroundArgb
        self.textArgb = textArgb
        self.alignment = alignment
    }
}

public struct ZolaStoryItem: Codable, Equatable, Sendable, Identifiable {
    public let id: Int64
    public let ownerUid: Int64
    public let isVideo: Bool
    public let mediaUrl: String
    public let thumbUrl: String
    /// Caption of a photo/video story, or the whole text of a text story.
    public let caption: String
    public let createdAtMs: Int64
    public let expiresAtMs: Int64
    public let durationMs: Int
    /// Set for text stories (no media): render `caption` on this background.
    public let textStyle: ZolaStoryTextStyle?

    public var isText: Bool { textStyle != nil }

    public init(id: Int64, ownerUid: Int64, isVideo: Bool, mediaUrl: String, thumbUrl: String, caption: String = "",
                createdAtMs: Int64 = 0, expiresAtMs: Int64 = 0, durationMs: Int = 0, textStyle: ZolaStoryTextStyle? = nil) {
        self.id = id
        self.ownerUid = ownerUid
        self.isVideo = isVideo
        self.mediaUrl = mediaUrl
        self.thumbUrl = thumbUrl
        self.caption = caption
        self.createdAtMs = createdAtMs
        self.expiresAtMs = expiresAtMs
        self.durationMs = durationMs
        self.textStyle = textStyle
    }
}

public struct ZolaStoryUser: Codable, Equatable, Sendable, Identifiable {
    public var id: Int64 { uid }
    public let uid: Int64
    public let name: String
    public let avatarUrl: String
    public let hasUnseen: Bool
    /// Stories already carried by the bar reply (may be empty: then fetch with `fetchUserStories`).
    public let stories: [ZolaStoryItem]

    public init(uid: Int64, name: String, avatarUrl: String, hasUnseen: Bool, stories: [ZolaStoryItem]) {
        self.uid = uid
        self.name = name
        self.avatarUrl = avatarUrl
        self.hasUnseen = hasUnseen
        self.stories = stories
    }
}

public struct ZolaStoryBarPage: Sendable, Equatable {
    public let users: [ZolaStoryUser]
    public let lastUserId: Int64
    public let hasMore: Bool
    public let version: Int64
}

public enum ZolaStoryFeed {
    public static let barPageSize: Int32 = 50
    public static let userPageSize: Int32 = 20

    public static func storyUsersBody(page: Int32 = 0, lastUserId: Int64 = 0, version: Int32 = 0,
                                      source: Int16 = 0, deviceType: Int32 = ZolaTimelineFeed.defaultDeviceType) -> Data {
        var body = Data()
        body.appendInt32LE(page)
        body.appendInt32LE(barPageSize)
        body.appendInt64LE(lastUserId)
        body.appendInt32LE(deviceType)
        body.appendInt32LE(version)
        body.appendInt16LE(source)
        body.appendUInt8(1)
        return body
    }

    public static func storyUsersFrame(page: Int32 = 0, lastUserId: Int64 = 0, srcId: Int32, seqId: Int32,
                                       deviceType: Int32 = ZolaTimelineFeed.defaultDeviceType) throws -> ZolaChatElementFrame {
        guard srcId != 0, page >= 0, lastUserId >= 0 else { throw ZolaError.invalidArgument("Yêu cầu Story không hợp lệ.") }
        return ZolaCrypto.packChatElementFrame(bodyData: storyUsersBody(page: page, lastUserId: lastUserId, deviceType: deviceType),
            srcId: srcId, srcType: 3, msgType: 1, cmd: ZolaConstants.cmdStoryUsers,
            subCmd: ZolaConstants.subCmdStoryUsers, seqId: seqId, needAck: 1)
    }

    public static func userStoriesBody(userId: Int64, page: Int32 = 0, lastStoryId: Int64 = 0,
                                       deviceType: Int32 = ZolaTimelineFeed.defaultDeviceType) throws -> Data {
        guard userId > 0, userId <= Int64(UInt32.max) else { throw ZolaError.invalidArgument("Mã người dùng Story không hợp lệ.") }
        var body = Data()
        body.appendUInt32LE(UInt32(userId))
        body.appendInt32LE(page)
        body.appendInt32LE(userPageSize)
        body.appendInt32LE(deviceType)
        body.appendInt64LE(lastStoryId)
        return body
    }

    public static func userStoriesFrame(userId: Int64, page: Int32 = 0, lastStoryId: Int64 = 0, srcId: Int32, seqId: Int32,
                                        deviceType: Int32 = ZolaTimelineFeed.defaultDeviceType) throws -> ZolaChatElementFrame {
        guard srcId != 0 else { throw ZolaError.invalidArgument("Tài khoản không hợp lệ.") }
        return ZolaCrypto.packChatElementFrame(bodyData: try userStoriesBody(userId: userId, page: page, lastStoryId: lastStoryId, deviceType: deviceType),
            srcId: srcId, srcType: 3, msgType: 1, cmd: ZolaConstants.cmdUserStories, subCmd: 0, seqId: seqId, needAck: 1)
    }

    // MARK: - Response

    private static func firstValue(_ dict: [String: Any], _ keys: [String]) -> Any? {
        for key in keys { if let value = dict[key], !(value is NSNull) { return value } }
        return nil
    }

    private static func string(_ dict: [String: Any], _ keys: [String]) -> String {
        for key in keys {
            let value = ZolaJSON.string(dict[key]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { return value }
        }
        return ""
    }

    private static func int64(_ dict: [String: Any], _ keys: [String]) -> Int64 {
        for key in keys { let value = ZolaJSON.int64(dict[key]); if value != 0 { return value } }
        return 0
    }

    /// Accepts JSON-in-string values (Zalo sometimes nests `metadata`/`content` as a JSON string).
    private static func object(_ raw: Any?) -> [String: Any]? {
        if let dict = raw as? [String: Any] { return dict }
        if let text = raw as? String, let data = text.data(using: .utf8) {
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }
        return nil
    }

    private static func list(_ raw: Any?) -> [[String: Any]] {
        if let items = raw as? [[String: Any]] { return items }
        if let items = raw as? [Any] { return items.compactMap { object($0) } }
        if let text = raw as? String, let data = text.data(using: .utf8),
           let items = (try? JSONSerialization.jsonObject(with: data)) as? [Any] {
            return items.compactMap { object($0) }
        }
        return []
    }

    static let storyListKeys = ["listStory", "stories", "story", "list", "items"]

    public static func storyItem(from raw: [String: Any], ownerUid: Int64 = 0) -> ZolaStoryItem? {
        // Media may sit on the item or in a nested `content`/`media`/`metadata` object.
        var dict = raw
        for nestedKey in ["content", "media", "metadata", "data"] {
            if let nested = object(raw[nestedKey]) { dict.merge(nested) { current, _ in current } }
        }
        let id = int64(dict, ["storyId", "storyid", "story_id", "id"])
        let video = string(dict, ["video_url", "videoUrl", "video", "url_video"])
        let photo = string(dict, ["photo_url", "photoUrl", "image_original", "origin", "image", "photo", "url", "media_url", "mediaUrl"])
        let media = video.isEmpty ? photo : video
        let thumb = string(dict, ["thumb_url", "thumbUrl", "thumb", "image"])
        let typeValue = ZolaJSON.int(firstValue(dict, ["mediaType", "media_type", "storyType", "type"]), default: -1)
        // Text story (live reply, 2026-11-06): type 3, text in `status` (a string), colors in `typo_info`, no url/thumb.
        let typo = object(dict["typo_info"]) ?? object(dict["typoInfo"])
        let isText = media.isEmpty && thumb.isEmpty && (typeValue == 3 || typo != nil)
        guard id > 0, isText || !(media.isEmpty && thumb.isEmpty) else { return nil }
        let owner = int64(dict, ["ownerId", "owner_id", "uid", "userId", "senderId"])
        let lowerMedia = media.lowercased()
        let textStyle = isText ? ZolaStoryTextStyle(
            backgroundArgb: ZolaJSON.int64(typo?["bg_color"] ?? typo?["bgColor"], default: -16_777_216), // opaque black
            textArgb: ZolaJSON.int64(typo?["text_color"] ?? typo?["textColor"], default: -1), // opaque white
            alignment: ZolaJSON.int(typo?["align"], default: 1)) : nil
        let caption = isText ? ((dict["status"] as? String) ?? string(dict, ["text", "caption", "desc"]))
                             : string(dict, ["caption", "text", "desc"])
        return ZolaStoryItem(
            id: id, ownerUid: owner != 0 ? owner : ownerUid,
            isVideo: !isText && (!video.isEmpty || typeValue == 2 || lowerMedia.contains(".mp4") || lowerMedia.contains(".m3u8")),
            mediaUrl: media.isEmpty ? thumb : media,
            thumbUrl: thumb.isEmpty ? media : thumb,
            caption: caption.trimmingCharacters(in: .whitespacesAndNewlines),
            createdAtMs: int64(dict, ["create_time", "createTime", "cts", "ts", "time"]),
            expiresAtMs: int64(dict, ["expire_time", "expireTime", "expired"]),
            // `delayTime` is how long Zalo shows a photo/text story (5000 ms in the live reply).
            durationMs: ZolaJSON.int(firstValue(dict, ["duration", "durationMs", "delayTime"])),
            textStyle: textStyle
        )
    }

    public static func parseStoryUsers(_ data: [String: Any]) throws -> ZolaStoryBarPage {
        guard let rawList = firstValue(data, ["listStory", "list", "users", "items"]) else {
            if data["lmore"] != nil || data["lastUserId"] != nil || data["version"] != nil {
                return ZolaStoryBarPage(users: [], lastUserId: 0, hasMore: false, version: ZolaJSON.int64(data["version"]))
            }
            throw ZolaError.transport("Máy chủ chưa trả danh sách Story hợp lệ.")
        }
        var users: [ZolaStoryUser] = []
        for raw in list(rawList) {
            var entry = raw
            if let nested = object(raw["user"]) ?? object(raw["Sender"]) ?? object(raw["sender"]) ?? object(raw["owner"]) {
                entry.merge(nested) { current, _ in current }
            }
            let uid = int64(entry, ["uid", "userId", "ownerId", "owner_id", "id"])
            guard uid > 0 else { continue }
            var stories: [ZolaStoryItem] = []
            var rawStories: [[String: Any]] = []
            for key in storyListKeys {
                let items = list(raw[key])
                if !items.isEmpty { rawStories = items; stories = items.compactMap { storyItem(from: $0, ownerUid: uid) }; break }
            }
            // Live bar entries use `dpName`/`avt`; each story also carries `ownerInfo{displayName, avatar}`.
            let owner = rawStories.lazy.compactMap { object($0["ownerInfo"]) }.first ?? [:]
            let name = string(entry, ["dpn", "dpName", "displayName", "name", "zaloName"])
            let avatar = string(entry, ["avt", "avatar", "avatarUrl"])
            let seenFlag = firstValue(entry, ["is_seen", "isSeen", "seen", "viewed"])
            users.append(ZolaStoryUser(
                uid: uid,
                name: name.isEmpty ? string(owner, ["displayName", "dpName", "name"]) : name,
                avatarUrl: avatar.isEmpty ? string(owner, ["avatar", "avt"]) : avatar,
                hasUnseen: seenFlag.map { ZolaJSON.int($0) == 0 } ?? true,
                stories: stories))
        }
        var seen = Set<Int64>()
        users = users.filter { seen.insert($0.uid).inserted }
        return ZolaStoryBarPage(users: users,
                                lastUserId: ZolaJSON.int64(data["lastUserId"]),
                                hasMore: ZolaJSON.int(data["lmore"]) != 0,
                                version: ZolaJSON.int64(data["version"]))
    }

    public static func parseUserStories(_ data: [String: Any], ownerUid: Int64) throws -> [ZolaStoryItem] {
        guard let rawList = firstValue(data, ["listStory", "story", "list", "stories", "items"]) else {
            if data["lmore"] != nil || data["lastStoryId"] != nil { return [] }
            throw ZolaError.transport("Máy chủ chưa trả Story hợp lệ.")
        }
        var seen = Set<Int64>()
        return list(rawList).compactMap { storyItem(from: $0, ownerUid: ownerUid) }.filter { seen.insert($0.id).inserted }
    }

    /// Key names only (never values): top-level keys, first list entry keys and first nested story keys.
    public static func shapeDescription(_ data: [String: Any]) -> String {
        var parts = ["keys=\(data.keys.sorted().joined(separator: ","))"]
        for key in ["listStory", "list", "story", "stories", "users", "items"] {
            let items = list(data[key])
            guard let first = items.first else { continue }
            parts.append("\(key)[\(items.count)]=\(first.keys.sorted().joined(separator: ","))")
            for inner in storyListKeys {
                let nested = list(first[inner])
                if let item = nested.first {
                    parts.append("\(key).\(inner)[\(nested.count)]=\(item.keys.sorted().joined(separator: ","))")
                    break
                }
            }
            break
        }
        return parts.joined(separator: " ")
    }

    /// Top-level values for diagnosing an empty story bar: numbers and bools as-is, id-like numbers only as
    /// set/0, strings only by length, arrays by count, objects by key names. Never user content.
    public static func scalarSummary(_ data: [String: Any]) -> String {
        data.keys.sorted().compactMap { key -> String? in
            let lower = key.lowercased()
            switch data[key] {
            case let number as NSNumber:
                if lower.hasSuffix("id") || lower.hasSuffix("ids") { return "\(key)=\(number.int64Value == 0 ? "0" : "set")" }
                return "\(key)=\(number)"
            case let text as String:
                return "\(key)=s\(text.count)"
            case let array as [Any]:
                return "\(key)[\(array.count)]"
            case let object as [String: Any]:
                return "\(key){\(object.keys.sorted().prefix(8).joined(separator: ","))}"
            default:
                return nil
            }
        }.joined(separator: " ")
    }

    /// `scalarSummary` of the first story item in a reply (bar or user list), plus its nested media objects.
    /// Same redaction as `scalarSummary`: no text, no ids.
    public static func firstItemSummary(_ data: [String: Any]) -> String {
        guard let rawList = firstValue(data, ["listStory", "story", "list", "stories", "items"]),
              var item = list(rawList).first else { return "" }
        for key in storyListKeys {
            if let nested = list(item[key]).first { item = nested; break }
        }
        var parts = [scalarSummary(item)]
        for nestedKey in ["content", "media", "metadata", "data"] {
            if let nested = object(item[nestedKey]) { parts.append("\(nestedKey):(\(scalarSummary(nested)))") }
        }
        return parts.joined(separator: " ")
    }
}

extension ZolaClient {
    nonisolated(unsafe) private static var storyShapeNotes = 0

    private func noteStoryShape(_ label: String, code: Int, data: [String: Any]) {
        guard let handler = Self.diagnosticHandler, Self.storyShapeNotes < 6 else { return }
        Self.storyShapeNotes += 1
        handler("story \(label) code=\(code) \(ZolaStoryFeed.shapeDescription(data))")
        if label == "bar" { handler("story bar gia-tri \(ZolaStoryFeed.scalarSummary(data))") }
        let first = ZolaStoryFeed.firstItemSummary(data)
        if !first.isEmpty { handler("story \(label) muc-dau \(first)") }
    }

    /// Story bar: friends that currently have stories. READ-ONLY; nil on dry-run.
    public func fetchStoryUsers(page: Int32 = 0, lastUserId: Int64 = 0, dryRun: Bool = true) async throws -> ZolaStoryBarPage? {
        try assertSessionAlive()
        let srcId = Int32(truncatingIfNeeded: session.uid)
        _ = try ZolaStoryFeed.storyUsersFrame(page: page, lastUserId: lastUserId, srcId: srcId, seqId: 1)
        guard !dryRun else { return nil }
        #if canImport(Network)
        return try await withAuthenticatedChatSocket { socket in
            let seq = await socket.nextSeqId()
            let frame = try ZolaStoryFeed.storyUsersFrame(page: page, lastUserId: lastUserId, srcId: srcId, seqId: seq)
            let response = try await socket.sendAndWait(rawPayload: frame.payload, expectedCmd: ZolaConstants.cmdStoryUsers,
                timeoutSeconds: 10, ackSeqId: seq, ackCmds: [ZolaConstants.cmdStoryUsers], requiresResponseBody: true)
            let parsed = try parseChatSocketResponse(response)
            noteStoryShape("bar", code: parsed.code, data: parsed.data)
            guard parsed.code == 0 else {
                throw ZolaError.server(code: parsed.code, message: parsed.message.isEmpty ? "Máy chủ Zalo chưa trả Story." : parsed.message)
            }
            return try ZolaStoryFeed.parseStoryUsers(parsed.data)
        }
        #else
        throw ZolaError.transport("Nền tảng không hỗ trợ Story native.")
        #endif
    }

    /// Stories of one user. READ-ONLY (does not send a view count); nil on dry-run.
    public func fetchUserStories(userId: Int64, lastStoryId: Int64 = 0, dryRun: Bool = true) async throws -> [ZolaStoryItem]? {
        try assertSessionAlive()
        let srcId = Int32(truncatingIfNeeded: session.uid)
        _ = try ZolaStoryFeed.userStoriesFrame(userId: userId, lastStoryId: lastStoryId, srcId: srcId, seqId: 1)
        guard !dryRun else { return nil }
        #if canImport(Network)
        return try await withAuthenticatedChatSocket { socket in
            let seq = await socket.nextSeqId()
            let frame = try ZolaStoryFeed.userStoriesFrame(userId: userId, lastStoryId: lastStoryId, srcId: srcId, seqId: seq)
            let response = try await socket.sendAndWait(rawPayload: frame.payload, expectedCmd: ZolaConstants.cmdUserStories,
                timeoutSeconds: 10, ackSeqId: seq, ackCmds: [ZolaConstants.cmdUserStories], requiresResponseBody: true)
            let parsed = try parseChatSocketResponse(response)
            noteStoryShape("user", code: parsed.code, data: parsed.data)
            guard parsed.code == 0 else {
                throw ZolaError.server(code: parsed.code, message: parsed.message.isEmpty ? "Máy chủ Zalo chưa trả Story." : parsed.message)
            }
            return try ZolaStoryFeed.parseUserStories(parsed.data, ownerUid: userId)
        }
        #else
        throw ZolaError.transport("Nền tảng không hỗ trợ Story native.")
        #endif
    }
}
