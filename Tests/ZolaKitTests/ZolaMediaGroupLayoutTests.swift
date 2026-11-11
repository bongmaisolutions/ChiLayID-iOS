import Foundation
import XCTest
@testable import ZolaKit

/// Album ("media group layout") metadata for multi-photo sends. Offline only: a capture transport
/// answers `/api/message` locally and group sends stay `dryRun: true`.
final class ZolaMediaGroupLayoutTests: XCTestCase {
    private final class CaptureFailover: ZolaNetworkTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var bodies: [Data] = []
        var captured: [Data] { lock.withLock { bodies } }
        func execute(_ request: URLRequest) async throws -> (Int, Data) {
            guard request.url?.path == "/api/message" else {
                XCTFail("Unexpected request \(request.url?.absoluteString ?? "")")
                throw ZolaError.transport("offline")
            }
            let unpacked = try ZolaCrypto.unpackHttpFailoverFrame(request.httpBody ?? Data())
            lock.withLock { bodies.append(unpacked.bodyData) }
            let ack: [String: Any] = [
                "error_code": 0,
                "data": [
                    "offline": ["msg": [] as [Any], "last": unpacked.globalMsgId, "e": 0] as [String: Any],
                    "deliver": ["data": [[
                        "di": Int(unpacked.desId),
                        "msg": [["cmi": unpacked.globalMsgId, "gmi": NSNull(), "err": 0] as [String: Any]],
                    ] as [String: Any]]] as [String: Any],
                ] as [String: Any],
            ]
            return (200, try JSONSerialization.data(withJSONObject: ack))
        }
    }

    private struct NoNetwork: ZolaNetworkTransport {
        func execute(_ request: URLRequest) async throws -> (Int, Data) {
            XCTFail("Dry run must not execute HTTP")
            throw ZolaError.transport("offline")
        }
    }

    private func session() throws -> ZolaSession {
        try ZolaSession(
            uid: 100_000_103,
            sessionKey: "offline-album",
            cryptKey: Data(repeating: 0x11, count: 16),
            zcid: try ZolaCrypto.generateZCID(idfa: "5A0C1E2D-7B3F-4C11-9D2E-0123456789AB",
                                              platform: "iP16Pro_@26.3.1_@NJ", timestampMs: 1_793_600_000_000),
            zcidIsNative: true
        )
    }

    private func json(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    /// Returns the UTF-8 JSON of TLV tag 16 by walking the property list the way `getPropertiesData:` writes it.
    private func tag16JSON(in body: Data) throws -> String? {
        let propCount = Int(body[body.startIndex + 2])
        var pos = 3
        for _ in 0..<propCount {
            let tag = body[body.startIndex + pos]
            pos += 1
            switch tag {
            case 5:
                let len = Int(try body.readInt32LE(at: pos + 4))
                pos += 8 + len
            case 16:
                let len = Int(try body.readInt32LE(at: pos))
                let start = body.startIndex + pos + 4
                return String(decoding: body[start..<(start + len)], as: UTF8.self)
            default:
                XCTFail("Unexpected tag \(tag)")
                return nil
            }
        }
        return nil
    }

    func testLayoutRejectsNonAlbumSlots() {
        XCTAssertNil(ZolaMediaGroupLayout(groupLayoutId: 0, index: 0, total: 3))
        XCTAssertNil(ZolaMediaGroupLayout(groupLayoutId: -5, index: 0, total: 3))
        XCTAssertNil(ZolaMediaGroupLayout(groupLayoutId: 42, index: 0, total: 1))
        XCTAssertNil(ZolaMediaGroupLayout(groupLayoutId: 42, index: 3, total: 3))
        XCTAssertNil(ZolaMediaGroupLayout(groupLayoutId: 42, index: -1, total: 3))
        XCTAssertNil(ZolaMediaGroupLayout(groupLayoutId: 42, index: 0, total: 101))
        XCTAssertNotNil(ZolaMediaGroupLayout(groupLayoutId: 42, index: 2, total: 3))
    }

    func testSinglePhotoParamIsUnchanged() {
        let param = ZolaMediaGroupLayout.photoParamJSON(url: "https://u.zdn.vn/a.jpg", thumb: "https://u.zdn.vn/t.jpg",
                                                        width: 640, height: 480, fileExt: "jpg")
        XCTAssertEqual(param, #"{"fileExt":"jpg","height":480,"thumb":"https://u.zdn.vn/t.jpg","thumb_height":480,"thumb_width":640,"url":"https://u.zdn.vn/a.jpg","width":640}"#)
    }

    func testAlbumParamCarriesNativeGroupKeysAsNumbers() throws {
        let layout = try XCTUnwrap(ZolaMediaGroupLayout(groupLayoutId: 1_793_000_000_123, index: 2, total: 4))
        let param = ZolaMediaGroupLayout.photoParamJSON(url: "https://u.zdn.vn/a.jpg", thumb: "https://u.zdn.vn/a.jpg",
                                                        width: 720, height: 720, fileExt: "jpg", mediaGroup: layout)
        XCTAssertTrue(param.contains(#""group_layout_id":1793000000123"#))
        XCTAssertTrue(param.contains(#""id_in_group":2"#))
        XCTAssertTrue(param.contains(#""is_group_layout":1"#))
        XCTAssertTrue(param.contains(#""total_item_in_group":4"#))
        let object = try json(param)
        XCTAssertEqual((object["group_layout_id"] as? NSNumber)?.int64Value, 1_793_000_000_123)
        XCTAssertEqual(object["url"] as? String, "https://u.zdn.vn/a.jpg")
        XCTAssertEqual(layout.extraDataJSON, #"{"groupMediaMsg":{"groupLayoutId":1793000000123}}"#)
    }

    func testMediaBodyWritesTag16AfterTrackingTag5() throws {
        let extra = #"{"groupMediaMsg":{"groupLayoutId":77}}"#
        let plain = ZolaCrypto.buildMediaMsgBodyData(subCmd: 32, action: "chat.photo", param: "{}")
        let onlyExtra = ZolaCrypto.buildMediaMsgBodyData(subCmd: 32, action: "chat.photo", param: "{}", extraDataJSON: extra)
        var expectedPrefix = Data([32, 0, 1, 16])
        expectedPrefix.appendInt32LE(Int32(extra.utf8.count))
        expectedPrefix.append(Data(extra.utf8))
        XCTAssertEqual(Data(onlyExtra.bodyData.prefix(expectedPrefix.count)), expectedPrefix)
        XCTAssertEqual(Data(onlyExtra.bodyData.dropFirst(expectedPrefix.count)), Data(plain.bodyData.dropFirst(3)))

        let both = ZolaCrypto.buildMediaMsgBodyData(subCmd: 32, action: "chat.photo", param: "{}",
                                                    includeIOSProps: true, trackingIdHex: "fixture", clientIdMs: 9, extraDataJSON: extra)
        XCTAssertEqual(Array(both.bodyData.prefix(4)), [32, 0, 2, 5])
        XCTAssertEqual(try tag16JSON(in: both.bodyData), extra)
        // The existing inbound property walker still accepts the new body.
        XCTAssertNoThrow(try ZolaCrypto.decryptMcryptTextAndPropertiesBody(both.bodyData, cryptKey: Data(repeating: 0x11, count: 16)))
    }

    func testGroupAlbumPhotoUses207WithTag16EvenWithoutTracking() async throws {
        let extra = #"{"groupMediaMsg":{"groupLayoutId":88}}"#
        let wire = try ZolaGroupMediaWire.media(subCmd: 32, href: "u", action: "chat.photo", param: "{}", extraDataJSON: extra)
        XCTAssertEqual(wire.command, 207)
        XCTAssertEqual(try tag16JSON(in: wire.data), extra)

        let client = ZolaClient(session: try ZolaSession(uid: 123_456_789, sessionKey: "offline-group-album",
                                                         zcid: "offline-native", zcidIsNative: true),
                                transport: NoNetwork())
        let layout = try XCTUnwrap(ZolaMediaGroupLayout(groupLayoutId: 1_793_000_000_000, index: 0, total: 3))
        let receipt = try await client.sendPhotoGroup(gid: 987, photoUrl: "https://example.invalid/a.jpg",
                                                      dryRun: true, mediaGroup: layout)
        XCTAssertEqual(receipt.cmd, 207)
        XCTAssertFalse(receipt.sent)
    }

    func testOneToOneAlbumSendsShareOneLayoutIdWithSequentialIndexes() async throws {
        let transport = CaptureFailover()
        let client = ZolaClient(session: try session(), transport: transport)
        let albumId: Int64 = 1_793_000_000_456
        for index in 0..<3 {
            let layout = try XCTUnwrap(ZolaMediaGroupLayout(groupLayoutId: albumId, index: index, total: 3))
            let receipt = try await client.sendPhoto1To1(to: 100_000_102, photoUrl: "https://f10.zdn.vn/p\(index).jpg",
                                                          width: 640, height: 480, dryRun: false,
                                                          clientIdMs: albumId + Int64(index), mediaGroup: layout)
            XCTAssertTrue(receipt.ok)
        }
        // A photo sent on its own keeps the old body: no group keys, no tag 16.
        _ = try await client.sendPhoto1To1(to: 100_000_102, photoUrl: "https://f10.zdn.vn/solo.jpg",
                                           dryRun: false, clientIdMs: albumId + 10)
        let bodies = transport.captured
        XCTAssertEqual(bodies.count, 4)
        for (index, body) in bodies.prefix(3).enumerated() {
            let text = String(decoding: body, as: UTF8.self)
            XCTAssertTrue(text.contains(#""group_layout_id":1793000000456"#))
            XCTAssertTrue(text.contains(#""id_in_group":\#(index)"#))
            XCTAssertTrue(text.contains(#""total_item_in_group":3"#))
            XCTAssertTrue(text.contains(#""is_group_layout":1"#))
            XCTAssertEqual(try tag16JSON(in: body), #"{"groupMediaMsg":{"groupLayoutId":1793000000456}}"#)
        }
        let solo = String(decoding: bodies[3], as: UTF8.self)
        XCTAssertFalse(solo.contains("group_layout_id"))
        XCTAssertNil(try tag16JSON(in: bodies[3]))
    }
}
