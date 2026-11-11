import Foundation
import CoreFoundation

public enum ZolaDeliveryStatus: String, Codable, Sendable, Equatable {
    case delivered, seen
    public func merging(_ incoming: Self) -> Self { self == .seen || incoming == .seen ? .seen : .delivered }
}

/// An acknowledgement by a peer, never a new message. Direct actor IDs identify the peer;
/// group receipts retain the individual member ID rather than claiming that everyone has read it.
public struct ZolaMessageDeliveryUpdate: Codable, Sendable, Equatable {
    public let threadId: Int64
    public let isGroup: Bool
    public let actorId: Int64
    public let cliMsgId: Int64
    public let globalMsgId: Int64
    public let status: ZolaDeliveryStatus
    public init(threadId: Int64, isGroup: Bool, actorId: Int64, cliMsgId: Int64, globalMsgId: Int64, status: ZolaDeliveryStatus) {
        self.threadId = threadId; self.isGroup = isGroup; self.actorId = actorId
        self.cliMsgId = cliMsgId; self.globalMsgId = globalMsgId; self.status = status
    }
    /// Preserves every content field. Rejects collisions across accounts, threads and already-resolved IDs.
    public func reconciling(_ message: ZolaMessage, accountUid: Int64) -> ZolaMessage? {
        guard accountUid > 0, actorId > 0, actorId != accountUid, message.senderId == accountUid, message.isSelf,
              message.threadId == threadId, message.isGroup == isGroup,
              cliMsgId > 0, globalMsgId > 0, message.cliMsgId == cliMsgId,
              message.id == globalMsgId || message.id == cliMsgId || message.id <= 0 else { return nil }
        let source = ["sending", "send-unconfirmed", "send-failed"].contains(message.source) ? "native-delivered" : message.source
        return ZolaMessage(id: globalMsgId, cliMsgId: cliMsgId, threadId: message.threadId, isGroup: message.isGroup,
            senderId: message.senderId, senderName: message.senderName, toId: message.toId, tsMs: message.tsMs,
            msgType: message.msgType, kind: message.kind, text: message.text, attachments: message.attachments,
            quote: message.quote, isSelf: message.isSelf, isCloud: message.isCloud, mcrypt: message.mcrypt,
            source: source, reactions: message.reactions, hasReactionSnapshot: message.hasReactionSnapshot,
            mentions: message.mentions, webContent: message.webContent, rawDebugJson: message.rawDebugJson,
            groupEvent: message.groupEvent, boardCard: message.boardCard)
    }
}

public struct ZolaTypingUpdate: Codable, Sendable, Equatable {
    public let threadId: Int64
    public let isGroup: Bool
    public let actorId: Int64
    /// Native subcommand; 1=text, 31=voice. Other states are retained without invented stop semantics.
    public let kind: Int8
    public let isFromPC: Bool
    public init(threadId: Int64, isGroup: Bool, actorId: Int64, kind: Int8, isFromPC: Bool = false) {
        self.threadId = threadId; self.isGroup = isGroup; self.actorId = actorId
        self.kind = kind; self.isFromPC = isFromPC
    }
}

/// IPA26.10.02 ChatProcessor/BaseChatProcessor/ChatSocketCmdHelper. Verified against live native traffic.
public enum ZolaNativeChatSignals {
    public static let receiptCommands: Set<Int16> = [102, 104, 107, 1996, 202, 203, 208, 209, 212, 213]
    public static func handles(_ command: Int16) -> Bool { receiptCommands.contains(command) || command == 106 || command == 206 }
    private static let groupReceipts: Set<Int16> = [202, 203, 208, 209, 212, 213]
    private static let seenReceipts: Set<Int16> = [107, 1996, 203, 209, 213]

    public struct Batch: Sendable {
        public let deliveries: [ZolaMessageDeliveryUpdate]
        public let typing: ZolaTypingUpdate?
        public let hasMore: Bool
        private let acknowledgementBody: Data?
        private let acknowledgementCommand: Int16
        private let acknowledgementSubcommand: Int8
        fileprivate init(deliveries: [ZolaMessageDeliveryUpdate] = [], typing: ZolaTypingUpdate? = nil,
                         hasMore: Bool = false, acknowledgementBody: Data? = nil,
                         acknowledgementCommand: Int16 = 0, acknowledgementSubcommand: Int8 = 0) {
            self.deliveries = deliveries; self.typing = typing; self.hasMore = hasMore
            self.acknowledgementBody = acknowledgementBody; self.acknowledgementCommand = acknowledgementCommand
            self.acknowledgementSubcommand = acknowledgementSubcommand
        }
        /// Native queue-specific pagination; its cursor is server-owned, not a chat-history watermark.
        public func nextPage(srcId: Int32, seqId: Int32) -> ZolaChatElementFrame? {
            guard hasMore, let command = [Int16(103): Int16(104), 108: 1996, 210: 212, 211: 213][acknowledgementCommand] else { return nil }
            return ZolaCrypto.packChatElementFrame(bodyData: Data(), srcId: srcId, srcType: 3,
                msgType: 1, cmd: command, subCmd: 0, seqId: seqId, needAck: 0, desType: 3)
        }

        /// ACK-of-status has a different command and no seen flag. Never re-ACK these ACK commands.
        public func acknowledgement(srcId: Int32, seqId: Int32) -> ZolaChatElementFrame? {
            guard let acknowledgementBody else { return nil }
            return ZolaCrypto.packChatElementFrame(bodyData: acknowledgementBody, srcId: srcId, srcType: 3,
                msgType: 1, cmd: acknowledgementCommand, subCmd: acknowledgementSubcommand, seqId: seqId,
                needAck: 0, desType: acknowledgementCommand == 108 || acknowledgementCommand == 211 ? 3 : 0)
        }
    }

    public static func parse(_ frame: ZolaUnpackedChatElement, accountUid: Int64) -> Batch? {
        guard accountUid > 0, handles(frame.cmd), frame.retCode == 0, frame.msgType != 4,
              frame.decodedBodyData.count <= 256 * 1024 else { return nil }
        let root: [String: Any]
        if frame.cmd == 106 && (frame.decodedBodyData.isEmpty || frame.decodedBodyData == Data([0])) {
            root = [:] // Native direct typing falls back to the header's srcId when JSON is absent.
        } else {
            guard let parsed = try? JSONSerialization.jsonObject(with: frame.decodedBodyData) as? [String: Any],
                  noError(parsed) else { return nil }
            root = parsed
        }
        if frame.cmd == 106 || frame.cmd == 206 {
            let group = frame.cmd == 206
            let source = Int64(UInt32(bitPattern: frame.srcId))
            guard source > 0, let actor = group ? positiveID(root["uid"]) : source,
                  actor != accountUid else { return nil }
            return Batch(typing: ZolaTypingUpdate(threadId: source, isGroup: group, actorId: actor,
                kind: frame.subCmd, isFromPC: flag(root["isPC"])))
        }
        guard let entries = root["data"] as? [[String: Any]], !entries.isEmpty else { return nil }
        let group = groupReceipts.contains(frame.cmd), seenQueue = seenReceipts.contains(frame.cmd)
        var updates: [ZolaMessageDeliveryUpdate] = []
        for entry in entries {
            guard let destination = positiveID(entry["di"]), let messages = entry["msg"] as? [[String: Any]],
                  !messages.isEmpty else { return nil }
            for message in messages {
                guard let actor = positiveID(message["sid"]), let cmi = positiveID(message["cmi"]),
                      let gmi = positiveID(message["gmi"]), noError(message) else { return nil }
                // Native skips receipts originating from our own UID. Direct di may be own UID or peer;
                // anything else is unrelated to this account and cannot be used to heal an outgoing bubble.
                guard group || destination == accountUid || destination == actor else { return nil }
                if actor != accountUid {
                    updates.append(ZolaMessageDeliveryUpdate(threadId: group ? destination : actor, isGroup: group,
                        actorId: actor, cliMsgId: cmi, globalMsgId: gmi,
                        status: seenQueue || flag(entry["seen"]) ? .seen : .delivered))
                }
            }
        }
        guard let ackBody = try? JSONSerialization.data(withJSONObject: ["data": entries], options: [.sortedKeys]) else { return nil }
        return Batch(deliveries: updates, hasMore: flag(root["more"]), acknowledgementBody: ackBody,
            acknowledgementCommand: seenQueue ? (group ? 211 : 108) : (group ? 210 : 103),
            acknowledgementSubcommand: seenQueue ? 1 : 3)
    }

    /// HttpSendMsgManager also reconciles *older* cmi/gmi pairs piggybacked on a later HTTP response.
    /// Keep this independent of the send's own receipt: never assign a different message's gmi to that send.
    public static func httpDeliveries(_ body: Data, accountUid: Int64) -> [ZolaMessageDeliveryUpdate] {
        guard let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any], noError(root),
              let data = dictionary(root["data"]), let deliver = dictionary(data["deliver"]), noError(deliver),
              let entries = deliver["data"] as? [[String: Any]] else { return [] }
        var updates: [ZolaMessageDeliveryUpdate] = []
        for entry in entries {
            guard let peer = positiveID(entry["di"]), peer != accountUid,
                  let messages = entry["msg"] as? [[String: Any]] else { continue }
            for item in messages {
                guard noError(item), let cmi = positiveID(item["cmi"]), let gmi = positiveID(item["gmi"]) else { continue }
                updates.append(.init(threadId: peer, isGroup: false, actorId: peer,
                    cliMsgId: cmi, globalMsgId: gmi, status: .delivered))
            }
        }
        return updates
    }

    public static func typingFrame(accountUid: Int64, threadId: Int64, isGroup: Bool,
                                   timestampMs: Int64, seqId: Int32) throws -> ZolaChatElementFrame {
        try validateUIDs(accountUid, threadId)
        guard timestampMs > 0 else { throw ZolaError.invalidArgument("Thiếu thời gian gõ tin nhắn.") }
        return ZolaCrypto.packChatElementFrame(bodyData: Data([0]), srcId: Int32(truncatingIfNeeded: accountUid),
            srcType: 3, msgType: 2, cmd: isGroup ? 206 : 106, subCmd: 1, seqId: seqId,
            needAck: 0, desId: Int32(truncatingIfNeeded: threadId), desType: 3, globalMsgId: timestampMs)
    }

    public static func seenFrame(accountUid: Int64, threadId: Int64, messages: [ZolaMessage], seqId: Int32) throws -> ZolaChatElementFrame {
        try validateUIDs(accountUid, threadId)
        guard let first = messages.first, !messages.isEmpty, messages.count <= 100,
              messages.allSatisfy({ !$0.isSelf && $0.senderId != accountUid && $0.senderId > 0 && $0.threadId == threadId
                  && $0.isGroup == first.isGroup && $0.id > 0 && $0.cliMsgId > 0 && $0.id != $0.cliMsgId
                  && (first.isGroup || $0.toId == accountUid) && ($0.mcrypt == 0 || $0.mcrypt == 1) }) else {
            throw ZolaError.invalidArgument("Chỉ đánh dấu đã xem tin nhắn nhận được có mã máy chủ xác thực.")
        }
        let items: [[String: Any]] = messages.map { message in
            var item: [String: Any] = ["gmi": message.id, "cmi": message.cliMsgId, "fromDI": 0,
                "ts": message.tsMs, "si": message.senderId, "cmd": message.isGroup ? 201 : 101,
                "mt": max(1, Int(ZolaQuote.wireServerMsgType(forMsgType: message.msgType, kind: message.kind))),
                "at": message.isGroup ? 3 : 5, "di": message.isGroup ? threadId : accountUid]
            if !message.isGroup { item["st"] = 5 }
            return item
        }
        guard let frame = ZolaCrypto.packSocketDeliveredAckFrame(srcId: Int32(truncatingIfNeeded: accountUid),
            items: items, isGroup: first.isGroup, isSeen: 1, seqId: seqId) else {
            throw ZolaError.invalidArgument("Không tạo được xác nhận đã xem.")
        }
        return frame
    }

    private static func validateUIDs(_ account: Int64, _ thread: Int64) throws {
        guard account > 0, account <= Int64(UInt32.max), thread > 0, thread <= Int64(UInt32.max) else {
            throw ZolaError.invalidArgument("UID không hợp lệ.")
        }
    }
    private static func positiveID(_ value: Any?) -> Int64? {
        if let string = value as? String, let value = Int64(string), value > 0 { return value }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              let value = Int64(number.stringValue), value > 0 else { return nil }
        return value
    }
    private static func flag(_ value: Any?) -> Bool {
        if let n = value as? NSNumber { return n.intValue == 1 }
        return value as? String == "1"
    }
    private static func noError(_ object: [String: Any]) -> Bool {
        for key in ["error_code", "e", "err"] {
            guard let value = object[key], !(value is NSNull) else { continue }
            if let string = value as? String { if string != "0" { return false } }
            else if let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue == 0 {} else { return false }
        }
        return true
    }
    private static func dictionary(_ value: Any?) -> [String: Any]? {
        if let d = value as? [String: Any] { return d }
        guard let string = value as? String, let data = string.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

extension ZolaClient {
    /// Fire-and-forget, like native sendStatusTyping. Return means submitted to socket, not read by the peer.
    public func sendTypingNative(threadId: Int64, type: ZolaThreadType = .user, dryRun: Bool = true) async throws {
        try Task.checkCancellation()
        try assertSessionAlive()
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        _ = try ZolaNativeChatSignals.typingFrame(accountUid: session.uid, threadId: threadId,
            isGroup: type == .group, timestampMs: now, seqId: 1)
        guard !dryRun else { return }
        #if canImport(Network)
        try await withAuthenticatedChatSocket { socket in
            let seq = await socket.nextSeqId()
            let frame = try ZolaNativeChatSignals.typingFrame(accountUid: session.uid, threadId: threadId,
                isGroup: type == .group, timestampMs: now, seqId: seq)
            try Task.checkCancellation()
            try await socket.sendFrame(frame)
        }
        #else
        throw ZolaError.transport("Không có UXChatSocket trên nền tảng này.")
        #endif
    }
    /// Default dry run. The caller must only submit messages actually shown to the user.
    public func sendSeenNative(threadId: Int64, messages: [ZolaMessage], dryRun: Bool = true) async throws {
        try Task.checkCancellation()
        try assertSessionAlive()
        _ = try ZolaNativeChatSignals.seenFrame(accountUid: session.uid, threadId: threadId, messages: messages, seqId: 1)
        guard !dryRun else { return }
        #if canImport(Network)
        try await withAuthenticatedChatSocket { socket in
            let seq = await socket.nextSeqId()
            let frame = try ZolaNativeChatSignals.seenFrame(accountUid: session.uid, threadId: threadId, messages: messages, seqId: seq)
            try Task.checkCancellation()
            try await socket.sendFrame(frame)
        }
        #else
        throw ZolaError.transport("Không có UXChatSocket trên nền tảng này.")
        #endif
    }
}
