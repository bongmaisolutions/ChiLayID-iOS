import Foundation

// Native `ChatTagRepository` commands on `UXChatSocket` (`0x7d0`), decoded from Zalo iOS `261002`.
// Conversation ids are `"<uid>"` for 1-1 chats and `"g<gid>"` for groups.

extension ZolaConstants {
    public static let cmdChatTagList: Int16 = 2140
    public static let cmdChatTagUpdateConversation: Int16 = 2141
    public static let cmdChatTagCreate: Int16 = 2170
    public static let cmdChatTagUpdate: Int16 = 2171
    public static let cmdChatTagDelete: Int16 = 2172
}

extension ZolaCrypto {
    private static func chatTagBody(
        platformType: UInt8 = 2,
        clientVersion: Int32 = Int32(ZolaConstants.clientVersionIOS)
    ) -> Data {
        var body = Data()
        body.appendUInt8(platformType)
        body.appendInt32LE(clientVersion)
        // Fixed trailer of `ZWorkBaseRequest` as emitted by the real 261002802 client.
        body.append(contentsOf: [0x00, 0x00, 0x00, 0x00, 0x01, 0x00])
        return body
    }

    private static func chatTagFrame(cmd: Int16, body: Data, srcId: Int32, seqId: Int32) -> ZolaChatElementFrame {
        packChatElementFrame(
            bodyData: body,
            srcId: srcId,
            srcType: 3,
            msgType: 1,
            cmd: cmd,
            subCmd: 0,
            seqId: seqId,
            needAck: 1
        )
    }

    /// `GetListChatTagRequest` (`0x10146c260`): `version`, then the ids already loaded for paging.
    public static func packChatTagListFrame(
        version: Int32,
        loadedTagIds: [Int32],
        srcId: Int32,
        seqId: Int32
    ) -> ZolaChatElementFrame {
        var body = chatTagBody()
        body.appendInt32LE(version)
        body.appendInt32LE(Int32(loadedTagIds.count))
        loadedTagIds.forEach { body.appendInt32LE($0) }
        return chatTagFrame(cmd: ZolaConstants.cmdChatTagList, body: body, srcId: srcId, seqId: seqId)
    }

    /// `UpdateListChatTagRequest` (`0x10146cb1c`): tags added to and removed from one conversation.
    public static func packChatTagUpdateConversationFrame(
        threadId: Int32,
        messageType: UInt8,
        addTagIds: [Int32],
        removeTagIds: [Int32],
        srcId: Int32,
        seqId: Int32
    ) -> ZolaChatElementFrame {
        var body = chatTagBody()
        body.appendInt32LE(threadId)
        body.appendUInt8(messageType)
        body.appendInt32LE(Int32(addTagIds.count))
        addTagIds.forEach { body.appendInt32LE($0) }
        body.appendInt32LE(Int32(removeTagIds.count))
        removeTagIds.forEach { body.appendInt32LE($0) }
        return chatTagFrame(cmd: ZolaConstants.cmdChatTagUpdateConversation, body: body, srcId: srcId, seqId: seqId)
    }

    /// `AddNewTagRequest` (`0x10146b86c`): `I(1)` then a length-prefixed `{"color","text"}` JSON.
    public static func packChatTagCreateFrame(
        text: String,
        color: String,
        srcId: Int32,
        seqId: Int32
    ) throws -> ZolaChatElementFrame {
        let json = try JSONSerialization.data(withJSONObject: ["color": color, "text": text], options: [.sortedKeys])
        var body = chatTagBody()
        body.appendInt32LE(1)
        body.appendInt32LE(Int32(json.count))
        body.append(json)
        return chatTagFrame(cmd: ZolaConstants.cmdChatTagCreate, body: body, srcId: srcId, seqId: seqId)
    }

    /// `UpdateTagRequest` (`0x10146d36c`): the full tag JSON including its member conversations.
    public static func packChatTagUpdateFrame(
        tag: ZolaLabel,
        srcId: Int32,
        seqId: Int32
    ) throws -> ZolaChatElementFrame {
        let payload: [String: Any] = [
            "id": tag.id,
            "text": tag.text,
            "color": tag.color,
            "offset": tag.offset,
            "emoji": tag.emoji,
            "createTime": tag.createTime,
            "conversations": tag.conversations,
        ]
        let json = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        var body = chatTagBody()
        body.appendInt32LE(Int32(truncatingIfNeeded: tag.id))
        body.appendInt32LE(Int32(json.count))
        body.append(json)
        return chatTagFrame(cmd: ZolaConstants.cmdChatTagUpdate, body: body, srcId: srcId, seqId: seqId)
    }

    /// `DeleteTagRequest` (`0x10146bdd8`).
    public static func packChatTagDeleteFrame(tagIds: [Int32], srcId: Int32, seqId: Int32) -> ZolaChatElementFrame {
        var body = chatTagBody()
        body.appendInt32LE(Int32(tagIds.count))
        tagIds.forEach { body.appendInt32LE($0) }
        return chatTagFrame(cmd: ZolaConstants.cmdChatTagDelete, body: body, srcId: srcId, seqId: seqId)
    }
}

/// Server answer to `cmd = 2141`: the tags now on the conversation and the ids refused for being over the limit.
public struct ZolaChatTagUpdateResult: Sendable, Equatable {
    public var tagIds: [Int]
    public var excessiveIds: [Int]

    public init(tagIds: [Int] = [], excessiveIds: [Int] = []) {
        self.tagIds = tagIds
        self.excessiveIds = excessiveIds
    }
}

#if canImport(Network)
extension ZolaClient {
    private static let chatTagNotFoundCode = 1001

    private func sendChatTagCommand(
        _ cmd: Int16,
        allowedCodes: Set<Int> = [],
        _ frame: @escaping (_ srcId: Int32, _ seqId: Int32) throws -> ZolaChatElementFrame
    ) async throws -> (code: Int, data: [String: Any], message: String) {
        let srcId = Int32(truncatingIfNeeded: session.uid)
        return try await withAuthenticatedChatSocket { sock in
            let seq = await sock.nextSeqId()
            let built = try frame(srcId, seq)
            let resp = try await sock.sendAndWait(rawPayload: built.payload, expectedCmd: cmd, timeoutSeconds: 6.0)
            return try self.parseChatSocketResponse(resp, allowedCodes: allowedCodes)
        }
    }

    private static func int32Ids(_ ids: [Int]) throws -> [Int32] {
        try ids.map { id in
            guard let value = Int32(exactly: id), value > 0 else {
                throw ZolaError.invalidArgument("Mã thẻ không hợp lệ: \(id)")
            }
            return value
        }
    }

    /// Reads every tag of this nick. A nick that never created a tag answers `1001`.
    public func fetchChatTags() async throws -> ZolaLabelsResponse {
        var loaded: [ZolaLabel] = []
        var version = 0
        for _ in 0..<20 {
            let loadedIds = loaded.map { Int32(truncatingIfNeeded: $0.id) }
            let parsed = try await sendChatTagCommand(
                ZolaConstants.cmdChatTagList,
                allowedCodes: [Self.chatTagNotFoundCode]
            ) { srcId, seqId in
                ZolaCrypto.packChatTagListFrame(version: 0, loadedTagIds: loadedIds, srcId: srcId, seqId: seqId)
            }
            if parsed.code == Self.chatTagNotFoundCode { break }
            version = ZolaJSON.int(parsed.data["version"])
            let items = (parsed.data["items"] as? [[String: Any]] ?? []).compactMap { ZolaLabel.fromServerDict($0) }
            loaded += items.filter { item in !loaded.contains(where: { $0.id == item.id }) }
            let hasMore = (parsed.data["hasMore"] as? Bool) ?? (ZolaJSON.int(parsed.data["hasMore"]) != 0)
            if !hasMore || items.isEmpty { break }
        }
        return ZolaLabelsResponse(labelData: loaded, version: version)
    }

    /// Adds and removes tags on one conversation (`cmd = 2141`).
    @discardableResult
    public func updateConversationTags(
        threadId: Int64,
        isGroup: Bool,
        addTagIds: [Int],
        removeTagIds: [Int],
        dryRun: Bool = true
    ) async throws -> ZolaChatTagUpdateResult {
        try assertSessionAlive()
        guard let wireThreadId = UInt32(exactly: threadId), wireThreadId > 0 else {
            throw ZolaError.invalidArgument("Hội thoại \(threadId) không gắn thẻ được trên Zalo")
        }
        let adds = try Self.int32Ids(addTagIds)
        let removes = try Self.int32Ids(removeTagIds)
        if dryRun { return ZolaChatTagUpdateResult(tagIds: addTagIds) }
        let parsed = try await sendChatTagCommand(ZolaConstants.cmdChatTagUpdateConversation) { srcId, seqId in
            ZolaCrypto.packChatTagUpdateConversationFrame(
                threadId: Int32(bitPattern: wireThreadId),
                messageType: isGroup ? 1 : 0,
                addTagIds: adds,
                removeTagIds: removes,
                srcId: srcId,
                seqId: seqId
            )
        }
        let ints: (String) -> [Int] = { key in (parsed.data[key] as? [Any] ?? []).map { ZolaJSON.int($0) } }
        return ZolaChatTagUpdateResult(tagIds: ints("tagIds"), excessiveIds: ints("excessiveIds"))
    }

    /// Creates a tag (`cmd = 2170`) and returns it with the id assigned by Zalo.
    public func createChatTag(text: String, color: String, dryRun: Bool = true) async throws -> ZolaLabel {
        try assertSessionAlive()
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw ZolaError.invalidArgument("Tên thẻ không được để trống") }
        if dryRun { return ZolaLabel(id: 0, text: clean, color: color) }
        let parsed = try await sendChatTagCommand(ZolaConstants.cmdChatTagCreate) { srcId, seqId in
            try ZolaCrypto.packChatTagCreateFrame(text: clean, color: color, srcId: srcId, seqId: seqId)
        }
        let dict = (parsed.data["items"] as? [[String: Any]])?.first ?? parsed.data
        guard let created = ZolaLabel.fromServerDict(dict), created.id > 0 else {
            throw ZolaError.transport("Zalo không trả về thẻ vừa tạo")
        }
        return created
    }

    /// Renames or recolors a tag (`cmd = 2171`). `tag.conversations` must carry the current members.
    public func updateChatTag(_ tag: ZolaLabel, dryRun: Bool = true) async throws {
        try assertSessionAlive()
        guard tag.id > 0 else { throw ZolaError.invalidArgument("Mã thẻ không hợp lệ: \(tag.id)") }
        if dryRun { return }
        _ = try await sendChatTagCommand(ZolaConstants.cmdChatTagUpdate) { srcId, seqId in
            try ZolaCrypto.packChatTagUpdateFrame(tag: tag, srcId: srcId, seqId: seqId)
        }
    }

    /// Deletes tags (`cmd = 2172`).
    public func deleteChatTags(ids: [Int], dryRun: Bool = true) async throws {
        try assertSessionAlive()
        let wireIds = try Self.int32Ids(ids)
        if dryRun { return }
        _ = try await sendChatTagCommand(ZolaConstants.cmdChatTagDelete) { srcId, seqId in
            ZolaCrypto.packChatTagDeleteFrame(tagIds: wireIds, srcId: srcId, seqId: seqId)
        }
    }
}
#endif
