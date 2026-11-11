import XCTest
@testable import ZolaKit

final class ZolaNativePinBoardTests: XCTestCase {
    private func hex(_ raw: String) -> Data {
        Data(stride(from: 0, to: raw.count, by: 2).map { offset in
            let start = raw.index(raw.startIndex, offsetBy: offset)
            return UInt8(raw[start..<raw.index(start, offsetBy: 2)], radix: 16)!
        })
    }

    func testReadBodiesMatchNativeGetRequestDataForUserAndGroup() throws {
        let expected = hex("0232968e0f00000000010040e201000700000000000000")
        for group in [false, true] {
            let frame = try ZolaNativePinBoard.readFrame(threadId: 123456, isGroup: group, version: 7, srcId: 1, seqId: 8)
            let decoded = try ZolaCrypto.unpackChatElementFrame(frame.payload)
            XCTAssertEqual(decoded.bodyData, expected)
            XCTAssertEqual(decoded.cmd, group ? 1703 : 1708)
            XCTAssertEqual(decoded.seqId, 8)
        }
    }

    func testUnpinUsesBoardIDNotMessageIDAndMatchesNativeBytes() throws {
        let frame = try ZolaNativePinBoard.unpinUserFrame(threadId: 123456, boardId: 987654, version: 7, srcId: 1, seqId: 8)
        let decoded = try ZolaCrypto.unpackChatElementFrame(frame.payload)
        XCTAssertEqual(decoded.cmd, 1706)
        XCTAssertEqual(decoded.bodyData, hex("0232968e0f00000000010040e2010006120f0000000000020000000700000000000000"))
        XCTAssertThrowsError(try ZolaNativePinBoard.unpinUserFrame(threadId: 123456, boardId: 0, version: 7, srcId: 1, seqId: 8))
    }

    func testBoardParserKeepsServerIdentityAndRejectsMissingSnapshot() throws {
        let response: [String: Any] = ["boardVersion": 7, "maxBoardItems": 10, "items": [
            ["id": "987654", "type": 2, "isPin": 1,
             "properties": ["0": #"{"global_msg_id":"900","client_msg_id":"120","title":"fixture","senderUid":"42"}"#]],
            ["id": "222", "type": 3, "isPin": 1, "properties": [:]]]]
        let board = try ZolaNativePinBoard.parse(response, threadId: 123456, isGroup: false)
        XCTAssertEqual(board.messages.count, 1)
        XCTAssertEqual(board.messages.first?.id, 987654)
        XCTAssertEqual(board.messages.first?.messageId, 900)
        XCTAssertEqual(board.messages.first?.cliMsgId, 120)
        XCTAssertTrue(board.messages.first?.isPinned == true)
        XCTAssertThrowsError(try ZolaNativePinBoard.parse([:], threadId: 1, isGroup: false))
        XCTAssertEqual(try ZolaNativePinBoard.parse(["boardVersion": 8, "items": []], threadId: 1, isGroup: false).messages, [])
    }

    func testAuthoritativeBoardMembershipIsPinnedEvenWhenLegacyIsPinIsZero() throws {
        // Live direct read1708: official native header pinned this exact type2 entry with isPin0.
        // Native isPinningTopicWithIdentity checks boardIdentities membership, not legacy isPin.
        let board = try ZolaNativePinBoard.parse(["boardVersion": 7, "maxBoardItems": 3, "items": [
            ["id": 123, "type": 2, "isPin": 0,
             "properties": ["0": ["global_msg_id": "900", "client_msg_id": "120", "title": "fixture"]]]
        ]], threadId: 42, isGroup: false)
        XCTAssertEqual(board.messages.count, 1)
        XCTAssertTrue(try XCTUnwrap(board.messages.first).isPinned)
    }

    func testPinPropertiesUseNativeTaggedLayoutAndOriginalMessageIDs() throws {
        let message = ZolaMessage(id: 900, cliMsgId: 120, threadId: 123456, senderId: 42, toId: 1,
            tsMs: 1, kind: "text", text: "offline pin fixture", isSelf: false, source: "fixture")
        let frame = try ZolaNativePinBoard.pinUserFrame(message: message, version: 7, srcId: 1, seqId: 8)
        let decoded = try ZolaCrypto.unpackChatElementFrame(frame.payload)
        XCTAssertEqual(decoded.cmd, 1705)
        let data = decoded.bodyData
        XCTAssertEqual(data[23], 6)
        var offset = 24
        var properties: [UInt8: [String: Any]] = [:]
        for _ in 0..<6 {
            let tag = data[offset]; offset += 1
            let size = Int(try data.readUInt32LE(at: offset)); offset += 4
            properties[tag] = try JSONSerialization.jsonObject(with: data.subdata(in: offset..<(offset + size))) as? [String: Any]
            offset += size
        }
        XCTAssertEqual(offset, data.count)
        XCTAssertEqual(properties[0]?["msg_type"] as? Int, 0)
        XCTAssertEqual(properties[0]?["global_msg_id"] as? String, "900")
        XCTAssertEqual(properties[0]?["client_msg_id"] as? String, "120")
        XCTAssertEqual(properties[5]?["needPin"] as? Int, 1)
        XCTAssertEqual(properties[6]?["topicType"] as? Int, 2)
        XCTAssertEqual(Set(properties.keys), [0, 1, 3, 4, 5, 6])
    }
    func testGroupUnpinUsesDistinctCommandAndOmitsPersonalBoardVersion() throws {
        let frame = try ZolaNativePinBoard.unpinGroupFrame(threadId: 123456, boardId: 987654, srcId: 1, seqId: 8)
        let decoded = try ZolaCrypto.unpackChatElementFrame(frame.payload)
        XCTAssertEqual(decoded.cmd, 241)
        XCTAssertEqual(decoded.subCmd, 3)
        XCTAssertEqual(decoded.bodyData, hex("0232968e0f00000000010040e2010006120f000000000002000000"))
    }

    func testGroupPinUses1752Sub2AndNativeMediaTypeNotQuoteCode() throws {
        let message = ZolaMessage(id: 900, cliMsgId: 120, threadId: 123456, isGroup: true, senderId: 42, toId: 1,
            tsMs: 1, kind: "photo", text: "fixture", isSelf: false, source: "fixture")
        let decoded = try ZolaCrypto.unpackChatElementFrame(ZolaNativePinBoard.pinGroupFrame(message: message, srcId: 1, seqId: 8).payload)
        XCTAssertEqual(decoded.cmd, 1752)
        XCTAssertEqual(decoded.subCmd, 2)
        XCTAssertEqual(decoded.bodyData[15], 6) // no personal boardVersion
        let size = Int(try decoded.bodyData.readUInt32LE(at: 17))
        let attachment = try JSONSerialization.jsonObject(with: decoded.bodyData.subdata(in: 21..<(21 + size))) as? [String: Any]
        XCTAssertEqual(attachment?["msg_type"] as? Int, 11)
    }

    func testAcknowledgementRejectsWrongRequestAndFalseBooleanSuccess() throws {
        func response(_ json: String, seq: Int32 = 8) throws -> ZolaUnpackedChatElement {
            try ZolaCrypto.unpackChatElementFrame(ZolaCrypto.packChatElementFrame(bodyData: Data(json.utf8), srcId: 1,
                srcType: 3, msgType: 1, cmd: 1705, subCmd: 0, seqId: seq, needAck: 1).payload)
        }
        try ZolaNativePinBoard.validateAcknowledgement(response(#"{"error_code":0}"#), command: 1705, sequence: 8)
        XCTAssertThrowsError(try ZolaNativePinBoard.validateAcknowledgement(response(#"{"error_code":false}"#), command: 1705, sequence: 8))
        XCTAssertThrowsError(try ZolaNativePinBoard.validateAcknowledgement(response(#"{"error_code":0}"#, seq: 7), command: 1705, sequence: 8))
        XCTAssertThrowsError(try ZolaNativePinBoard.validateAcknowledgement(response(#"{"error_code":0}"#), command: 1706, sequence: 8))
    }

}
