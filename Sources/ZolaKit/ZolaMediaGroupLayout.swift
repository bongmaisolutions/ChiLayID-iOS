import Foundation
import CoreFoundation

/// Native Zalo iOS `261002` album ("media group layout") metadata for a batch of photos sent together.
///
/// - `+[ChatDataManager createMediaChatsWithResourceInfos:…]` (`0x100920810`): only for batches of 2+ items,
///   one `group_layout_id` for the whole batch (`[UXSessionContext uniqueServerTime]`), `id_in_group` 0…N-1,
///   `total_item_in_group` = N, `is_group_layout` = 1.
/// - `-[RichMessageContent _getParamForPhoto]` (`0x100D95424`) adds the four keys as JSON numbers to `param`;
///   receivers read them back in `_parseMediaGroupInfoWithDict:` (`0x100d93224`) to draw one grid.
/// - `-[ChatEntity getExtraDataDicToSend]` (`0x100d52b90`) also writes `{"groupMediaMsg":{"groupLayoutId":id}}`,
///   which `getPropertiesData:` emits as TLV tag 16 (`0x10` + Int32LE length + UTF-8, after tag 5).
public struct ZolaMediaGroupLayout: Codable, Sendable, Equatable {
    public let groupLayoutId: Int64
    public let index: Int
    public let total: Int

    /// Returns `nil` unless this is a real album slot: positive id, 2…100 items, `0 <= index < total`.
    public init?(groupLayoutId: Int64, index: Int, total: Int) {
        guard groupLayoutId > 0, (2...100).contains(total), (0..<total).contains(index) else { return nil }
        self.groupLayoutId = groupLayoutId
        self.index = index
        self.total = total
    }

    private enum CodingKeys: String, CodingKey { case groupLayoutId, index, total }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let layout = Self(groupLayoutId: try c.decode(Int64.self, forKey: .groupLayoutId),
                                index: try c.decode(Int.self, forKey: .index),
                                total: try c.decode(Int.self, forKey: .total)) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid album slot"))
        }
        self = layout
    }

    /// Read the same native photo parameters we send; never infer an album ID from timestamps.
    public static func fromPhotoParam(_ params: [String: Any]) -> Self? {
        func integer(_ value: Any?) -> Int64? {
            if let n = value as? NSNumber {
                guard CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
                return Int64(n.stringValue)
            }
            if let s = value as? String { return Int64(s.trimmingCharacters(in: .whitespacesAndNewlines)) }
            return nil
        }
        guard integer(params["is_group_layout"]) == 1,
              let id = integer(params["group_layout_id"]),
              let index = integer(params["id_in_group"]), let total = integer(params["total_item_in_group"]),
              let safeIndex = Int(exactly: index), let safeTotal = Int(exactly: total) else { return nil }
        return Self(groupLayoutId: id, index: safeIndex, total: safeTotal)
    }

    /// The four `_getParamForPhoto` keys, all JSON numbers.
    public var paramFields: [String: Any] {
        [
            "is_group_layout": 1,
            "id_in_group": index,
            "group_layout_id": NSNumber(value: groupLayoutId),
            "total_item_in_group": total,
        ]
    }

    /// TLV tag 16 payload written by `getExtraDataDicToSend`.
    public var extraDataJSON: String {
        #"{"groupMediaMsg":{"groupLayoutId":\#(groupLayoutId)}}"#
    }

    /// `chat.photo` `param` JSON shared by the 1-1 and group senders (sorted keys, unescaped slashes).
    /// Without `mediaGroup` the output is byte-identical to the single-photo param used before albums.
    public static func photoParamJSON(
        url: String, thumb: String, width: Int, height: Int, fileExt: String,
        mediaGroup: ZolaMediaGroupLayout? = nil
    ) -> String {
        var paramObj: [String: Any] = [
            "fileExt": fileExt,
            "height": height,
            "thumb": thumb,
            "thumb_height": height,
            "thumb_width": width,
            "url": url,
            "width": width,
        ]
        if let mediaGroup {
            paramObj.merge(mediaGroup.paramFields) { _, new in new }
        }
        let paramData = (try? JSONSerialization.data(withJSONObject: paramObj, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        return String(decoding: paramData, as: UTF8.self)
    }
}
