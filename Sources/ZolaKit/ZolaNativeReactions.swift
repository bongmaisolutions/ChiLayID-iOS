import Foundation

public enum ZolaNativeReaction {
    /// ReactionEntity.chatElementParams 0x100e06c3c. -1 removes only rIcon, or all when empty.
    public static func parameters(icon: String, messageSenderUid: Int64, cliMsgId: Int64,
                                  globalMsgId: Int64, msgType: Int, removing: Bool = false) throws -> String {
        guard messageSenderUid > 0, cliMsgId > 0, globalMsgId > 0,
              let wire = ZolaReactionCatalog.wireReaction(for: icon) else {
            throw ZolaError.invalidArgument("Tin nhắn hoặc cảm xúc chưa có mã native hợp lệ.")
        }
        let body: [String: Any] = ["msgSender": String(messageSenderUid), "rIcon": wire.rIcon,
            "rType": removing || wire.rIcon.isEmpty ? -1 : wire.rType,
            "rCount": 1, "source": 6,
            "rMsg": [["cMsgID": cliMsgId, "gMsgID": globalMsgId, "msgType": msgType]]]
        return String(decoding: try JSONSerialization.data(withJSONObject: body,
            options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
    }
}

extension ZolaClient {
    /// Native failover113/sub55; default dry-run never sends a request.
    public func sendNativeReaction1To1(icon: String, message: ZolaMessage, removing: Bool = false,
                                       dryRun: Bool = true, clientIdMs: Int64? = nil) async throws -> ZolaSendReceipt {
        try assertSessionAlive()
        guard !message.isGroup, !["sending", "send-failed", "send-unconfirmed"].contains(message.source),
              !["recalled", "unknown", "call"].contains(message.kind) else {
            throw ZolaError.invalidArgument("Tin nhắn này chưa thể thả cảm xúc.")
        }
        let params = try ZolaNativeReaction.parameters(icon: icon, messageSenderUid: message.senderId,
            cliMsgId: message.cliMsgId, globalMsgId: message.id,
            msgType: Int(ZolaQuote.wireServerMsgType(forMsgType: message.msgType, kind: message.kind)), removing: removing)
        return try await sendMedia1To1(to: message.threadId, subCmd: ZolaConstants.subCmdSendReaction,
            param: params, includeIOSPropsOverride: false, dryRun: dryRun, clientIdMs: clientIdMs)
    }
}
