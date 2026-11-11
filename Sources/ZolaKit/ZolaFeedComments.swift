import Foundation

// Timeline ("Nhật ký") comment list, READ-ONLY, decoded from Zalo iOS 261002 (UXChatSocket 0x7d0, sourceType 3,
// messageType 1):
//   - COMMENT LIST cmd 191 subCmd 4 (`+[SingleRequestManager getFeedCommentListByFeedId:lastComment:feedMemoryId:
//     sourceType:success:failure:]` 0x1011d9694). Body (48 bytes, matched byte for byte against a live Zalo 2 capture
//     opened from the Timeline): Int16 0, UInt8 clientType(2), Int32 clientVersion, Int16 0, UInt8 deviceType,
//     Int64 feedId, Int64 lastCommentId (0 = newest page), Int32 10, Int32 100, Int16 sourceType (0 on the Timeline),
//     Int32 0, Int64 feedMemoryId (0).
// Reply (live): {tot, last_cid, list, rmv, rtot, enable_recent_like}. Entries are read by
// `+[SocialDataParser parseCommentDictionary:atIndex:numTotal:]` 0x1011d3688 with short keys:
//   cid (comment id), fid, oid (author uid), tim (time), con (text), avt, sck, fdn (display name), fun (username),
//   tvb (time label), prt, tdn (name of the person replied to).
// Each feed item also carries its latest comment as `item.comment`:
//   {comment_id, uid, dpn, avt, comment, cts, mapEffect}.

extension ZolaConstants {
    public static let cmdFeedCommentList: Int16 = 191
    public static let subCmdFeedCommentList: Int8 = 4
}

public struct ZolaFeedComment: Codable, Equatable, Sendable, Identifiable {
    public let id: Int64
    public let authorUid: Int64
    public let authorName: String
    public let authorAvatarUrl: String
    /// Plain text of the comment; empty for comment kinds this client cannot show (sticker, photo).
    public let text: String
    public let createdAtMs: Int64
    /// Name of the person this comment replies to (`tdn`), empty for a top-level comment.
    public let replyToName: String

    public init(id: Int64, authorUid: Int64, authorName: String, authorAvatarUrl: String, text: String, createdAtMs: Int64,
                replyToName: String = "") {
        self.id = id
        self.authorUid = authorUid
        self.authorName = authorName
        self.authorAvatarUrl = authorAvatarUrl
        self.text = text
        self.createdAtMs = createdAtMs
        self.replyToName = replyToName
    }
}

public struct ZolaFeedCommentPage: Equatable, Sendable {
    /// Oldest first, as the Zalo comment screen shows them.
    public let comments: [ZolaFeedComment]
    /// `tot`: all comments of the post (0 when the reply does not say).
    public let total: Int
    /// `last_cid`: pass back as `lastCommentId` for the next (older) page; 0 when there is none.
    public let nextCursor: Int64
    public let hasMore: Bool

    public init(comments: [ZolaFeedComment], total: Int = 0, nextCursor: Int64 = 0, hasMore: Bool) {
        self.comments = comments
        self.total = total
        self.nextCursor = nextCursor
        self.hasMore = hasMore
    }
}

public enum ZolaFeedComments {
    public static func listBody(feedId: Int64, lastCommentId: Int64 = 0, sourceType: Int16 = 0,
                                deviceType: Int32 = ZolaTimelineFeed.defaultDeviceType) throws -> Data {
        guard feedId > 0 else { throw ZolaError.invalidArgument("Mã bài viết không hợp lệ.") }
        guard lastCommentId >= 0 else { throw ZolaError.invalidArgument("Mã bình luận không hợp lệ.") }
        var body = Data()
        body.appendInt16LE(0)
        body.appendUInt8(UInt8(ZolaConstants.clientTypeIOS))
        body.appendInt32LE(Int32(ZolaConstants.clientVersionIOS))
        body.appendInt16LE(0)
        body.appendUInt8(UInt8(truncatingIfNeeded: deviceType))
        body.appendInt64LE(feedId)
        body.appendInt64LE(lastCommentId)
        body.appendInt32LE(10)
        body.appendInt32LE(100)
        body.appendInt16LE(sourceType)
        body.appendInt32LE(0)
        body.appendInt64LE(0)                     // feedMemoryId: not a memory post
        return body
    }

    public static func listFrame(feedId: Int64, lastCommentId: Int64 = 0, srcId: Int32, seqId: Int32) throws -> ZolaChatElementFrame {
        guard srcId != 0 else { throw ZolaError.invalidArgument("Tài khoản không hợp lệ.") }
        return ZolaCrypto.packChatElementFrame(
            bodyData: try listBody(feedId: feedId, lastCommentId: lastCommentId),
            srcId: srcId, srcType: 3, msgType: 1, cmd: ZolaConstants.cmdFeedCommentList,
            subCmd: ZolaConstants.subCmdFeedCommentList, seqId: seqId, needAck: 1)
    }

    /// One comment from `item.comment` or a comment list entry; nil without a usable id.
    public static func comment(from raw: [String: Any]?) -> ZolaFeedComment? {
        guard let raw else { return nil }
        let id = firstInt64(raw, ["cid", "comment_id", "commentId", "cmtid", "cmt_id", "id"])
        guard id > 0 else { return nil }
        let owner = raw["owner"] as? [String: Any] ?? raw["user"] as? [String: Any] ?? [:]
        // `tim` is a "yyyy-MM-dd HH:mm:ss" local-time string (`+[NSDate za_dateWithString:]` 0x100e132b0);
        // `item.comment` uses a millisecond `cts`.
        let time = firstInt64(raw, ["cts", "createTime", "create_time", "ts", "time"]).nonZero
            ?? dateStringMs(raw["tim"]) ?? firstInt64(raw, ["tim"])
        return ZolaFeedComment(
            id: id,
            authorUid: firstInt64(raw, ["oid", "uid", "userId", "user_id", "ownerId"]).nonZero ?? firstInt64(owner, ["uid", "userId", "id"]),
            authorName: firstString(raw, ["fdn", "dpn", "displayName", "display_name", "name", "fun"]).nonEmpty
                ?? firstString(owner, ["dpn", "displayName", "name"]),
            authorAvatarUrl: firstString(raw, ["avt", "avatar", "avatarUrl"]).nonEmpty ?? firstString(owner, ["avt", "avatar"]),
            text: firstString(raw, ["con", "comment", "content", "text", "msg"]).trimmingCharacters(in: .whitespacesAndNewlines),
            // Seconds and milliseconds both occur in Zalo replies; anything below year 5138 in seconds is seconds.
            createdAtMs: time > 0 && time < 100_000_000_000 ? time * 1000 : time,
            replyToName: firstString(raw, ["tdn"]))
    }

    /// Finds the comment array wherever the reply keeps it and returns it oldest first, without duplicates.
    public static func parseList(_ data: [String: Any]) -> ZolaFeedCommentPage {
        let entries = commentArray(in: data, depth: 0) ?? []
        var seen = Set<Int64>()
        let comments = entries.compactMap { comment(from: $0) }
            .filter { seen.insert($0.id).inserted }
            .sorted { ($0.createdAtMs, $0.id) < ($1.createdAtMs, $1.id) }
        let total = ZolaJSON.int(data["tot"])
        let cursor = ZolaJSON.int64(data["last_cid"])
        let more: Bool
        if let flag = ["lmore", "has_more", "hasMore", "more", "isMore"].lazy.compactMap({ data[$0] }).first {
            more = ZolaJSON.int(flag) == 1
        } else {
            // Live replies carry no flag: older comments exist while the total exceeds this page and a cursor is given.
            more = cursor > 0 && total > comments.count
        }
        return ZolaFeedCommentPage(comments: comments, total: total, nextCursor: cursor, hasMore: more)
    }

    /// Key names and counts only (no ids, names or text), for the first live replies.
    public static func shapeDescription(_ data: [String: Any]) -> String {
        var parts = ["keys=" + data.keys.sorted().joined(separator: ",")]
        if let entries = commentArray(in: data, depth: 0) {
            parts.append("list[\(entries.count)]=" + (entries.first?.keys.sorted().joined(separator: ",") ?? ""))
        } else {
            parts.append("list=none")
        }
        return parts.joined(separator: " ")
    }

    private static let preferredListKeys = ["comments", "listComment", "list_comment", "cmts", "data", "list", "items", "comment"]

    /// A list entry only counts as a comment with a comment-specific id key, or an `id` next to comment text,
    /// so photo or like arrays that merely carry `id` are not mistaken for comments.
    private static func isCommentEntry(_ entry: [String: Any]) -> Bool {
        if ["cid", "comment_id", "commentId", "cmtid", "cmt_id"].contains(where: { entry[$0] != nil }) { return true }
        return entry["id"] != nil && (entry["comment"] is String || entry["content"] is String || entry["con"] is String)
    }

    private static func commentArray(in value: Any, depth: Int) -> [[String: Any]]? {
        guard depth < 5 else { return nil }
        if let entries = value as? [[String: Any]], entries.contains(where: isCommentEntry) {
            return entries.filter(isCommentEntry)
        }
        if let dict = value as? [String: Any] {
            let keys = preferredListKeys.filter { dict[$0] != nil } + dict.keys.sorted().filter { !preferredListKeys.contains($0) }
            for key in keys {
                guard let child = dict[key] else { continue }
                if let found = commentArray(in: decodedJSON(child), depth: depth + 1) { return found }
            }
        } else if let list = value as? [Any] {
            for child in list {
                if let found = commentArray(in: decodedJSON(child), depth: depth + 1) { return found }
            }
        }
        return nil
    }

    /// Some Zalo replies nest JSON as a string; decode it so the search can go inside.
    private static func decodedJSON(_ value: Any) -> Any {
        guard let text = value as? String else { return value }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{") || trimmed.hasPrefix("["), let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else { return value }
        return object
    }

    private static let commentDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone.current     // the native formatter keeps the device time zone too
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    /// Milliseconds for a "yyyy-MM-dd HH:mm:ss" string, nil for anything else.
    static func dateStringMs(_ raw: Any?) -> Int64? {
        guard let text = raw as? String, text.count == 19, let date = commentDateFormatter.date(from: text) else { return nil }
        return Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    private static func firstInt64(_ dict: [String: Any], _ keys: [String]) -> Int64 {
        for key in keys {
            let value = ZolaJSON.int64(dict[key])
            if value > 0 { return value }
        }
        return 0
    }

    private static func firstString(_ dict: [String: Any], _ keys: [String]) -> String {
        for key in keys {
            let value = ZolaJSON.string(dict[key])
            if !value.isEmpty { return value }
        }
        return ""
    }
}

private extension Int64 {
    var nonZero: Int64? { self == 0 ? nil : self }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

extension ZolaClient {
    nonisolated(unsafe) private static var commentListShapeNotes = 0

    /// Comments of one timeline post, oldest first. READ-ONLY; nil on dry-run.
    /// `lastCommentId` 0 asks for the newest page.
    public func fetchFeedComments(feedId: Int64, lastCommentId: Int64 = 0, dryRun: Bool = true) async throws -> ZolaFeedCommentPage? {
        try assertSessionAlive()
        let srcId = Int32(truncatingIfNeeded: session.uid)
        _ = try ZolaFeedComments.listFrame(feedId: feedId, lastCommentId: lastCommentId, srcId: srcId, seqId: 1)
        guard !dryRun else { return nil }
        #if canImport(Network)
        return try await withAuthenticatedChatSocket { socket in
            let seq = await socket.nextSeqId()
            let frame = try ZolaFeedComments.listFrame(feedId: feedId, lastCommentId: lastCommentId, srcId: srcId, seqId: seq)
            let response = try await socket.sendAndWait(rawPayload: frame.payload, expectedCmd: ZolaConstants.cmdFeedCommentList,
                timeoutSeconds: 10, ackSeqId: seq, ackCmds: [ZolaConstants.cmdFeedCommentList], requiresResponseBody: true)
            let parsed = try parseChatSocketResponse(response) // includes the 102/-96 session breaker
            if let handler = Self.diagnosticHandler, Self.commentListShapeNotes < 3 {
                Self.commentListShapeNotes += 1
                handler("binh-luan code=\(parsed.code) \(ZolaFeedComments.shapeDescription(parsed.data))")
            }
            guard parsed.code == 0 else {
                throw ZolaError.server(code: parsed.code, message: parsed.message.isEmpty ? "Zalo chưa trả bình luận." : parsed.message)
            }
            return ZolaFeedComments.parseList(parsed.data)
        }
        #else
        throw ZolaError.transport("Nền tảng không hỗ trợ đọc bình luận native.")
        #endif
    }
}
