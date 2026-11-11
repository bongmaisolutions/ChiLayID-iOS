import XCTest
@testable import ZolaKit

/// Static IPA-derived fixtures, not captured live traffic.
final class ZolaNativeRecallTests: XCTestCase {
    private func client() throws -> ZolaClient {
        ZolaClient(session: try ZolaSession(uid: 42, sessionKey: "offline-recall", zcid: "native-fixture", zcidIsNative: true))
    }

    private func message(id: Int64 = 0x1112131415161718, cli: Int64 = 0x0102030405060708,
                         group: Bool = false, sender: Int64 = 42, isSelf: Bool = true,
                         kind: String = "text", source: String = "socket", mcrypt: Int = 0) -> ZolaMessage {
        .init(id: id, cliMsgId: cli, threadId: 100, isGroup: group, senderId: sender,
              toId: 100, tsMs: 1000, kind: kind, text: "Original", isSelf: isSelf, mcrypt: mcrypt, source: source)
    }

    func testRecallDefaultsToValidationOnlyWithoutSocketKeys() async throws {
        // Synthetic native session has no keyset/endpoints and cannot open a live socket.
        // Omitting dryRun must still validate and succeed for direct and group recall.
        let client = try client()
        for group in [false, true] {
            let accepted = try await client.recallNative(message: message(group: group), threadId: 100,
                                                         type: group ? .group : .user)
            XCTAssertTrue(accepted)
        }
        do {
            _ = try await client.recallNative(message: message(sender: 7), threadId: 100)
            XCTFail("Default dry-run must still reject a message belonging to another sender")
        } catch let error as ZolaError {
            guard case .invalidArgument = error else { throw error }
        }
    }

    func testNativeRecallBodyUsesOriginalIDsAndNative114Or204Header() async throws {
        let client = try client()
        for group in [false, true] {
            let frame = try await client.buildRecallSocketFrame(message: message(group: group), threadId: 100,
                                                                type: group ? .group : .user, seqId: 73)
            let decoded = try ZolaCrypto.unpackChatElementFrame(frame.payload)
            XCTAssertEqual(decoded.bodyData, Data([
                100, 0, 0, 0, 8, 7, 6, 5, 4, 3, 2, 1, 24, 23, 22, 21, 20, 19, 18, 17,
                1, 0, 0, 0, 42, 0, 0, 0
            ]))
            XCTAssertEqual(decoded.cmd, group ? 204 : 114)
            XCTAssertEqual(decoded.subCmd, 2)
            XCTAssertEqual(decoded.msgType, 2)
            XCTAssertEqual(decoded.srcType, 3)
            XCTAssertEqual(decoded.desType, 3)
            XCTAssertEqual(decoded.desId, 100)
            XCTAssertEqual(decoded.seqId, 73)
            XCTAssertEqual(decoded.globalMsgId, 0)
        }
    }

    func testRecallRejectsForeignPendingFailedEncryptedAndMissingIdentifiersBeforeNetwork() async throws {
        let client = try client()
        let invalid = [message(sender: 7), message(isSelf: false), message(kind: "recalled"), message(kind: "call"),
                       message(source: "sending"), message(source: "send-failed"), message(source: "send-unconfirmed"),
                       message(mcrypt: 2), message(id: 0), message(cli: 0)]
        for msg in invalid {
            do {
                _ = try await client.buildRecallSocketFrame(message: msg, threadId: 100)
                XCTFail("Must reject \(msg.source)/\(msg.kind) before opening a socket")
            } catch { }
        }
        do {
            _ = try await client.buildRecallSocketFrame(message: message(), threadId: 101)
            XCTFail("Must reject cross-thread target")
        } catch { }
    }

    func testMediaRecallCarriesOriginalWireMessageType() async throws {
        let client = try client()
        for (kind, expected) in [("text", 1), ("photo", 32), ("voice", 31), ("video", 44), ("file", 46), ("sticker", 36)] {
            let frame = try await client.buildRecallSocketFrame(message: message(kind: kind), threadId: 100)
            let parsed = try ZolaCrypto.unpackChatElementFrame(frame.payload)
            XCTAssertEqual(try parsed.bodyData.readInt32LE(at: 20), Int32(expected))
        }
    }

    func testSessionEncryptedTextIsStillOrdinaryNativeRecall() async throws {
        let client = try client()
        let frame = try await client.buildRecallSocketFrame(message: message(mcrypt: 1), threadId: 100)
        XCTAssertEqual(try ZolaCrypto.unpackChatElementFrame(frame.payload).cmd, 114)
    }

    #if canImport(Network)
    private func ack(body: String = #"{"error_code":0}"#, cmd: Int16 = 114,
                     seq: Int32 = 73, type: Int8 = 3, ret: Int32 = 0) throws -> ZolaUnpackedChatElement {
        try ZolaCrypto.unpackChatElementFrame(ZolaCrypto.packServerChatElementFrame(
            bodyData: Data(body.utf8), gzipBody: true, srcId: 42, msgType: type,
            cmd: cmd, subCmd: 2, seqId: seq, retCode: ret).payload)
    }

    func testRecallRequiresStructuredSuccessAndCorrelatedCommandAndSequence() async throws {
        let client = try client()
        try await client.validateRecallSocketResponse(ack(), expectedCommand: 114, seqId: 73)
        let invalid = [try ack(body: ""), try ack(body: "{}"), try ack(body: "not-json"),
                       try ack(body: #"{"error_code":false}"#), try ack(body: #"{"error_code":-105}"#),
                       try ack(cmd: 204), try ack(seq: 74), try ack(type: 1), try ack(ret: -7)]
        for value in invalid {
            do {
                try await client.validateRecallSocketResponse(value, expectedCommand: 114, seqId: 73)
                XCTFail("Receipt/error/unrelated response must never report recalled")
            } catch { }
        }
    }

    func testRecallWaiterRequiresBodyWithoutChangingNormalMessageAckPolicy() throws {
        let receipt = try ack(body: "", type: 4)
        let response = try ack()
        XCTAssertTrue(ZolaVoipSocketSession.resolvesSeqWaiter(receipt))
        XCTAssertFalse(ZolaVoipSocketSession.resolvesSeqWaiter(response))
        XCTAssertFalse(ZolaVoipSocketSession.resolvesSeqWaiter(receipt, requiresResponseBody: true))
        XCTAssertTrue(ZolaVoipSocketSession.resolvesSeqWaiter(response, requiresResponseBody: true))
        XCTAssertTrue(ZolaVoipSocketSession.resolvesSeqWaiter(try ack(body: "", ret: -7), requiresResponseBody: true))
        XCTAssertFalse(ZolaVoipSocketSession.resolvesSeqWaiter(try ack(type: 1), requiresResponseBody: true))
    }
    #endif
}
