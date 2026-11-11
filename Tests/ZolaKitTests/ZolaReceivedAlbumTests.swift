import Foundation
import XCTest
@testable import ZolaKit

final class ZolaReceivedAlbumTests: XCTestCase {
    func testPhotoMetadataDictionaryAndJSONStringSurviveCacheRoundtrip() throws {
        let fields: [String: Any] = ["is_group_layout": 1, "group_layout_id": 9876543210123 as Int64,
                                     "id_in_group": 1, "total_item_in_group": 3]
        let expected = ZolaMediaGroupLayout(groupLayoutId: 9876543210123, index: 1, total: 3)
        for params in [fields, String(decoding: try JSONSerialization.data(withJSONObject: fields), as: UTF8.self)] as [Any] {
            let a = ZolaAttachment.fromRaw(msgType: "chat.photo", attach: ["params": params, "href": "https://example.test/p.jpg"])
            XCTAssertEqual(a.mediaGroup, expected)
            XCTAssertEqual(try JSONDecoder().decode(ZolaAttachment.self, from: JSONEncoder().encode(a)).mediaGroup, expected)
        }
        let old = ZolaAttachment(kind: "photo", url: "https://example.test/old.jpg")
        var oldJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        oldJSON.removeValue(forKey: "mediaGroup")
        XCTAssertNil(try JSONDecoder().decode(ZolaAttachment.self, from: JSONSerialization.data(withJSONObject: oldJSON)).mediaGroup)
    }

    func testInvalidMetadataAndNonPhotosDoNotBecomeAlbums() {
        let valid: [String: Any] = ["is_group_layout": 1, "group_layout_id": 42, "id_in_group": 0, "total_item_in_group": 3]
        for (key, value) in [("is_group_layout", 0), ("group_layout_id", 0), ("id_in_group", -1), ("id_in_group", 3), ("total_item_in_group", 101)] {
            var p = valid; p[key] = value
            XCTAssertNil(ZolaAttachment.fromRaw(msgType: "chat.photo", attach: ["params": p]).mediaGroup)
        }
        for value: Any in [true, "oops", 0.5] {
            var p = valid; p["id_in_group"] = value
            XCTAssertNil(ZolaAttachment.fromRaw(msgType: "chat.photo", attach: ["params": p]).mediaGroup)
        }
        XCTAssertNil(ZolaAttachment.fromRaw(msgType: "chat.video.msg", attach: ["params": valid]).mediaGroup)
    }
}
