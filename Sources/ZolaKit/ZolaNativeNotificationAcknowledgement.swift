import Foundation

/// Native261002 NotifyStreamModule: cmd600 is a generic notification stream;
/// confirmNotifyACK:needACK: (0x100ef5af0) sends cmd601, concatenated Int64LE IDs.
/// Only the independently verified type188 group-info notification is acknowledged.
/// Unknown/mixed/partially malformed batches remain unacknowledged for catch-up/replay.
public enum ZolaNativeNotificationAcknowledgement {
    public static func frame(command: Int16, decodedBody: Data, srcId: Int32, seqId: Int32) -> ZolaChatElementFrame? {
        guard command == 600, srcId > 0, decodedBody.count <= 1024 * 1024,
              let root = try? JSONSerialization.jsonObject(with: decodedBody) as? [[String: Any]],
              !root.isEmpty, root.count <= 256 else { return nil }
        var ids: [Int64] = []
        var seen = Set<Int64>()
        var itemCount = 0
        for notification in root {
            guard ZolaGroupPollWire.integer(notification["type"]) == 188,
                  let id = positiveDecimalID(notification["id"]),
                  let items = notification["item"] as? [[String: Any]], !items.isEmpty,
                  items.count <= 256 else { return nil }
            itemCount += items.count
            guard itemCount <= 256,
                  items.allSatisfy({ ZolaGroupPollWire.positiveID($0["groupId"]) != nil }) else { return nil }
            if seen.insert(id).inserted { ids.append(id) }
        }
        var body = Data()
        for id in ids { body.appendInt64LE(id) }
        return ZolaCrypto.packChatElementFrame(bodyData: body, srcId: srcId, srcType: 3,
            msgType: 1, cmd: 601, subCmd: 0, seqId: seqId, needAck: 0)
    }

    private static func positiveDecimalID(_ value: Any?) -> Int64? {
        if let string = value as? String {
            guard !string.isEmpty, string.utf8.count <= 19,
                  string.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
                  let id = Int64(string), id > 0 else { return nil }
            return id
        }
        return ZolaGroupPollWire.positiveID(value)
    }
}
