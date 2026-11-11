import Foundation
import CoreFoundation

/// Native recall capabilities shared by the SDK and UI. Server-side time limits remain authoritative.
public enum ZolaNativeRecall {
    public static func validate(message: ZolaMessage, accountUid: Int64, threadId: Int64) throws {
        guard accountUid > 0, accountUid <= Int64(UInt32.max),
              threadId > 0, threadId <= Int64(UInt32.max), message.threadId == threadId else {
            throw ZolaError.invalidArgument("Tin nhắn không thuộc cuộc trò chuyện này.")
        }
        guard message.isSelf, message.senderId == accountUid else {
            throw ZolaError.invalidArgument("Chỉ có thể thu hồi tin nhắn do chính bạn gửi.")
        }
        guard message.id > 0, message.cliMsgId > 0,
              !["sending", "send-failed", "send-unconfirmed"].contains(message.source) else {
            throw ZolaError.invalidArgument("Tin nhắn chưa được xác nhận đã gửi. Hãy thử lại sau khi đồng bộ.")
        }
        guard message.kind != "recalled", message.kind != "call", message.kind != "unknown" else {
            throw ZolaError.invalidArgument("Không thể thu hồi loại tin nhắn này.")
        }
        // mcrypt1 is ordinary session-key encryption, NOT the native isE2eeMessage property.
        guard message.mcrypt == 0 || message.mcrypt == 1 else {
            throw ZolaError.safetyGate("Định dạng mã hoá của tin nhắn này chưa được hỗ trợ thu hồi.")
        }
    }
}

extension ZolaClient {
    /// IPA 26.10.02 `ZAUndoSendModel.getSendingChatElement:` 0x100b8b284:
    /// body = destination i32, original client i64, original global i64, media subtype i32, sender i32.
    /// `integerToBytes:` 0x103ab15b8 / `longToBytes:` 0x103ab1698 copy little-endian values.
    /// Direct command114/group204, subcommand2; msgType2, srcType3, destinationType3, global header ID0.
    public func buildRecallSocketFrame(
        message: ZolaMessage, threadId: Int64, type: ZolaThreadType = .user, seqId: Int32 = 1
    ) throws -> ZolaChatElementFrame {
        try assertSessionAlive()
        try ZolaNativeRecall.validate(message: message, accountUid: session.uid, threadId: threadId)
        guard message.isGroup == (type == .group) else {
            throw ZolaError.invalidArgument("Loại cuộc trò chuyện không khớp tin nhắn.")
        }
        var body = Data()
        body.appendInt32LE(Int32(truncatingIfNeeded: threadId))
        body.appendInt64LE(message.cliMsgId)
        body.appendInt64LE(message.id)
        // Same native getSubCmdType(mediatype) mapping as QuoteData / ordinary message sends.
        body.appendInt32LE(Int32(ZolaQuote.wireServerMsgType(forMsgType: message.msgType, kind: message.kind)))
        body.appendInt32LE(Int32(truncatingIfNeeded: message.senderId))
        return ZolaCrypto.packChatElementFrame(bodyData: body, srcId: Int32(truncatingIfNeeded: session.uid),
            srcType: 3, msgType: 2, cmd: message.isGroup ? 204 : 114, subCmd: 2, seqId: seqId,
            desId: Int32(truncatingIfNeeded: threadId), desType: 3, globalMsgId: 0)
    }

    /// Uses the existing authenticated listener when present. Never opens a competing socket or uses Web hosts.
    /// A transport receipt is insufficient: only an explicit native JSON success acknowledges recall.
    @discardableResult
    public func recallNative(
        message: ZolaMessage, threadId: Int64, type: ZolaThreadType = .user,
        dryRun: Bool = true, timeoutSeconds: Double = 8
    ) async throws -> Bool {
        _ = try buildRecallSocketFrame(message: message, threadId: threadId, type: type)
        guard !dryRun else { return true }
        #if canImport(Network)
        let command: Int16 = message.isGroup ? 204 : 114
        return try await withAuthenticatedChatSocket { socket in
            let seq = await socket.nextSeqId()
            let frame = try buildRecallSocketFrame(message: message, threadId: threadId, type: type, seqId: seq)
            let response = try await socket.sendAndWait(rawPayload: frame.payload, expectedCmd: command,
                timeoutSeconds: timeoutSeconds, ackSeqId: seq, ackCmds: [command], requiresResponseBody: true)
            try validateRecallSocketResponse(response, expectedCommand: command, seqId: seq)
            return true
        }
        #else
        throw ZolaError.transport("Nền tảng này không hỗ trợ kênh thu hồi tin nhắn Native.")
        #endif
    }

    #if canImport(Network)
    /// `ZAUndoChatManager.checkValidResult:` 0x100b8aed8 gunzips JSON and checks error_code.
    /// We additionally fail closed on missing/malformed error codes and unrelated responses.
    internal func validateRecallSocketResponse(
        _ response: ZolaUnpackedChatElement, expectedCommand: Int16, seqId: Int32
    ) throws {
        guard response.cmd == expectedCommand, response.seqId == seqId,
              response.msgType == 3 || response.msgType == 4 else {
            throw ZolaError.transport("Phản hồi thu hồi tin nhắn không khớp yêu cầu.")
        }
        _ = try parseChatSocketResponse(response) // Preserves session-expiry latching and server errors.
        guard let json = try? JSONSerialization.jsonObject(with: response.decodedBodyData) as? [String: Any],
              let value = json["error_code"] else {
            throw ZolaError.transport("Máy chủ chưa xác nhận thu hồi tin nhắn.")
        }
        let code: Int?
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
           number.doubleValue == Double(number.intValue) {
            code = number.intValue
        } else if let string = value as? String {
            code = Int(string)
        } else {
            code = nil
        }
        guard code == 0 else {
            throw ZolaError.transport("Phản hồi xác nhận thu hồi tin nhắn không hợp lệ.")
        }
    }
    #endif
}
