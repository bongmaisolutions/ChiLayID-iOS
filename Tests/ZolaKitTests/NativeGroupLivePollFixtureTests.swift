import XCTest
import ZolaKit

/// PollEntity fixtures (identities synthetic).
/// These are native detail callback objects, not synthetic SDK or raw socket envelopes.
final class NativeGroupLivePollFixtureTests: XCTestCase {
    private let single = #"""
{
  "poll": {
    "id": 9001,
    "groupId": 9000,
    "question": "Demo time",
    "verId": 1793778613108,
    "state": 1,
    "type": 1,
    "isMultiChoice": false,
    "isAnonymous": false,
    "isHideVotePreview": false,
    "numVote": 1,
    "createUid": 1001,
    "creatorName": "Actor A",
    "answers": [
      {
        "id": 9100,
        "content": "Morning",
        "numVote": 1,
        "isChecked": true,
        "usersVoteProfile": [
          {
            "uid": 1001,
            "dpn": "Actor A"
          }
        ]
      },
      {
        "id": 9101,
        "content": "Afternoon",
        "numVote": 0,
        "isChecked": false
      }
    ]
  }
}
"""#
    private let two = #"""
{
  "poll": {
    "id": 9001,
    "groupId": 9000,
    "question": "Demo time",
    "verId": 1793778634887,
    "state": 1,
    "type": 1,
    "isMultiChoice": false,
    "isAnonymous": false,
    "isHideVotePreview": false,
    "numVote": 2,
    "createUid": 1001,
    "creatorName": "Actor A",
    "answers": [
      {
        "id": 9101,
        "content": "Afternoon",
        "numVote": 1,
        "isChecked": false,
        "usersVoteProfile": [
          {
            "uid": 1003,
            "dpn": "Actor C"
          }
        ]
      },
      {
        "id": 9100,
        "content": "Morning",
        "numVote": 1,
        "isChecked": true,
        "usersVoteProfile": [
          {
            "uid": 1001,
            "dpn": "Actor A"
          }
        ]
      }
    ]
  }
}
"""#

    private func parse(_ text: String) throws -> ZolaGroupPollDetail {
        let data = try XCTUnwrap(text.data(using: .utf8))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try ZolaGroupPollWire.detail(from: object, expectedPollId: "9001", groupId: 9000)
    }
    func testActualNative1641InlineProfilesWithoutUsersVoteArray() throws {
        let result = try parse(single)
        XCTAssertEqual(result.totalVotes, 1)
        XCTAssertEqual(result.creatorUid, 1001)
        XCTAssertEqual(result.creatorName, "Actor A")
        XCTAssertTrue(result.mayShowVoters)
        let morning = try XCTUnwrap(result.answers.first { $0.content == "Morning" })
        XCTAssertEqual(morning.votes, 1)
        XCTAssertEqual(morning.checked, true) // native creator perspective only
        XCTAssertEqual(morning.voterUids, []) // server omitted usersVote; no fabricated IDs
        XCTAssertEqual(morning.voters.map(\.uid), [1001])
        XCTAssertEqual(morning.voters.map(\.name), ["Actor A"])
        XCTAssertFalse(result.hasVoterDetails) // no claim of1646/full voter list
    }
    func testActualSecondActorVoteReordersOptionsWithoutLosingIdentity() throws {
        let result = try parse(two)
        XCTAssertEqual(result.totalVotes, 2)
        XCTAssertEqual(result.answers.map(\.content), ["Afternoon", "Morning"])
        XCTAssertEqual(result.answers.map(\.id), ["9101", "9100"])
        XCTAssertEqual(result.answers.map(\.votes), [1, 1])
        XCTAssertEqual(result.answers.flatMap(\.voters).map(\.uid), [1003, 1001])
        let card = result.applying(to: ZolaBoardCard(kind: .poll, title: "Pending", pollId: "9001"))
        XCTAssertEqual(card.title, "Demo time")
        XCTAssertEqual(card.totalVotes, 2)
        XCTAssertEqual(card.options.map(\.label), ["Afternoon", "Morning"])
    }
}
