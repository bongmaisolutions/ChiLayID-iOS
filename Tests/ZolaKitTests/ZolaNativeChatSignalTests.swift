import XCTest
import Foundation
@testable import ZolaKit

/// Literal fixtures derived from IPA26.10.02; these are not live packet captures.
final class ZolaNativeChatSignalTests: XCTestCase {
    private let own: Int64 = 100000103
    private let peer: Int64 = 100000102
    private func element(_ command: Int16, _ json: String, sub: Int8 = 0, source: Int32 = 100000102,
                         messageType: Int8 = 1, error: Int32 = 0) throws -> ZolaUnpackedChatElement {
        try ZolaCrypto.unpackChatElementFrame(ZolaCrypto.packServerChatElementFrame(
            bodyData: Data(json.utf8), srcId: source, msgType: messageType, cmd: command,
            subCmd: sub, seqId: 77, retCode: error).payload)
    }
    func testDeliveryRecoversGlobalIDAndSeenIsMonotonic() throws {
        let batch = try XCTUnwrap(ZolaNativeChatSignals.parse(try element(102,
            #"{"data":[{"di":100000103,"msg":[{"sid":100000102,"cmi":1001,"gmi":9001}]}],"more":0}"#), accountUid: own))
        let delivery = try XCTUnwrap(batch.deliveries.first)
        XCTAssertEqual(delivery.threadId, peer)
        XCTAssertEqual(delivery.actorId, peer)
        XCTAssertEqual(delivery.cliMsgId, 1001)
        XCTAssertEqual(delivery.globalMsgId, 9001)
        XCTAssertEqual(delivery.status, .delivered)
        let pending = ZolaMessage(id: 1001, cliMsgId: 1001, threadId: peer, senderId: own,
            toId: peer, tsMs: 1001, text: "original", isSelf: true, source: "failover", reactions: ["❤️"])
        let healed = try XCTUnwrap(delivery.reconciling(pending, accountUid: own))
        XCTAssertEqual(healed.id, 9001)
        XCTAssertEqual(healed.text, "original")
        XCTAssertEqual(healed.reactions, ["❤️"])
        XCTAssertNil(delivery.reconciling(pending, accountUid: peer))
        XCTAssertEqual(ZolaDeliveryStatus.seen.merging(.delivered), .seen)
        XCTAssertEqual(ZolaDeliveryStatus.delivered.merging(.seen), .seen)
        let ack = try XCTUnwrap(batch.acknowledgement(srcId: Int32(own), seqId: 88))
        let unpacked = try ZolaCrypto.unpackChatElementFrame(ack.payload)
        XCTAssertEqual(unpacked.cmd, 103)
        XCTAssertEqual(unpacked.subCmd, 3)
        let ackJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: unpacked.decodedBodyData) as? [String: Any])
        XCTAssertEqual(ackJSON.keys.sorted(), ["data"])
    }
    func testDirectAndGroupSeenCommandsAndEmbeddedSeenFlag() throws {
        for command: Int16 in [102, 104, 107, 202, 203, 208, 209, 212, 213] {
            let group = command >= 200
            let json = group
                ? #"{"data":[{"di":777,"seen":1,"msg":[{"sid":100000102,"cmi":1001,"gmi":9001}]}]}"#
                : #"{"data":[{"di":100000103,"seen":1,"msg":[{"sid":100000102,"cmi":1001,"gmi":9001}]}]}"#
            let batch = try XCTUnwrap(ZolaNativeChatSignals.parse(try element(command, json), accountUid: own))
            let update = try XCTUnwrap(batch.deliveries.first)
            XCTAssertEqual(update.status, .seen)
            XCTAssertEqual(update.threadId, group ? 777 : peer)
            XCTAssertEqual(update.isGroup, group)
            let ack = try ZolaCrypto.unpackChatElementFrame(XCTUnwrap(batch.acknowledgement(srcId: Int32(own), seqId: 1)).payload)
            let seenQueue = [Int16(107), 203, 209, 213].contains(command)
            XCTAssertEqual(ack.cmd, seenQueue ? (group ? 211 : 108) : (group ? 210 : 103))
            XCTAssertEqual(ack.subCmd, seenQueue ? 1 : 3)
        }
    }
    func testReceiptsErrorsMalformedAndForeignDirectThreadCannotMutateMessagesOrACKLoop() throws {
        let good = #"{"data":[{"di":100000103,"msg":[{"sid":100000102,"cmi":1001,"gmi":9001}]}]}"#
        for command: Int16 in [103, 108, 117, 210, 211] {
            XCTAssertNil(ZolaNativeChatSignals.parse(try element(command, good), accountUid: own))
        }
        XCTAssertNil(ZolaNativeChatSignals.parse(try element(102, good, messageType: 4), accountUid: own))
        XCTAssertNil(ZolaNativeChatSignals.parse(try element(102, good, messageType: 3, error: -1), accountUid: own))
        for malformed in ["", "{}", #"{"error_code":102,"data":[]}"#,
            #"{"data":[{"di":777,"msg":[{"sid":100000102,"cmi":1001,"gmi":9001}]}]}"#,
            #"{"data":[{"di":100000103,"msg":[{"sid":true,"cmi":1001,"gmi":9001}]}]}"#,
            #"{"data":[{"di":100000103,"msg":[{"sid":100000102,"cmi":1001,"gmi":null}]}]}"#] {
            XCTAssertNil(ZolaNativeChatSignals.parse(try element(102, malformed), accountUid: own), malformed)
        }
    }
    func testTypingDirectAndGroupUsesNativeSenderFields() throws {
        let direct = try XCTUnwrap(ZolaNativeChatSignals.parse(try element(106, #"{"isPC":1}"#, sub: 1), accountUid: own)?.typing)
        XCTAssertEqual(direct.threadId, peer)
        XCTAssertEqual(direct.actorId, peer)
        XCTAssertTrue(direct.isFromPC)
        let group = try XCTUnwrap(ZolaNativeChatSignals.parse(try element(206, #"{"uid":100000102,"isPC":0}"#, sub: 1, source: 777), accountUid: own)?.typing)
        XCTAssertEqual(group.threadId, 777)
        XCTAssertEqual(group.actorId, peer)
        XCTAssertTrue(group.isGroup)
        XCTAssertNil(ZolaNativeChatSignals.parse(try element(206, "{}", sub: 1, source: 777), accountUid: own))
        XCTAssertNil(ZolaNativeChatSignals.parse(try element(106, "{}", sub: 1, source: Int32(own)), accountUid: own))
    }
    func testTypingLiteralWireAndSeenNeverAcknowledgesOwnOrUnconfirmedMessage() throws {
        let typing = try ZolaNativeChatSignals.typingFrame(accountUid: own, threadId: peer, isGroup: false, timestampMs: 123456, seqId: 42)
        let wire = try ZolaCrypto.unpackChatElementFrame(typing.payload)
        XCTAssertEqual(wire.cmd, 106)
        XCTAssertEqual(wire.subCmd, 1)
        XCTAssertEqual(wire.msgType, 2)
        XCTAssertEqual(wire.desId, Int32(peer))
        XCTAssertEqual(wire.desType, 3)
        XCTAssertEqual(wire.globalMsgId, 123456)
        XCTAssertEqual(wire.decodedBodyData, Data([0]))
        let incoming = ZolaMessage(id: 9001, cliMsgId: 1001, threadId: peer, senderId: peer,
            toId: own, tsMs: 1234, text: "native", isSelf: false)
        let seen = try ZolaNativeChatSignals.seenFrame(accountUid: own, threadId: peer, messages: [incoming], seqId: 5)
        let seenWire = try ZolaCrypto.unpackChatElementFrame(seen.payload)
        XCTAssertEqual(seenWire.cmd, 102)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: seenWire.decodedBodyData) as? [String: Any])
        XCTAssertEqual(json["seen"] as? Int, 1)
        let item = try XCTUnwrap((json["data"] as? [[String: Any]])?.first)
        XCTAssertEqual(item["gmi"] as? Int64, 9001)
        XCTAssertEqual(item["si"] as? Int64, peer)
        XCTAssertEqual(item["di"] as? Int64, own)
        XCTAssertThrowsError(try ZolaNativeChatSignals.seenFrame(accountUid: peer, threadId: peer, messages: [incoming], seqId: 1))
        XCTAssertThrowsError(try ZolaNativeChatSignals.typingFrame(accountUid: own, threadId: -1, isGroup: false, timestampMs: 1, seqId: 1))
    }
    func testDirectTypingWithoutJSONUsesNativeHeaderAndReceiptsPaginateOnTheirOwnQueues() throws {
        let typing = try XCTUnwrap(ZolaNativeChatSignals.parse(try element(106, "\u{0}", sub: 1), accountUid: own)?.typing)
        XCTAssertEqual(typing.actorId, peer)
        for (command, next): (Int16, Int16) in [(102,104),(104,104),(107,1996),(1996,1996),(202,212),(203,213)] {
            let isGroup = command == 202 || command == 203
            let json = isGroup
                ? #"{"more":1,"data":[{"di":777,"msg":[{"sid":100000102,"cmi":1001,"gmi":9001}]}]}"#
                : #"{"more":1,"data":[{"di":100000103,"msg":[{"sid":100000102,"cmi":1001,"gmi":9001}]}]}"#
            let batch = try XCTUnwrap(ZolaNativeChatSignals.parse(try element(command, json), accountUid: own))
            let frame = try ZolaCrypto.unpackChatElementFrame(XCTUnwrap(batch.nextPage(srcId: Int32(own), seqId: 9)).payload)
            XCTAssertEqual(frame.cmd, next)
            XCTAssertEqual(frame.subCmd, 0)
            XCTAssertEqual(frame.msgType, 1)
            XCTAssertTrue(frame.decodedBodyData.isEmpty)
        }
    }
    func testPiggybackReceiptKeepsEachClientIDAndSkipsNullOrRejectedGlobalID() throws {
        let body = Data(#"{"error_code":0,"data":{"deliver":{"data":[{"di":100000102,"msg":[{"cmi":101,"gmi":901},{"cmi":102,"gmi":null,"err":0},{"cmi":103,"gmi":903,"err":-1}]}]}}}"#.utf8)
        let updates = ZolaNativeChatSignals.httpDeliveries(body, accountUid: own)
        XCTAssertEqual(updates.map(\.cliMsgId), [101])
        XCTAssertEqual(updates.map(\.globalMsgId), [901])
        XCTAssertEqual(updates.map(\.threadId), [peer])
    }

}
