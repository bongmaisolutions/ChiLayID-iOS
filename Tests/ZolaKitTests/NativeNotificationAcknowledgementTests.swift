import XCTest
@testable import ZolaKit

final class NativeNotificationAcknowledgementTests: XCTestCase {
    private func frame(_ json: String, command: Int16 = 600) -> ZolaChatElementFrame? {
        ZolaNativeNotificationAcknowledgement.frame(command: command, decodedBody: Data(json.utf8), srcId: 42, seqId: 9)
    }

    func testExact64BitIDsDeduplicateWithoutCountPrefix() throws {
        let packet = try XCTUnwrap(frame(#"[{"id":"9007199254740993","type":188,"item":[{"groupId":777}]},{"id":9223372036854775807,"type":188,"item":[{"groupId":778}]},{"id":"9007199254740993","type":188,"item":[{"groupId":779}]}]"#))
        let decoded = try ZolaCrypto.unpackChatElementFrame(packet.payload)
        XCTAssertEqual(decoded.bodyData, Data([1,0,0,0,0,0,0x20,0, 0xff,0xff,0xff,0xff,0xff,0xff,0xff,0x7f]))
        XCTAssertEqual(decoded.cmd, 601)
        XCTAssertEqual(decoded.seqId, 9)
        XCTAssertEqual(decoded.srcId, 42)
        XCTAssertEqual(decoded.msgType, 1)
        XCTAssertEqual(decoded.needAck, 0)
    }

    func testMalformedOrUnsupportedBatchesAreNeverPartiallyAcknowledged() {
        let invalid = ["null", "{}", "[]", "bad-json",
            #"[{"id":"8","type":188,"item":[]}]"#,
            #"[{"id":"8","type":188,"item":[{"groupId":777},{}]}]"#,
            #"[{"id":"8","type":188,"item":[{"groupId":777}]},{"id":"9","type":189,"item":[{"groupId":777}]}]"#,
            #"[{"id":"8","type":188,"item":[{"groupId":777}]},false]"#]
        for json in invalid { XCTAssertNil(frame(json), json) }
        for id in ["true", "0", "-1", "1.5", "\"9223372036854775808\"", "\"+12\"", "\"1a\"", "\" 12\""] {
            XCTAssertNil(frame("[{\"id\":\(id),\"type\":188,\"item\":[{\"groupId\":777}]}]"), id)
        }
    }

    func testOnly600CanProduceAcknowledgement() {
        let json = #"[{"id":"8","type":188,"item":[{"groupId":777}]}]"#
        for command: Int16 in [599,601,602,603,604,605] { XCTAssertNil(frame(json, command: command)) }
        XCTAssertNil(ZolaNativeNotificationAcknowledgement.frame(command: 600, decodedBody: Data(json.utf8), srcId: 0, seqId: 1))
    }

    func testNotificationAndAggregateItemBoundsFailClosed() {
        let notification = #"{"id":"8","type":188,"item":[{"groupId":777}]}"#
        XCTAssertNil(frame("[" + Array(repeating: notification, count: 257).joined(separator: ",") + "]"))
        let items = Array(repeating: #"{"groupId":777}"#, count: 129).joined(separator: ",")
        XCTAssertNil(frame("[{\"id\":8,\"type\":188,\"item\":[\(items)]},{\"id\":9,\"type\":188,\"item\":[\(items)]}]"))
        XCTAssertNil(ZolaNativeNotificationAcknowledgement.frame(command: 600, decodedBody: Data(repeating: 32, count: 1024 * 1024 + 1), srcId: 42, seqId: 1))
    }
}
