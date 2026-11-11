import Foundation

/// A native `rIcon` / `rMsg` mutation by one participant, not a snapshot of everyone's reactions.
public struct ZolaReactionUpdate: Codable, Equatable, Sendable {
    public let threadId: Int64
    public let isGroup: Bool
    public let actorUid: Int64
    public let messageId: Int64
    public let cliMsgId: Int64
    /// Empty means this participant removed their reaction.
    public let emoji: String
    /// Native additive quantity; absent in legacy assignment-only events.
    public let count: Int?
    /// Native -1 removes the named icon (or all this actor's icons when empty).
    public let reactionType: Int?
    /// Reaction envelope ID, distinct from the target's messageId. Used to deduplicate delivery replays.
    public let envelopeId: Int64?
    public let clientEnvelopeId: Int64?

    public init(threadId: Int64, isGroup: Bool, actorUid: Int64, messageId: Int64, cliMsgId: Int64, emoji: String, count: Int? = nil, reactionType: Int? = nil, envelopeId: Int64? = nil, clientEnvelopeId: Int64? = nil) {
        self.threadId = threadId
        self.isGroup = isGroup
        self.actorUid = actorUid
        self.messageId = messageId
        self.cliMsgId = cliMsgId
        self.emoji = emoji
        self.count = count
        self.reactionType = reactionType
        self.envelopeId = envelopeId
        self.clientEnvelopeId = clientEnvelopeId
    }

    /// Decodes native reaction params shared by send subCmd=55 and incoming commands 1780/1782/1785/1787.
    /// RichMessageContent._parseParamsAttachDataForReaction (IPA 26.10.02, 0x100d948d8). No message-author inference:
    /// `msgSender` identifies the target's author, whereas the envelope sender is the reacting user.
    internal static func fromRawItem(_ raw: [String: Any], selfUid: Int64, knownGroupIds: Set<Int64> = [], isGroup: Bool = false) -> [ZolaReactionUpdate] {
        let wrapper = raw["text"] as? [String: Any]
        let inner = wrapper?["data"] as? [String: Any] ?? raw
        func object(_ value: Any?) -> [String: Any]? {
            if let value = value as? [String: Any] { return value }
            guard let value = value as? String, let data = value.data(using: .utf8) else { return nil }
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }
        func payload(_ node: [String: Any], depth: Int = 0) -> [String: Any]? {
            if node["rIcon"] is String, node["rMsg"] is [Any] { return node }
            guard depth < 4 else { return nil }
            for key in ["msg", "content", "attach", "params", "param", "data"] {
                if let next = object(node[key]), let found = payload(next, depth: depth + 1) { return found }
            }
            return nil
        }
        guard let body = payload(inner), let icon = body["rIcon"] as? String,
              let targets = body["rMsg"] as? [[String: Any]] else { return [] }
        let trimmed = icon.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty || ZolaReactionCatalog.displayEmoji(for: trimmed) != nil else { return [] }
        let actor = ZolaJSON.int64(inner["fromU"] ?? inner["uidFrom"] ?? inner["src"] ?? inner["si"] ?? raw["fromU"] ?? raw["si"])
        let to = ZolaJSON.int64(inner["to"] ?? inner["idTo"] ?? inner["des"] ?? inner["gId"] ?? inner["groupId"] ?? inner["di"] ?? raw["to"] ?? raw["di"])
        let group = isGroup || knownGroupIds.contains(to)
        let thread = group || actor == selfUid ? to : actor
        guard actor > 0, thread > 0 else { return [] }
        let reactionType = body["rType"].map { ZolaJSON.int($0) }
        let count = body["rCount"].map { max(1, ZolaJSON.int($0, default: 1)) }
        let envelope = ZolaJSON.int64(inner["id"] ?? inner["globalMsgId"] ?? inner["msgId"] ?? inner["gmi"])
        let clientEnvelope = ZolaJSON.int64(inner["cliMsgId"] ?? inner["clientId"] ?? inner["cmi"])
        return targets.compactMap { target in
            let messageId = ZolaJSON.int64(target["gMsgID"])
            let cliMsgId = ZolaJSON.int64(target["cMsgID"])
            guard messageId > 0 || cliMsgId > 0 else { return nil }
            return ZolaReactionUpdate(threadId: thread, isGroup: group, actorUid: actor,
                                      messageId: messageId, cliMsgId: cliMsgId,
                                      emoji: ZolaReactionCatalog.displayEmoji(for: trimmed) ?? "",
                                      count: count, reactionType: reactionType,
                                      envelopeId: envelope > 0 ? envelope : nil,
                                      clientEnvelopeId: clientEnvelope > 0 ? clientEnvelope : nil)
        }
    }
}
