import Foundation

/// Native cmd600 is a generic notification stream, not a group-message envelope.
/// Verified261002: NotifyStreamModule 0x100ef6898/0x100ef5cd4/0x100ee489c,
/// jump-table type188→0x100ee566c; GroupFlowManager 0x10099bdec reads item[].groupId.
/// This decoder only invalidates group info. It cannot manufacture chat notices,
/// infer join/leave actions, or treat601–605 as equivalent without further evidence.
public enum ZolaGroupSystemNotifications {
    public struct Invalidation: Equatable, Sendable {
        public let notificationId: String
        public let groupId: Int64
        public var deduplicationKey: String { "\(notificationId):\(groupId)" }
    }
    public static func decode(command: Int16, decodedBody: Data) -> [Invalidation] {
        guard command == 600, decodedBody.count <= 1024 * 1024,
              let root = try? JSONSerialization.jsonObject(with: decodedBody) as? [Any],
              root.count <= 256 else { return [] }
        var result: [Invalidation] = []
        var seen = Set<String>()
        for value in root {
            guard let notification = value as? [String: Any],
                  ZolaGroupPollWire.integer(notification["type"]) == 188,
                  let items = notification["item"] as? [[String: Any]], items.count <= 256 else { continue }
            let id: String
            if let value = notification["id"] as? String { id = value }
            else if let value = ZolaGroupPollWire.positiveID(notification["id"]) { id = String(value) }
            else { continue }
            guard !id.isEmpty, id.utf8.count <= 128 else { continue }
            for item in items {
                guard let gid = ZolaGroupPollWire.positiveID(item["groupId"]) else { continue }
                let invalidation = Invalidation(notificationId: id, groupId: gid)
                if seen.insert(invalidation.deduplicationKey).inserted { result.append(invalidation) }
                // Oversized notifications fall back to the existing coalesced sync.
                if result.count > 256 { return [] }
            }
        }
        return result
    }
}
