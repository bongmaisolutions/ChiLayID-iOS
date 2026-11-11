import XCTest
@testable import ZolaKit

/// Synthetic fixtures using field names verified in native261002's parser.
/// No live session, network or group mutation is used by these tests.
final class NativeGroupPollTests: XCTestCase {
    private func fixture(version: Int = 3, anonymous: Bool = false, hidden: Bool = false) -> [String: Any] {
        ["poll": ["id": "72623859790382856", "groupId": "70001", "verId": version,
            "question": "Chọn giờ họp", "createUid": 101, "creatorName": "Người tạo",
            "isAnonymous": anonymous ? 1 : 0, "isHideVotePreview": hidden ? 1 : 0,
            "isMultiChoice": 1, "state": 2, "numVote": 2,
            "answers": [["id": 0, "content": "Buổi sáng", "numVote": 2, "isChecked": 1,
                         "usersVote": [101, "102", 101],
                         "usersVoteProfile": [["uid": "101", "dpn": "Thành viên A"], ["uid": "102", "dpn": "Thành viên B"]]]]]]
    }
    private func detail(version: Int = 3, anonymous: Bool = false, hidden: Bool = false) throws -> ZolaGroupPollDetail {
        try ZolaGroupPollWire.detail(from: fixture(version: version, anonymous: anonymous, hidden: hidden),
            expectedPollId: "72623859790382856", groupId: 70001)
    }

    func testNativeReadCommandsContainOnlyInt64LittleEndianPollID() throws {
        for read in [ZolaGroupPollWire.Read.detail, .answers] {
            let frame = try ZolaGroupPollWire.requestFrame(pollId: "72623859790382856", read: read, srcId: 101, seqId: 7)
            let unpacked = try ZolaCrypto.unpackChatElementFrame(frame.payload)
            XCTAssertEqual(unpacked.cmd, read.rawValue)
            XCTAssertEqual(unpacked.subCmd, 0)
            XCTAssertEqual(unpacked.srcType, 3)
            XCTAssertEqual(unpacked.msgType, 1)
            XCTAssertEqual(unpacked.bodyData, Data([8, 7, 6, 5, 4, 3, 2, 1]))
        }
        for bad in ["0", "-1", "12_other", "9223372036854775808"] {
            XCTAssertThrowsError(try ZolaGroupPollWire.requestFrame(pollId: bad, read: .detail, srcId: 101, seqId: 7))
        }
    }

    func testExactNativePollAndVoterFieldsRenderWithoutAliasGuessing() throws {
        let result = try detail()
        XCTAssertEqual(result.question, "Chọn giờ họp")
        XCTAssertEqual(result.answers.first?.id, "0")
        XCTAssertEqual(result.answers.first?.voterUids, [101, 102])
        XCTAssertEqual(result.answers.first?.voters.map(\.name), ["Thành viên A", "Thành viên B"])
        let card = result.applying(to: ZolaBoardCard(kind: .poll, title: "Bình chọn"))
        XCTAssertEqual(card.options.first?.votedBySelf, true)
        XCTAssertEqual(card.options.first?.votes, 2)
        XCTAssertEqual(card.totalVotes, 2)
        XCTAssertEqual(card.isClosed, true)
        XCTAssertEqual(card.allowMultiChoice, true)
    }

    func testPollIdentityAndGroupMismatchAreRejected() throws {
        XCTAssertThrowsError(try ZolaGroupPollWire.detail(from: fixture(), expectedPollId: "99", groupId: 70001))
        XCTAssertThrowsError(try ZolaGroupPollWire.detail(from: fixture(), expectedPollId: "72623859790382856", groupId: 70002))
        XCTAssertThrowsError(try ZolaGroupPollWire.detail(from: ["answers": []], expectedPollId: "72623859790382856", groupId: 70001))
    }

    func testAnonymousOrHiddenPollDropsVoterIdentities() throws {
        for result in [try detail(anonymous: true), try detail(hidden: true)] {
            XCTAssertFalse(result.mayShowVoters)
            XCTAssertEqual(result.answers.first?.voters, [])
            XCTAssertEqual(result.answers.first?.voterUids, [])
            XCTAssertEqual(result.answers.first?.votes, 2)
        }
    }

    func testUncorrelated1646AnswersCannotReplaceAnotherPoll() throws {
        let pollA = try detail()
        var pollBFields = try XCTUnwrap(fixture()["poll"] as? [String: Any])
        pollBFields["id"] = "99"
        pollBFields["groupId"] = "70002"
        pollBFields["question"] = "Bình chọn khác"
        let pollB = try ZolaGroupPollWire.detail(from: ["poll": pollBFields], expectedPollId: "99", groupId: 70002)
        let bareAnswersFromA = ["answers": try XCTUnwrap((fixture()["poll"] as? [String: Any])?["answers"])]
        // A times out; its delayed response arrives during B. Neither a bare1646
        // array nor even A's complete identity can be relabeled as B.
        XCTAssertThrowsError(try ZolaGroupPollWire.applyingAnswers(bareAnswersFromA, to: pollB))
        XCTAssertThrowsError(try ZolaGroupPollWire.applyingAnswers(fixture(), to: pollB))
        XCTAssertEqual(pollB.pollId, "99")
        XCTAssertEqual(pollB.groupId, 70002)
        XCTAssertFalse(pollB.hasVoterDetails)
        let matching = try ZolaGroupPollWire.applyingAnswers(fixture(), to: pollA)
        XCTAssertEqual(matching, pollA)
    }

    func testMissingOrMalformedPrivacyFlagsNeverExposeVoters() throws {
        for key in ["isAnonymous", "isHideVotePreview"] {
            for invalid: Any? in [nil, NSNull(), "unknown", ["unexpected": 0]] {
                var fields = try XCTUnwrap(fixture()["poll"] as? [String: Any])
                fields[key] = invalid
                let value = try ZolaGroupPollWire.detail(from: ["poll": fields], expectedPollId: "72623859790382856", groupId: 70001)
                XCTAssertFalse(value.mayShowVoters)
                XCTAssertEqual(value.answers.first?.voters, [])
                XCTAssertEqual(value.answers.first?.voterUids, [])
                XCTAssertEqual(value.answers.first?.votes, 2)
            }
        }
    }

    func testCacheIsPersistentAccountScopedAndExpires() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("polls.json")
        let now = Date(timeIntervalSince1970: 1000)
        let original = try detail()
        let cache = ZolaGroupPollCache(accountUid: 101, fileURL: file)
        try await cache.store(original, now: now)
        let restored = ZolaGroupPollCache(accountUid: 101, fileURL: file)
        let same = await restored.value(pollId: original.pollId, groupId: 70001, now: now)
        XCTAssertEqual(same, original)
        let expired = await restored.value(pollId: original.pollId, groupId: 70001, now: now.addingTimeInterval(61))
        XCTAssertNil(expired)
        let other = ZolaGroupPollCache(accountUid: 102, fileURL: file)
        let leaked = await other.value(pollId: original.pollId, groupId: 70001, now: now)
        XCTAssertNil(leaked)
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }

    func testOlderVersionCannotOverwriteNewerCachedPoll() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = ZolaGroupPollCache(accountUid: 101, fileURL: dir.appendingPathComponent("polls.json"))
        let now = Date()
        try await cache.store(detail(version: 5), now: now)
        try await cache.store(detail(version: 3), now: now)
        let current = await cache.value(pollId: "72623859790382856", groupId: 70001, now: now)
        XCTAssertEqual(current?.version, 5)
    }
    func test600Type188OnlyInvalidatesExplicitGroupIDs() throws {
        let body = try JSONSerialization.data(withJSONObject: [
            ["id": "notification-a", "type": 188, "item": [["groupId": "70001"], ["groupId": "70001"], ["groupId": 70002]]],
            ["id": "notification-b", "type": 12, "item": [["groupId": "70003"]]]
        ])
        let changes = ZolaGroupSystemNotifications.decode(command: 600, decodedBody: body)
        XCTAssertEqual(changes.map(\.groupId), [70001, 70002])
        for command: Int16 in [601, 602, 603, 604, 605] {
            XCTAssertEqual(ZolaGroupSystemNotifications.decode(command: command, decodedBody: body), [])
        }
        XCTAssertEqual(ZolaGroupSystemNotifications.decode(command: 600, decodedBody: Data(body.dropLast())), [])
        let guessedEnvelope = try JSONSerialization.data(withJSONObject: ["data": [["type": 188, "groupId": 70001]]])
        XCTAssertEqual(ZolaGroupSystemNotifications.decode(command: 600, decodedBody: guessedEnvelope), [])
    }

    func testNotificationBoundsAndMissingIdentityAreRejected() throws {
        let body = try JSONSerialization.data(withJSONObject: [
            ["type": 188, "item": [["groupId": "70001"]]],
            ["id": "bad-id", "type": 188, "item": [["groupId": true], ["groupId": -1]]]
        ])
        XCTAssertEqual(ZolaGroupSystemNotifications.decode(command: 600, decodedBody: body), [])
        XCTAssertEqual(ZolaGroupSystemNotifications.decode(command: 600, decodedBody: Data(count: 1024 * 1024 + 1)), [])
    }

    func testSameCommandReadsCannotOverlap() async throws {
        actor Probe {
            var active = 0
            var maximum = 0
            func enter() { active += 1; maximum = max(maximum, active) }
            func leave() { active -= 1 }
        }
        let queue = ZolaGroupPollReadQueue()
        let probe = Probe()
        let value = try detail()
        try await withThrowingTaskGroup(of: ZolaGroupPollDetail.self) { group in
            for _ in 0..<12 {
                group.addTask {
                    try await queue.run {
                        await probe.enter()
                        for _ in 0..<8 { await Task.yield() }
                        await probe.leave()
                        return value
                    }
                }
            }
            for try await result in group { XCTAssertEqual(result, value) }
        }
        let maximum = await probe.maximum
        XCTAssertEqual(maximum, 1)
    }

    func testPreFixCacheWithoutCorrelationVersionIsIgnored() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("polls.json")
        let now = Date()
        let cache = ZolaGroupPollCache(accountUid: 101, fileURL: file)
        try await cache.store(detail(), now: now)
        var oldEnvelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        oldEnvelope.removeValue(forKey: "formatVersion")
        try JSONSerialization.data(withJSONObject: oldEnvelope).write(to: file)
        let reloaded = ZolaGroupPollCache(accountUid: 101, fileURL: file)
        let stale = await reloaded.value(pollId: "72623859790382856", groupId: 70001, now: now)
        XCTAssertNil(stale)
    }

}
