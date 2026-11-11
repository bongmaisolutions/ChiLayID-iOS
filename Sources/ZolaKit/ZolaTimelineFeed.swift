import Foundation

// Native timeline ("Nhật ký") feed, READ-ONLY. Decoded from Zalo iOS 261002:
// `+[IMRequestController getTimelineWithTab:page:record:lastFeedId:lastFeedIdBackup:maxFeedId:feedVersion:feedLoadType:complete:]`
// (0x101264854) appends, little endian, through `NSMutableData appendChar:/appendInteger:/appendLong:/appendShort:`:
//   UInt8 clientType, Int32 clientVersion, Int32 deviceType, UInt8 tab, Int32 page, Int32 record,
//   Int64 lastFeedId, Int64 lastFeedIdBackup, Int64 maxFeedId, Int64 feedVersion, Int16 feedLoadType
// then sends `IMRequest initWithMainCmd:1230 subCmd:6` on UXChatSocket 0x7d0 (sourceType 3, messageType 1).
// The completion receives the JSON response; items carry `item` (one post) or `items` (a grouped "shared N
// activities" holder), `ftype` 2 = one photo, 3 = album, 110 = sponsored (never shown here).
// Native timeline parser (0x1011cc000..0x1011ce3a0) maps data.`last_feed_id` -> resultLastFeedId,
// data.`ver` -> resultFeedVersion, data.`lmore` -> resultHasMore before resultParsedFeeds.
// Live reply keys: last_feed_id, list, lmore, promote_friend, settings, sug_*, type, update_sug, ver.

extension ZolaConstants {
    public static let cmdTimelineFeed: Int16 = 1230
    public static let subCmdTimelineFeed: Int8 = 6
}

public struct ZolaFeedPhoto: Codable, Equatable, Sendable, Identifiable {
    public let id: Int64
    public let thumbUrl: String
    public let url: String
    public let width: Int
    public let height: Int

    public init(id: Int64, thumbUrl: String, url: String, width: Int = 0, height: Int = 0) {
        self.id = id
        self.thumbUrl = thumbUrl
        self.url = url
        self.width = width
        self.height = height
    }
}

public struct ZolaFeedPost: Codable, Equatable, Sendable, Identifiable {
    public let id: Int64
    public let type: Int
    public let authorUid: Int64
    public let authorName: String
    public let authorAvatarUrl: String
    public let createdAtMs: Int64
    public let caption: String
    public let photos: [ZolaFeedPhoto]
    public let likeCount: Int
    public let commentCount: Int
    public let isLiked: Bool
    /// `holder_title` of a grouped entry (for example "Shared 2 activities"), empty for single posts.
    public let groupTitle: String
    public let hasVoice: Bool
    /// The newest comment Zalo sends inside the feed item (`item.comment`), shown under the post like Zalo does.
    public let latestComment: ZolaFeedComment?

    public init(id: Int64, type: Int, authorUid: Int64, authorName: String, authorAvatarUrl: String,
                createdAtMs: Int64, caption: String, photos: [ZolaFeedPhoto], likeCount: Int,
                commentCount: Int, isLiked: Bool, groupTitle: String = "", hasVoice: Bool = false,
                latestComment: ZolaFeedComment? = nil) {
        self.id = id
        self.type = type
        self.authorUid = authorUid
        self.authorName = authorName
        self.authorAvatarUrl = authorAvatarUrl
        self.createdAtMs = createdAtMs
        self.caption = caption
        self.photos = photos
        self.likeCount = likeCount
        self.commentCount = commentCount
        self.isLiked = isLiked
        self.groupTitle = groupTitle
        self.hasVoice = hasVoice
        self.latestComment = latestComment
    }

    /// True when the post has something this read-only viewer can render.
    public var hasRenderableContent: Bool { !caption.isEmpty || !photos.isEmpty }
}

/// Paging state for the next 1230 request. Matches the native fields Zalo sends on "load more"
/// (`FEED_LOAD_TYPE: 8`, page index +1, last/max feed ids of what is already shown).
public struct ZolaFeedCursor: Codable, Equatable, Sendable {
    public let page: Int32
    public let lastFeedId: Int64
    public let maxFeedId: Int64
    public let feedVersion: Int64

    public init(page: Int32, lastFeedId: Int64, maxFeedId: Int64, feedVersion: Int64) {
        self.page = page
        self.lastFeedId = lastFeedId
        self.maxFeedId = maxFeedId
        self.feedVersion = feedVersion
    }
}

public struct ZolaFeedPage: Sendable, Equatable {
    public let posts: [ZolaFeedPost]
    /// nil when the server returned no further posts.
    public let nextCursor: ZolaFeedCursor?

    public init(posts: [ZolaFeedPost], nextCursor: ZolaFeedCursor?) {
        self.posts = posts
        self.nextCursor = nextCursor
    }
}

public enum ZolaTimelineFeed {
    public static let pageSize: Int32 = 20
    public static let loadTypeFirst: Int16 = 3
    public static let loadTypeMore: Int16 = 8
    public static let sponsoredType = 110
    /// `UXSessionContext.deviceType` is the login response's `devicetype` (Zalo2 on a Mac reports 4).
    /// Sessions in Keychain never stored it, so an iOS phone value is used.
    public static let defaultDeviceType: Int32 = 2

    public static func requestBody(cursor: ZolaFeedCursor?, tab: UInt8 = 0, record: Int32 = pageSize,
                                   deviceType: Int32 = defaultDeviceType,
                                   clientVersion: Int32 = Int32(ZolaConstants.clientVersionIOS)) -> Data {
        var body = Data()
        body.appendUInt8(UInt8(ZolaConstants.clientTypeIOS))
        body.appendInt32LE(clientVersion)
        body.appendInt32LE(deviceType)
        body.appendUInt8(tab)
        body.appendInt32LE(cursor?.page ?? 0)
        body.appendInt32LE(record)
        let last = cursor?.lastFeedId ?? 0
        body.appendInt64LE(last)
        body.appendInt64LE(last) // lastFeedIdBackup: the live client repeats lastFeedId
        body.appendInt64LE(cursor?.maxFeedId ?? 0)
        body.appendInt64LE(cursor?.feedVersion ?? 0)
        body.appendInt16LE(cursor == nil ? loadTypeFirst : loadTypeMore)
        return body
    }

    public static func requestFrame(cursor: ZolaFeedCursor?, srcId: Int32, seqId: Int32,
                                    deviceType: Int32 = defaultDeviceType) throws -> ZolaChatElementFrame {
        guard srcId != 0 else { throw ZolaError.invalidArgument("Tài khoản không hợp lệ.") }
        if let cursor, cursor.page < 1 || cursor.lastFeedId <= 0 {
            throw ZolaError.invalidArgument("Vị trí tải thêm Nhật ký không hợp lệ.")
        }
        return ZolaCrypto.packChatElementFrame(bodyData: requestBody(cursor: cursor, deviceType: deviceType),
            srcId: srcId, srcType: 3, msgType: 1, cmd: ZolaConstants.cmdTimelineFeed,
            subCmd: ZolaConstants.subCmdTimelineFeed, seqId: seqId, needAck: 1)
    }

    // MARK: - Response

    /// `data` is the dictionary after the shared native response check (`parseChatSocketResponse`).
    /// Throws when no feed list can be found, so a malformed reply never looks like an empty timeline.
    public static func parse(_ data: [String: Any], previous: ZolaFeedCursor?) throws -> ZolaFeedPage {
        guard let entries = feedEntries(in: data) else {
            throw ZolaError.transport("Máy chủ chưa trả danh sách Nhật ký hợp lệ.")
        }
        var posts: [ZolaFeedPost] = []
        var allIds: [Int64] = []
        func take(_ item: [String: Any], groupTitle: String) {
            if let id = positiveId(item["fid"]) { allIds.append(id) }
            if let post = post(from: item, groupTitle: groupTitle) { posts.append(post) }
        }
        for entry in entries {
            if let item = entry["item"] as? [String: Any] {
                take(item, groupTitle: "")
            } else if let items = entry["items"] as? [[String: Any]] {
                let holderTitle = ZolaJSON.string(entry["holder_title"])
                items.forEach { take($0, groupTitle: holderTitle) }
            } else {
                take(entry, groupTitle: "")
            }
        }
        var seen = Set<Int64>()
        posts = posts.filter { seen.insert($0.id).inserted }

        let serverLastId = positiveId(data["last_feed_id"])
        let hasMoreFlag: Bool? = data["lmore"].map { ZolaJSON.int($0) != 0 }
        let nextCursor: ZolaFeedCursor?
        if hasMoreFlag != false, let lastId = serverLastId ?? allIds.last, lastId != previous?.lastFeedId {
            let maxId = max(previous?.maxFeedId ?? 0, allIds.max() ?? 0)
            nextCursor = ZolaFeedCursor(page: (previous?.page ?? 0) + 1, lastFeedId: lastId, maxFeedId: maxId,
                                        feedVersion: feedVersion(in: data) ?? previous?.feedVersion ?? 0)
        } else {
            nextCursor = nil
        }
        return ZolaFeedPage(posts: posts, nextCursor: nextCursor)
    }

    /// Key names only (never values) of the response, for diagnostics.
    public static func shapeDescription(_ data: [String: Any]) -> String {
        let entries = feedEntries(in: data) ?? []
        let grouped = entries.filter { $0["items"] != nil }.count
        let lmore = data["lmore"].map { String(ZolaJSON.int($0)) } ?? "-"
        return "keys=\(data.keys.sorted().joined(separator: ",")) list=\(listKeyPath(in: data) ?? "?") n=\(entries.count) gop=\(grouped) lmore=\(lmore)"
    }

    static func post(from item: [String: Any], groupTitle: String) -> ZolaFeedPost? {
        let type = ZolaJSON.int(item["ftype"], default: -1)
        guard type != sponsoredType, item["track_ads"] == nil, let id = positiveId(item["fid"]),
              let header = item["header"] as? [String: Any], let author = positiveId(header["uid"]) else { return nil }
        let content = item["content"] as? [String: Any] ?? [:]
        let footer = item["footer"] as? [String: Any] ?? [:]
        var photos: [ZolaFeedPhoto] = []
        if let list = content["photos"] as? [[String: Any]] {
            photos = list.compactMap { photo(from: $0, dimension: nil) }
        } else if let single = content["photo"] as? [String: Any],
                  let one = photo(from: single, dimension: content["photo_dimension"] as? [String: Any]) {
            photos = [one]
        }
        return ZolaFeedPost(
            id: id, type: type, authorUid: author,
            authorName: ZolaJSON.string(header["dpn"]),
            authorAvatarUrl: ZolaJSON.string(header["avt"]),
            createdAtMs: ZolaJSON.int64(item["cts"]),
            caption: ZolaJSON.string(content["caption"]).trimmingCharacters(in: .whitespacesAndNewlines),
            photos: photos,
            likeCount: max(0, ZolaJSON.int(footer["numlike"])),
            commentCount: max(0, ZolaJSON.int(footer["numcmt"])),
            isLiked: ZolaJSON.int(item["islike"]) == 1,
            groupTitle: groupTitle,
            hasVoice: !ZolaJSON.string(content["voice_url"]).isEmpty,
            latestComment: ZolaFeedComments.comment(from: item["comment"] as? [String: Any])
        )
    }

    static func photo(from raw: [String: Any], dimension: [String: Any]?) -> ZolaFeedPhoto? {
        let thumb = ZolaJSON.string(raw["thumb"])
        let origin = ZolaJSON.string(raw["origin"])
        guard !thumb.isEmpty || !origin.isEmpty else { return nil }
        return ZolaFeedPhoto(id: ZolaJSON.int64(raw["photoid"]), thumbUrl: thumb.isEmpty ? origin : thumb,
                             url: origin.isEmpty ? thumb : origin,
                             width: ZolaJSON.int(dimension?["width"]), height: ZolaJSON.int(dimension?["height"]))
    }

    private static func positiveId(_ raw: Any?) -> Int64? {
        let value = ZolaJSON.int64(raw)
        return value > 0 ? value : nil
    }

    private static func isFeedEntry(_ raw: Any) -> Bool {
        guard let dict = raw as? [String: Any] else { return false }
        return dict["item"] is [String: Any] || dict["items"] is [[String: Any]] || dict["fid"] != nil
    }

    /// The list is found by shape (entries carrying `item`/`items`/`fid`), at most three levels deep,
    /// because the response wrapper key was not observable without sending traffic. An empty list is
    /// only accepted under a list-like key, so an unrelated reply never reads as "no posts".
    static func feedEntries(in data: [String: Any]) -> [[String: Any]]? {
        let listKeys: Set<String> = ["feeds", "items", "feed", "data", "list"]
        // Live 1230 replies (2026-11-05) carry the posts in `list`, next to sug_* suggestion blocks.
        for key in ["list", "feeds"] {
            if let feeds = data[key] as? [Any], feeds.isEmpty || feeds.contains(where: isFeedEntry) {
                return feeds.compactMap { $0 as? [String: Any] }
            }
        }
        func search(_ dict: [String: Any], depth: Int) -> [[String: Any]]? {
            var empty: [[String: Any]]?
            for key in dict.keys.sorted() {
                let value = dict[key]
                if let list = value as? [Any] {
                    if list.contains(where: isFeedEntry) { return list.compactMap { $0 as? [String: Any] } }
                    if list.isEmpty, listKeys.contains(key), empty == nil { empty = [] }
                } else if depth < 2, let nested = value as? [String: Any],
                          let found = search(nested, depth: depth + 1) {
                    if !found.isEmpty { return found }
                    if empty == nil { empty = found }
                }
            }
            return empty
        }
        return search(data, depth: 0)
    }

    private static func listKeyPath(in data: [String: Any]) -> String? {
        func search(_ dict: [String: Any], path: String, depth: Int) -> String? {
            for key in dict.keys.sorted() {
                let here = path.isEmpty ? key : "\(path).\(key)"
                if let list = dict[key] as? [Any], list.contains(where: isFeedEntry) { return here }
                if depth < 2, let nested = dict[key] as? [String: Any],
                   let found = search(nested, path: here, depth: depth + 1) { return found }
            }
            return nil
        }
        return search(data, path: "", depth: 0)
    }

    private static func feedVersion(in data: [String: Any]) -> Int64? {
        for key in ["ver", "feedVersion", "feed_version", "version"] {
            let value = ZolaJSON.int64(data[key])
            if value > 0 { return value }
        }
        return nil
    }
}

extension ZolaClient {
    nonisolated(unsafe) private static var feedShapeNotes = 0

    /// Reads one page of the account's timeline ("Nhật ký"). Returns nil on dry-run (no socket opened).
    /// Read-only: never likes, comments, posts or changes privacy.
    public func fetchTimelineFeed(cursor: ZolaFeedCursor? = nil,
                                  deviceType: Int32 = ZolaTimelineFeed.defaultDeviceType,
                                  dryRun: Bool = true) async throws -> ZolaFeedPage? {
        try assertSessionAlive()
        let srcId = Int32(truncatingIfNeeded: session.uid)
        _ = try ZolaTimelineFeed.requestFrame(cursor: cursor, srcId: srcId, seqId: 1, deviceType: deviceType)
        guard !dryRun else { return nil }
        #if canImport(Network)
        return try await withAuthenticatedChatSocket { socket in
            let seq = await socket.nextSeqId()
            let frame = try ZolaTimelineFeed.requestFrame(cursor: cursor, srcId: srcId, seqId: seq, deviceType: deviceType)
            let response = try await socket.sendAndWait(rawPayload: frame.payload, expectedCmd: ZolaConstants.cmdTimelineFeed,
                timeoutSeconds: 10, ackSeqId: seq, ackCmds: [ZolaConstants.cmdTimelineFeed], requiresResponseBody: true)
            let parsed = try parseChatSocketResponse(response) // includes the 102/-96 session breaker
            if let handler = Self.diagnosticHandler, Self.feedShapeNotes < 3 {
                Self.feedShapeNotes += 1
                handler("nhat-ky code=\(parsed.code) \(ZolaTimelineFeed.shapeDescription(parsed.data))")
            }
            guard parsed.code == 0 else {
                throw ZolaError.server(code: parsed.code,
                                       message: parsed.message.isEmpty ? "Máy chủ Zalo chưa trả Nhật ký." : parsed.message)
            }
            return try ZolaTimelineFeed.parse(parsed.data, previous: cursor)
        }
        #else
        throw ZolaError.transport("Nền tảng không hỗ trợ Nhật ký native.")
        #endif
    }
}
