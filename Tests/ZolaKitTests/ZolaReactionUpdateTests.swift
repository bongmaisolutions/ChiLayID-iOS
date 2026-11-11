import XCTest
@testable import ZolaKit

final class ZolaReactionUpdateTests: XCTestCase {
    func testNativeReactionTargetsAndActorAreSeparateFromTargetAuthor() throws {
        // Native subCmd=55 schema from sendReaction1To1, under the existing chat envelope.
        let payload: [String: Any] = ["rIcon": "/-heart", "msgSender": "1", "rMsg": [["gMsgID": 900, "cMsgID": 120, "msgType": 1]]]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
        let raw: [String: Any] = ["id": 999, "fromU": 42, "to": 1, "msg": ["params": json]]
        let event = try XCTUnwrap(ZolaReactionUpdate.fromRawItem(raw, selfUid: 1).first)
        XCTAssertEqual(event.actorUid, 42)
        XCTAssertEqual(event.threadId, 42)
        XCTAssertEqual(event.messageId, 900)
        XCTAssertEqual(event.cliMsgId, 120)
        XCTAssertEqual(event.emoji, "❤️")
        XCTAssertFalse(event.isGroup)
    }

    func testGroupClearIsActorScopedAndUnknownIconsAreNotClears() throws {
        var raw: [String: Any] = ["si": 42, "di": 777, "rIcon": "", "rMsg": [["gMsgID": 900, "cMsgID": 120]]]
        let clear = try XCTUnwrap(ZolaReactionUpdate.fromRawItem(raw, selfUid: 1, knownGroupIds: [777]).first)
        XCTAssertEqual(clear.threadId, 777)
        XCTAssertEqual(clear.actorUid, 42)
        XCTAssertTrue(clear.isGroup)
        XCTAssertEqual(clear.emoji, "")
        raw["rIcon"] = "unsupported-symbol"
        XCTAssertTrue(ZolaReactionUpdate.fromRawItem(raw, selfUid: 1, knownGroupIds: [777]).isEmpty)
        raw["rIcon"] = "/-heart"
        raw.removeValue(forKey: "si")
        raw["msgSender"] = "42"
        XCTAssertTrue(ZolaReactionUpdate.fromRawItem(raw, selfUid: 1).isEmpty, "Target author must never be treated as reacting actor")
    }

    func testSeenMessageEmitsChangedSnapshotWithoutNewMessageEvent() async throws {
        let session = try ZolaSession(uid: 1, sessionKey: "fixture-only", cryptKey: Data(repeating: 1, count: 16))
        let client = ZolaClient(session: session)
        func message(_ icons: [String]) -> ZolaMessage {
            ZolaMessage(id: 900, cliMsgId: 120, threadId: 42, senderId: 42, toId: 1, tsMs: 1000, text: "Tin", isSelf: false, reactions: icons, hasReactionSnapshot: true)
        }
        let first = await client.messageEvent(message([]), isUnseen: true, nowMs: 1000)
        XCTAssertEqual(first?.type, "message.new")
        let heart = await client.messageEvent(message(["❤️"]), isUnseen: false, nowMs: 1000)
        XCTAssertEqual(heart?.type, "message.updated")
        let repeatHeart = await client.messageEvent(message(["❤️"]), isUnseen: false, nowMs: 1000)
        XCTAssertNil(repeatHeart)
        let clear = await client.messageEvent(message([]), isUnseen: false, nowMs: 1000)
        XCTAssertEqual(clear?.type, "message.updated")
        let heartAgain = await client.messageEvent(message(["❤️"]), isUnseen: false, nowMs: 1000)
        XCTAssertEqual(heartAgain?.type, "message.updated")
    }

    func testNativeNestedHistoryBatchExtractsChildrenNotUnsupportedContainers() {
        let batch: [String: Any] = ["groups": [["gId": 777, "msg": [["gmi": 900, "cmi": 120, "si": 42, "di": 777, "msg": "Nội dung"]]]]]
        let items = ZolaClient.extractRawMessageDicts(from: batch)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?["msg"] as? String, "Nội dung")
        let parsed = items.map { ZolaMessage.fromRawItem($0, selfUid: 1, knownGroupIds: [777]) }
        XCTAssertEqual(parsed.first?.text, "Nội dung")
        XCTAssertEqual(parsed.first?.id, 900)
    }
    func testOfflinePollEmitsActorMutationWithoutBlankMessageWhenFemcFails() async throws {
        final class FixtureTransport: ZolaNetworkTransport, @unchecked Sendable {
            func execute(_ request: URLRequest) async throws -> (Int, Data) {
                if request.url?.path == "/api/message" {
                    let raw: [String: Any] = ["id": 999, "cliMsgId": 888, "fromU": 42, "to": 1,
                        "msg": ["rIcon": "/-heart", "msgSender": "1", "rMsg": [["gMsgID": 900, "cMsgID": 120, "msgType": 1]]]]
                    return (200, try JSONSerialization.data(withJSONObject: ["error_code": 0, "data": ["offline": ["e": 0, "msg": [raw]]]]))
                }
                return (200, Data(#"{"e":-500,"errMessage":"fixture transient"}"#.utf8))
            }
        }
        let session = try ZolaSession(uid: 1, sessionKey: "fixture-only", cryptKey: Data(repeating: 1, count: 16))
        let client = ZolaClient(session: session, transport: FixtureTransport(), minPollIntervalSeconds: 0)
        let events = try await client.pollOnce(includePreload: false, includeOffline: true, emitInitialSnapshot: true)
        XCTAssertEqual(events.map(\.type), ["message.reaction"])
        XCTAssertNil(events.first?.message)
        XCTAssertEqual(events.first?.reaction?.actorUid, 42)
        XCTAssertEqual(events.first?.reaction?.messageId, 900)
    }

    func testPollDeliversChangedAndRemovedSnapshotsForSameServerID() async throws {
        actor FixtureTransport: ZolaNetworkTransport {
            let zcid: String
            var step = 0
            init(zcid: String) { self.zcid = zcid }
            func execute(_ request: URLRequest) async throws -> (Int, Data) {
                guard request.url?.path == "/api/cm/femc" else { throw ZolaError.transport("Unexpected fixture request") }
                let icons: [[String: Any]] = step == 1 ? [["rIcon": "/-heart"]] : []
                step += 1
                let raw: [String: Any] = ["id": 900, "cliMsgId": 120, "fromU": 42, "to": 1, "ts": 1000, "msg": "Tin gốc", "reactions": icons]
                let encrypted = try ZolaCrypto.encryptZCIDParams(["hasMore": false, "msg": [raw]], zcid: zcid)
                return (200, try JSONSerialization.data(withJSONObject: ["e": 0, "data": encrypted]))
            }
        }
        let session = try ZolaSession(uid: 1, sessionKey: "fixture-only", cryptKey: Data(repeating: 1, count: 16), zcid: String(repeating: "a", count: 64), zcidIsNative: true)
        let client = ZolaClient(session: session, transport: FixtureTransport(zcid: session.zcid), minPollIntervalSeconds: 0)
        let initial = try await client.pollOnce(includePreload: false, includeOffline: false, emitInitialSnapshot: true)
        let changed = try await client.pollOnce(includePreload: false, includeOffline: false)
        let removed = try await client.pollOnce(includePreload: false, includeOffline: false)
        let duplicate = try await client.pollOnce(includePreload: false, includeOffline: false)
        XCTAssertEqual(initial.map(\.type), ["message.new"])
        XCTAssertEqual(changed.map(\.type), ["message.updated"])
        XCTAssertEqual(changed.first?.message?.reactions, ["❤️"])
        XCTAssertEqual(removed.map(\.type), ["message.updated"])
        XCTAssertEqual(removed.first?.message?.reactions, [])
        XCTAssertTrue(duplicate.isEmpty)
    }

}
