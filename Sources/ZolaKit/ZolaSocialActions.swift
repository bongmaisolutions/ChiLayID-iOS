import Foundation

// Timeline ("Nhật ký") write actions, decoded byte-for-byte from live Zalo iOS 261002 socket sends
// (UXChatSocket 0x7d0, sourceType 3, messageType 1):
//   - LIKE/REACTION  cmd 189 subCmd 5  (`SingleRequestManager requestLikeUnlike:...` 0x1011da208)
//   - COMMENT        cmd 188 subCmd 5  (`SingleRequestManager postCommentOnFeed:...` 0x1011df928)
// Both bodies share the header: Int16 0, UInt8 clientType(2), Int32 clientVersion, Int16 0, Int64 feedId.
// `ZolaSocialActionsTests` pins each body against the real captured bytes.

extension ZolaConstants {
    public static let cmdFeedReaction: Int16 = 189
    public static let cmdFeedComment: Int16 = 188
    public static let subCmdFeedWrite: Int8 = 5
    /// `SocialCommonSource` value for the Timeline/Nhật ký context used by the live client.
    public static let feedSourceTimeline = 101
    /// Heart is reaction id 1 (`new_reaction_id` in the live like payload).
    public static let feedReactionHeart: Int = 1
}

public enum ZolaSocialActions {
    private static func header(feedId: Int64) throws -> Data {
        guard feedId > 0 else { throw ZolaError.invalidArgument("Mã bài viết không hợp lệ.") }
        var body = Data()
        body.appendInt16LE(0)
        body.appendUInt8(UInt8(ZolaConstants.clientTypeIOS))
        body.appendInt32LE(Int32(ZolaConstants.clientVersionIOS))
        body.appendInt16LE(0)
        body.appendInt64LE(feedId)
        return body
    }

    /// `new_reaction_id`: 1 = heart (like), 0 = remove reaction. `current_reaction_id`: the reaction
    /// already set (0 when none). Toggling off a heart is newReactionId 0, currentReactionId 1.
    public static func reactionBody(feedId: Int64, newReactionId: Int, currentReactionId: Int,
                                    source: Int = ZolaConstants.feedSourceTimeline) throws -> Data {
        guard newReactionId >= 0, currentReactionId >= 0 else {
            throw ZolaError.invalidArgument("Mã cảm xúc không hợp lệ.")
        }
        var body = try header(feedId: feedId)
        body.appendInt16LE(Int16(source))
        let json = "{\"new_reaction_id\":\(newReactionId),\"current_reaction_id\":\(currentReactionId),\"enable_reactions\":true,\"react_context\":0}"
        let jsonData = Data(json.utf8)
        body.appendInt32LE(Int32(jsonData.count))
        body.append(jsonData)
        body.appendInt16LE(0)
        body.appendInt32LE(1)
        body.appendInt64LE(0)
        return body
    }

    public static func reactionFrame(feedId: Int64, newReactionId: Int, currentReactionId: Int,
                                     srcId: Int32, seqId: Int32) throws -> ZolaChatElementFrame {
        let body = try reactionBody(feedId: feedId, newReactionId: newReactionId, currentReactionId: currentReactionId)
        return ZolaCrypto.packChatElementFrame(bodyData: body, srcId: srcId, srcType: 3, msgType: 1,
            cmd: ZolaConstants.cmdFeedReaction, subCmd: ZolaConstants.subCmdFeedWrite, seqId: seqId, needAck: 1)
    }

    public static func commentBody(feedId: Int64, text: String, timestampMs: Int64,
                                   source: Int = ZolaConstants.feedSourceTimeline) throws -> Data {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ZolaError.invalidArgument("Nội dung bình luận trống.") }
        let textData = Data(text.utf8)
        guard textData.count <= 8000 else { throw ZolaError.invalidArgument("Bình luận quá dài.") }
        var body = try header(feedId: feedId)
        body.appendInt32LE(Int32(source - 1)) // live client sent 100 for the Timeline comment context
        body.appendInt32LE(Int32(textData.count))
        body.append(textData)
        body.appendInt64LE(0) // replyToUserId
        body.appendInt64LE(0) // replyToCommentId
        body.appendInt64LE(0) // stickerId / feedMemoryId
        body.appendInt64LE(timestampMs)
        body.appendInt32LE(Int32(source))
        body.append(Data(count: 18)) // trailer: empty photoUrl + photo dims, as the live client sent
        return body
    }

    public static func commentFrame(feedId: Int64, text: String, timestampMs: Int64,
                                    srcId: Int32, seqId: Int32) throws -> ZolaChatElementFrame {
        let body = try commentBody(feedId: feedId, text: text, timestampMs: timestampMs)
        return ZolaCrypto.packChatElementFrame(bodyData: body, srcId: srcId, srcType: 3, msgType: 1,
            cmd: ZolaConstants.cmdFeedComment, subCmd: ZolaConstants.subCmdFeedWrite, seqId: seqId, needAck: 1)
    }
}

extension ZolaClient {
    /// Likes a timeline post (heart) or removes the like. READ-SAFE default `dryRun` sends nothing.
    /// A write to Zalo, so only call with `dryRun: false` from a real user tap.
    @discardableResult
    public func reactToFeed(feedId: Int64, like: Bool, previousReactionId: Int = 0,
                            dryRun: Bool = true) async throws -> Bool {
        try assertSessionAlive()
        let srcId = Int32(truncatingIfNeeded: session.uid)
        let newId = like ? ZolaConstants.feedReactionHeart : 0
        let curId = like ? previousReactionId : (previousReactionId == 0 ? ZolaConstants.feedReactionHeart : previousReactionId)
        _ = try ZolaSocialActions.reactionFrame(feedId: feedId, newReactionId: newId, currentReactionId: curId, srcId: srcId, seqId: 1)
        guard !dryRun else { return false }
        #if canImport(Network)
        return try await withAuthenticatedChatSocket { socket in
            let seq = await socket.nextSeqId()
            let frame = try ZolaSocialActions.reactionFrame(feedId: feedId, newReactionId: newId, currentReactionId: curId, srcId: srcId, seqId: seq)
            let response = try await socket.sendAndWait(rawPayload: frame.payload, expectedCmd: ZolaConstants.cmdFeedReaction,
                timeoutSeconds: 8, ackSeqId: seq, ackCmds: [ZolaConstants.cmdFeedReaction], requiresResponseBody: true)
            let parsed = try parseChatSocketResponse(response) // includes the 102/-96 session breaker
            guard parsed.code == 0 else {
                throw ZolaError.server(code: parsed.code, message: parsed.message.isEmpty ? "Zalo chưa nhận cảm xúc." : parsed.message)
            }
            return true
        }
        #else
        throw ZolaError.transport("Nền tảng không hỗ trợ thả tim native.")
        #endif
    }

    /// Posts a comment on a timeline post. READ-SAFE default `dryRun`. A write to Zalo; call with
    /// `dryRun: false` only from a real user tap.
    @discardableResult
    public func commentOnFeed(feedId: Int64, text: String, dryRun: Bool = true) async throws -> Bool {
        try assertSessionAlive()
        let srcId = Int32(truncatingIfNeeded: session.uid)
        let ts = Int64(Date().timeIntervalSince1970 * 1000)
        _ = try ZolaSocialActions.commentFrame(feedId: feedId, text: text, timestampMs: ts, srcId: srcId, seqId: 1)
        guard !dryRun else { return false }
        #if canImport(Network)
        return try await withAuthenticatedChatSocket { socket in
            let seq = await socket.nextSeqId()
            let frame = try ZolaSocialActions.commentFrame(feedId: feedId, text: text, timestampMs: ts, srcId: srcId, seqId: seq)
            let response = try await socket.sendAndWait(rawPayload: frame.payload, expectedCmd: ZolaConstants.cmdFeedComment,
                timeoutSeconds: 8, ackSeqId: seq, ackCmds: [ZolaConstants.cmdFeedComment], requiresResponseBody: true)
            let parsed = try parseChatSocketResponse(response)
            guard parsed.code == 0 else {
                throw ZolaError.server(code: parsed.code, message: parsed.message.isEmpty ? "Zalo chưa nhận bình luận." : parsed.message)
            }
            return true
        }
        #else
        throw ZolaError.transport("Nền tảng không hỗ trợ bình luận native.")
        #endif
    }
}
