import Foundation
import XCTest
@testable import ZolaKit

final class ZolaGroupMediaTests: XCTestCase {
    private func client(expired: Bool = false) throws -> ZolaClient {
        var session = try ZolaSession(uid: 123_456_789, sessionKey: "offline-group-media", zcid: "offline-native", zcidIsNative: true)
        if expired { session.markExpired(code: 102, reason: "offline test") }
        return ZolaClient(session: session, transport: NoNetwork())
    }
    private struct NoNetwork: ZolaNetworkTransport {
        func execute(_ request: URLRequest) async throws -> (Int, Data) {
            XCTFail("Group-media dry run must not execute HTTP")
            throw ZolaError.transport("offline")
        }
    }
    private func bytes(_ hex: String) -> Data {
        Data(hex.split(separator: " ").map { UInt8($0, radix: 16)! })
    }

    func testNativePlainGroupMediaHasNoTLVPrefixAndUses201() throws {
        for sub: Int8 in [31, 32, 44, 46] {
            let body = try ZolaGroupMediaWire.media(subCmd: sub, href: "u", thumb: "t", title: "n", description: "d", action: "a", param: "{}")
            XCTAssertEqual(body.command, 201)
            // Native createMesageData: fields are UInt16LE length + bytes; childnum is Int16LE.
            XCTAssertEqual(body.data, bytes("01 00 6e 01 00 64 01 00 75 01 00 74 00 00 01 00 61 02 00 7b 7d"))
            let frame = try body.frame(uid: 123_456_789, gid: 987_654_321, seqId: 7, clientIdMs: 1_700_000_000_000)
            let decoded = try ZolaCrypto.unpackChatElementFrame(frame.payload)
            XCTAssertEqual(decoded.cmd, 201)
            XCTAssertEqual(decoded.subCmd, sub)
            XCTAssertEqual(decoded.msgType, 2)
            XCTAssertEqual(decoded.srcType, 3)
            XCTAssertEqual(decoded.desType, 4)
            XCTAssertEqual(decoded.desId, 987_654_321)
            XCTAssertEqual(decoded.globalMsgId, 1_700_000_000_000)
            XCTAssertEqual(decoded.needAck, 1)
            XCTAssertEqual(decoded.bodyData, body.data)
        }
    }
    func testNativePropertyGroupMediaUses207AndRetainsTLV() throws {
        let body = try ZolaGroupMediaWire.media(subCmd: 32, href: "u", includeIOSProps: true, clientIdMs: 42, trackingIdHex: "fixture")
        XCTAssertEqual(body.command, 207)
        XCTAssertEqual(Array(body.data.prefix(4)), [32, 0, 1, 5])
        XCTAssertTrue(String(decoding: body.data, as: UTF8.self).contains("fixture"))
    }
    func testNativeStickerBodyAndPropertyEnvelope() throws {
        let plain = try ZolaGroupMediaWire.sticker(stickerId: 1234, cateId: 10425, stickerType: 7)
        XCTAssertEqual(plain.command, 201)
        XCTAssertEqual(plain.data, bytes("d2 04 00 00 b9 28 00 00 07 00 00 00 00"))
        let classic = try ZolaGroupMediaWire.sticker(stickerId: 1, cateId: 0, stickerType: 2)
        XCTAssertEqual(classic.data, bytes("01 00 00 00 00 00 00 00 02 00 00 00 00"))
        let props = try ZolaGroupMediaWire.sticker(stickerId: 1234, cateId: 10425, stickerType: 7, includeIOSProps: true, trackingIdHex: "fixture")
        XCTAssertEqual(props.command, 207)
        XCTAssertEqual(Array(props.data.prefix(4)), [36, 0, 1, 5])
        XCTAssertTrue(props.data.suffix(13).elementsEqual(plain.data))
    }
    func testGroupReactionUsesDedicated1785EvenWithoutProperties() throws {
        let body = try ZolaGroupMediaWire.reaction(parameterJSON: #"{"rIcon":"/-heart"}"#)
        XCTAssertEqual(body.command, 1785)
        XCTAssertEqual(body.subCommand, 55)
        XCTAssertEqual(Array(body.data.prefix(3)), [55, 0, 0])
        let decoded = try ZolaCrypto.unpackChatElementFrame(body.frame(uid: 123, gid: 987, seqId: 3, clientIdMs: 42).payload)
        XCTAssertEqual(decoded.cmd, 1785)
        XCTAssertEqual(decoded.desType, 4)
    }
    func testUnverifiedSubcommandsAndInvalidDestinationsFailClosed() throws {
        for sub: Int8 in [1, 36, 37, 38, 49, 55] {
            XCTAssertThrowsError(try ZolaGroupMediaWire.media(subCmd: sub))
        }
        XCTAssertThrowsError(try ZolaGroupMediaWire.sticker(stickerId: 0, cateId: 1))
        let body = try ZolaGroupMediaWire.media(subCmd: 31)
        XCTAssertThrowsError(try body.frame(uid: 123, gid: 0, seqId: 1, clientIdMs: 42))
        XCTAssertThrowsError(try body.frame(uid: 123, gid: Int64(UInt32.max) + 1, seqId: 1, clientIdMs: 42))
    }
    func testDryRunPublicMediaMethodsNeverUploadOrOpenSocket() async throws {
        let c = try client()
        let receipts = [
            try await c.sendMediaGroup(gid: 987, subCmd: 31, href: "https://example.invalid/a.aac"),
            try await c.sendStickerGroup(gid: 987, stickerId: 1234),
            try await c.sendPhotoGroup(gid: 987, photoUrl: "https://example.invalid/a.jpg"),
            try await c.sendVideoGroup(gid: 987, videoUrl: "https://example.invalid/a.mp4", durationMs: 1000),
            try await c.sendFileGroup(gid: 987, fileUrl: "https://example.invalid/a.pdf", fileName: "a.pdf", fileSize: 100),
        ]
        for receipt in receipts {
            XCTAssertTrue(receipt.dryRun)
            XCTAssertFalse(receipt.sent)
            XCTAssertTrue(receipt.ok)
            XCTAssertEqual(receipt.desId, 987)
            XCTAssertTrue([201, 207].contains(receipt.cmd))
        }
    }
    func testExpiredSessionRejectsEvenDryRun() async throws {
        let c = try client(expired: true)
        do {
            _ = try await c.sendStickerGroup(gid: 987, stickerId: 1234)
            XCTFail("Expired session must remain latched")
        } catch ZolaError.sessionExpired(let code, _, _) {
            XCTAssertEqual(code, 102)
        }
    }
    func testGroupLivePolicyRequiresExplicitEnableAndRejectsUnsupportedGroups() throws {
        XCTAssertThrowsError(try ZolaGroupMediaWire.checkPolicy(enabled: false, dryRun: false, group: nil))
        XCTAssertNoThrow(try ZolaGroupMediaWire.checkPolicy(enabled: false, dryRun: true, group: nil))
        XCTAssertThrowsError(try ZolaGroupMediaWire.checkPolicy(enabled: true, dryRun: true, group: ZolaGroup(gid: 987, name: "synthetic", isE2ee: true)))
        XCTAssertThrowsError(try ZolaGroupMediaWire.checkPolicy(enabled: true, dryRun: true, group: ZolaGroup(gid: 987, name: "synthetic", lockSendMsg: true)))
    }
    func testLivePolicyRequiresKnownGroupAndHonorsLockForOrdinaryMembers() throws {
        XCTAssertThrowsError(try ZolaGroupMediaWire.checkPolicy(enabled: true, dryRun: false, group: nil))
        let locked = ZolaGroup(gid: 987, name: "synthetic", creatorId: 123, adminIds: [456], lockSendMsg: true)
        XCTAssertNoThrow(try ZolaGroupMediaWire.checkPolicy(enabled: true, dryRun: false, group: locked, senderUid: 123))
        XCTAssertNoThrow(try ZolaGroupMediaWire.checkPolicy(enabled: true, dryRun: false, group: locked, senderUid: 456))
        XCTAssertThrowsError(try ZolaGroupMediaWire.checkPolicy(enabled: true, dryRun: false, group: locked, senderUid: 789))
    }
    func testReactionDryRunAndNativeVoiceUseCorrectCommand() async throws {
        let c = try client()
        let reaction = try await c.sendReactionGroup(gid: 987, messageSenderUid: 456,
            cliMsgId: 1001, globalMsgId: 2001, icon: "❤️", msgType: 32)
        XCTAssertEqual(reaction.cmd, 1785)
        XCTAssertEqual(reaction.subCmd, 55)
        XCTAssertTrue(reaction.dryRun)
        XCTAssertFalse(reaction.sent)
        let voice = try await c.sendGroupVoice(gid: 987, voiceUrl: "https://example.invalid/voice.aac", durationMs: 1500)
        XCTAssertEqual(voice.cmd, 201)
        XCTAssertEqual(voice.subCmd, 31)
        XCTAssertFalse(voice.sent)
    }

    func testNativeReactionProducerGoldenBytes() throws {
        // Actual pure ReactionEntity.createReactionChatElement output from IPA261002.
        // All IDs and values are synthetic; JSON key order is the captured producer order.
        let json = #"{"rType":5,"rMsg":[{"cMsgID":1001,"gMsgID":2001,"msgType":1}],"source":6,"msgSender":"456","rIcon":"/-heart"}"#
        let wire = try ZolaGroupMediaWire.reaction(parameterJSON: json)
        let expected = "3700000000000000000000000000006d007b227254797065223a352c22724d7367223a5b7b22634d73674944223a313030312c22674d73674944223a323030312c226d736754797065223a317d5d2c22736f75726365223a362c226d736753656e646572223a22343536222c227249636f6e223a222f2d6865617274227d"
        XCTAssertEqual(wire.data.map { String(format: "%02x", $0) }.joined(), expected)
    }

    func testNamedReactionRemovalPreservesIconAndUsesNativeMinusOne() throws {
        let json = try ZolaGroupMediaWire.reactionParameters(messageSenderUid: 456, cliMsgId: 1001,
            globalMsgId: 2001, icon: "❤️", removing: true, msgType: 32)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(object["rType"] as? Int, -1)
        XCTAssertEqual(object["rIcon"] as? String, "/-heart")
        XCTAssertEqual((object["rMsg"] as? [[String: Any]])?.first?["msgType"] as? Int, 32)
        let empty = try ZolaGroupMediaWire.reactionParameters(messageSenderUid: 456, cliMsgId: 1001,
            globalMsgId: 2001, icon: "", removing: false, msgType: 1)
        let clearAll = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(empty.utf8)) as? [String: Any])
        XCTAssertEqual(clearAll["rType"] as? Int, -1)
        XCTAssertEqual(clearAll["rIcon"] as? String, "")
    }

}
