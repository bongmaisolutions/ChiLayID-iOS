import Foundation
import CoreFoundation

/// Native 261002 board entry. Board ID is NOT the global message ID.
public struct ZolaPinnedMessage: Codable, Equatable, Sendable, Identifiable {
    public let id: Int64
    public let messageId: Int64
    public let cliMsgId: Int64
    public let title: String
    public let senderUid: Int64
    public let isPinned: Bool
}

public struct ZolaPinBoard: Codable, Equatable, Sendable {
    public let threadId: Int64
    public let isGroup: Bool
    public let version: Int64
    public let maximumItems: Int
    public let messages: [ZolaPinnedMessage]
}

/// Proven from ZAGet{Group,Friend}PinBoardRequest / ZACreateFriendTopicRequest /
/// ZAUnpinFriendTopicRequest in IPA261002. Golden request bytes were obtained by
/// calling getRequestData on synthetic objects, without sending traffic.
public enum ZolaNativePinBoard {
    private static func base(threadId: Int64) throws -> Data {
        guard threadId > 0, threadId <= Int64(UInt32.max) else {
            throw ZolaError.invalidArgument("Mã hội thoại ghim không hợp lệ.")
        }
        var body = Data([2])
        body.appendInt32LE(Int32(ZolaConstants.clientVersionIOS))
        body.appendInt32LE(0) // tracking longString, empty
        body.appendInt16LE(1) // language from the real native request constructor
        body.appendUInt32LE(UInt32(threadId))
        return body
    }

    private static func frame(_ body: Data, command: Int16, subCommand: Int8 = 0, srcId: Int32, seqId: Int32) -> ZolaChatElementFrame {
        ZolaCrypto.packChatElementFrame(bodyData: body, srcId: srcId, srcType: 3,
            msgType: 1, cmd: command, subCmd: subCommand, seqId: seqId, needAck: 1)
    }

    public static func readFrame(threadId: Int64, isGroup: Bool, version: Int64 = 0, srcId: Int32, seqId: Int32) throws -> ZolaChatElementFrame {
        guard version >= 0 else { throw ZolaError.invalidArgument("Phiên bản bảng ghim không hợp lệ.") }
        var body = try base(threadId: threadId)
        body.appendInt64LE(version)
        return frame(body, command: isGroup ? 1703 : 1708, srcId: srcId, seqId: seqId)
    }

    public static func unpinUserFrame(threadId: Int64, boardId: Int64, version: Int64, srcId: Int32, seqId: Int32) throws -> ZolaChatElementFrame {
        guard boardId > 0, version >= 0 else { throw ZolaError.invalidArgument("Tin ghim chưa có mã bảng ghim từ máy chủ.") }
        var body = try base(threadId: threadId)
        body.appendInt64LE(boardId)
        body.appendInt32LE(2) // native GroupTopic type=message, not thread type
        body.appendInt64LE(version)
        return frame(body, command: 1706, srcId: srcId, seqId: seqId)
    }

    /// GroupTopicRequestManager.unpinTopicWithGroupId 0x1055e5870;
    /// body enum branch4 at0x1055e55b8, scalar writer widths independently verified.
    public static func unpinGroupFrame(threadId: Int64, boardId: Int64, srcId: Int32, seqId: Int32) throws -> ZolaChatElementFrame {
        guard boardId > 0 else { throw ZolaError.invalidArgument("Tin ghim chưa có mã bảng ghim từ máy chủ.") }
        var body = try base(threadId: threadId)
        body.appendInt64LE(boardId)
        body.appendInt32LE(2)
        return frame(body, command: 241, subCommand: 3, srcId: srcId, seqId: seqId)
    }

    /// copyMessageTopicDataFromChatEntity reads native mediatype, NOT quote/server subCmd.
    /// These values are independently mapped in ChatSocketCmdHelper 0x100c8c308.
    public static func mediaType(for message: ZolaMessage) throws -> Int {
        if message.msgType == "chat.gif" { return 42 }
        switch message.kind {
        case "text": return 0 // ChatEntity.localChatTextWithMessage 0x100d29b64
        case "voice": return 2
        case "video": return 3
        case "photo": return 11
        case "sticker": return 7
        case "file": return 41
        default: throw ZolaError.invalidArgument("Loại nội dung này chưa hỗ trợ ghim native.")
        }
    }

    public static func pinUserFrame(message: ZolaMessage, version: Int64, srcId: Int32, seqId: Int32) throws -> ZolaChatElementFrame {
        guard !message.isGroup else { throw ZolaError.invalidArgument("Hãy dùng lệnh ghim nhóm native.") }
        return try pinFrame(message: message, version: version, srcId: srcId, seqId: seqId)
    }

    public static func pinGroupFrame(message: ZolaMessage, srcId: Int32, seqId: Int32) throws -> ZolaChatElementFrame {
        guard message.isGroup else { throw ZolaError.invalidArgument("Tin nhắn không thuộc nhóm.") }
        return try pinFrame(message: message, version: 0, srcId: srcId, seqId: seqId)
    }

    private static func pinFrame(message: ZolaMessage, version: Int64, srcId: Int32, seqId: Int32) throws -> ZolaChatElementFrame {
        guard message.id > 0, message.cliMsgId > 0, version >= 0,
              !["sending", "send-failed", "send-unconfirmed"].contains(message.source),
              !["recalled", "call", "unknown"].contains(message.kind) else {
            throw ZolaError.invalidArgument("Tin nhắn này chưa thể ghim đồng bộ.")
        }
        var body = try base(threadId: message.threadId)
        if !message.isGroup { body.appendInt64LE(version) }
        // TopicPropertyData: byte count; repeated byte propertyType + longString JSON.
        // Native synthetic message constructor produced property tags 0,1,3,4,5,6.
        let properties: [(UInt8, [String: Any])] = [
            (0, ["title": message.previewText, "msg_type": try mediaType(for: message),
                 "global_msg_id": String(message.id), "client_msg_id": String(message.cliMsgId),
                 "senderUid": String(message.senderId), "senderName": message.senderName,
                 "thumb": message.attachments.first.map { $0.thumbUrl.isEmpty ? $0.url : $0.thumbUrl } ?? ""]),
            (1, ["repeatRule": "[]"]),
            (3, ["startTime": 0, "endTime": 0, "subType": 0, "calendarType": 0]),
            (4, ["emoji": ""]), (5, ["needPin": 1]), (6, ["topicType": 2])
        ]
        body.appendUInt8(UInt8(properties.count))
        for (tag, object) in properties {
            let json = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
            guard json.count <= Int(Int32.max) else { throw ZolaError.invalidArgument("Nội dung tin ghim quá dài.") }
            body.appendUInt8(tag)
            body.appendInt32LE(Int32(json.count))
            body.append(json)
        }
        return frame(body, command: message.isGroup ? 1752 : 1705, subCommand: message.isGroup ? 2 : 0, srcId: srcId, seqId: seqId)
    }

    public static func validateAcknowledgement(_ response: ZolaUnpackedChatElement, command: Int16, sequence: Int32) throws {
        guard response.cmd == command, response.seqId == sequence,
              let raw = try? JSONSerialization.jsonObject(with: response.decodedBodyData) as? [String: Any],
              let code = raw["error_code"] as? NSNumber, CFGetTypeID(code) != CFBooleanGetTypeID(),
              code.doubleValue == 0 else {
            throw ZolaError.transport("Máy chủ chưa xác nhận đúng yêu cầu bảng ghim.")
        }
    }

    /// ZAGetPinBoardResponse.parseFromData 0x1027951c4; GroupTopic parser0x1001732b0.
    /// Do not turn a malformed/missing list into an authoritative empty board.
    public static func parse(_ data: [String: Any], threadId: Int64, isGroup: Bool) throws -> ZolaPinBoard {
        guard data["boardVersion"] != nil, let items = data["items"] as? [[String: Any]] else {
            throw ZolaError.transport("Máy chủ chưa trả danh sách ghim hợp lệ.")
        }
        let version = ZolaJSON.int64(data["boardVersion"])
        guard version >= 0 else { throw ZolaError.transport("Phiên bản bảng ghim không hợp lệ.") }
        func object(_ raw: Any?) -> [String: Any]? {
            if let raw = raw as? [String: Any] { return raw }
            if let raw = raw as? String, let bytes = raw.data(using: .utf8) {
                return (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any]
            }
            return nil
        }
        let messages = items.compactMap { item -> ZolaPinnedMessage? in
            guard ZolaJSON.int(item["type"], default: -1) == 2,
                  let properties = object(item["properties"]), let attachment = object(properties["0"]) else { return nil }
            let id = ZolaJSON.int64(item["id"])
            let global = ZolaJSON.int64(attachment["global_msg_id"])
            let client = ZolaJSON.int64(attachment["client_msg_id"])
            guard id > 0, global > 0 || client > 0 else { return nil }
            return .init(id: id, messageId: global, cliMsgId: client,
                         title: ZolaJSON.string(attachment["title"]), senderUid: ZolaJSON.int64(attachment["senderUid"]),
                         // Native ZAPinBoardEntity.isPinningTopicWithIdentity uses board membership.
                         // Live read1708 returns valid pinned type2 entries with legacy isPin=0.
                         isPinned: true)
        }
        return .init(threadId: threadId, isGroup: isGroup, version: version,
                     maximumItems: max(0, ZolaJSON.int(data["maxBoardItems"], default: 10)), messages: messages)
    }
}

extension ZolaClient {
    /// Returns nil for dry-run (no socket is opened). User and group read commands are independently verified.
    public func fetchNativePinBoard(threadId: Int64, isGroup: Bool, version: Int64 = 0,
                                    dryRun: Bool = true) async throws -> ZolaPinBoard? {
        try assertSessionAlive()
        _ = try ZolaNativePinBoard.readFrame(threadId: threadId, isGroup: isGroup, version: version,
                                            srcId: Int32(truncatingIfNeeded: session.uid), seqId: 1)
        guard !dryRun else { return nil }
        #if canImport(Network)
        return try await withAuthenticatedChatSocket { socket in
            let seq = await socket.nextSeqId()
            let frame = try ZolaNativePinBoard.readFrame(threadId: threadId, isGroup: isGroup, version: version,
                                                        srcId: Int32(truncatingIfNeeded: session.uid), seqId: seq)
            let response = try await socket.sendAndWait(rawPayload: frame.payload, expectedCmd: isGroup ? 1703 : 1708,
                timeoutSeconds: 8, ackSeqId: seq, ackCmds: [isGroup ? 1703 : 1708], requiresResponseBody: true)
            let parsed = try parseChatSocketResponse(response)
            try ZolaNativePinBoard.validateAcknowledgement(response, command: isGroup ? 1703 : 1708, sequence: seq)
            return try ZolaNativePinBoard.parse(parsed.data, threadId: threadId, isGroup: isGroup)
        }
        #else
        throw ZolaError.transport("Nền tảng không hỗ trợ bảng ghim native.")
        #endif
    }

    public func pinNativeUserMessage(_ message: ZolaMessage, boardVersion: Int64, dryRun: Bool = true) async throws {
        try assertSessionAlive()
        let frame = try ZolaNativePinBoard.pinUserFrame(message: message, version: boardVersion,
            srcId: Int32(truncatingIfNeeded: session.uid), seqId: 1)
        guard !dryRun else { return }
        try await executeNativePinMutation(command: 1705, build: { seq in
            try ZolaNativePinBoard.pinUserFrame(message: message, version: boardVersion,
                srcId: Int32(truncatingIfNeeded: self.session.uid), seqId: seq)
        })
        _ = frame
    }

    public func unpinNativeUserMessage(threadId: Int64, boardId: Int64, boardVersion: Int64, dryRun: Bool = true) async throws {
        try assertSessionAlive()
        _ = try ZolaNativePinBoard.unpinUserFrame(threadId: threadId, boardId: boardId, version: boardVersion,
            srcId: Int32(truncatingIfNeeded: session.uid), seqId: 1)
        guard !dryRun else { return }
        try await executeNativePinMutation(command: 1706, build: { seq in
            try ZolaNativePinBoard.unpinUserFrame(threadId: threadId, boardId: boardId, version: boardVersion,
                srcId: Int32(truncatingIfNeeded: self.session.uid), seqId: seq)
        })
    }

    public func pinNativeGroupMessage(_ message: ZolaMessage, dryRun: Bool = true, groupSendEnabled: Bool = false) async throws {
        try assertSessionAlive()
        try ZolaGroupMediaWire.checkPolicy(enabled: groupSendEnabled, dryRun: dryRun, group: groupsCache[message.threadId], senderUid: session.uid)
        _ = try ZolaNativePinBoard.pinGroupFrame(message: message, srcId: Int32(truncatingIfNeeded: session.uid), seqId: 1)
        guard !dryRun else { return }
        try await executeNativePinMutation(command: 1752, build: { seq in
            try ZolaNativePinBoard.pinGroupFrame(message: message, srcId: Int32(truncatingIfNeeded: self.session.uid), seqId: seq)
        })
    }

    public func unpinNativeGroupMessage(threadId: Int64, boardId: Int64, dryRun: Bool = true, groupSendEnabled: Bool = false) async throws {
        try assertSessionAlive()
        try ZolaGroupMediaWire.checkPolicy(enabled: groupSendEnabled, dryRun: dryRun, group: groupsCache[threadId], senderUid: session.uid)
        _ = try ZolaNativePinBoard.unpinGroupFrame(threadId: threadId, boardId: boardId, srcId: Int32(truncatingIfNeeded: session.uid), seqId: 1)
        guard !dryRun else { return }
        try await executeNativePinMutation(command: 241, build: { seq in
            try ZolaNativePinBoard.unpinGroupFrame(threadId: threadId, boardId: boardId, srcId: Int32(truncatingIfNeeded: self.session.uid), seqId: seq)
        })
    }

    private func executeNativePinMutation(command: Int16, build: (Int32) throws -> ZolaChatElementFrame) async throws {
        #if canImport(Network)
        try await withAuthenticatedChatSocket { socket in
            let seq = await socket.nextSeqId()
            let frame = try build(seq)
            let response = try await socket.sendAndWait(rawPayload: frame.payload, expectedCmd: command,
                timeoutSeconds: 8, ackSeqId: seq, ackCmds: [command], requiresResponseBody: true)
            _ = try parseChatSocketResponse(response) // includes the102/-96 session breaker
            try ZolaNativePinBoard.validateAcknowledgement(response, command: command, sequence: seq)
        }
        #else
        throw ZolaError.transport("Nền tảng không hỗ trợ bảng ghim native.")
        #endif
    }
}
