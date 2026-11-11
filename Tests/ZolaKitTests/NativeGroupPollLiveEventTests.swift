import XCTest
@testable import ZolaKit

/// 201 poll-vote event and native 1641 callback fixture (identities synthetic).
/// Actor/group/poll/message identities are remapped; unknown attach.action stays redacted.
final class NativeGroupPollLiveEventTests: XCTestCase {
    private let event = #"""
{
  "text": {
    "data": {
      "at": 0,
      "attach": {
        "action": "[redacted]",
        "childnumber": 0,
        "description": "",
        "href": "",
        "params": "{\"dName\":\"Actor A\",\"groupId\":9000,\"isAnonymous\":false,\"msg\":{\"en\":\"%1$s changed vote in the poll: %2$s\",\"my\":\"%1$s သည္မဲဇယား: %2$s တြင္မဲကိုေျပာင္းခဲ့သည္\",\"vi\":\"%1$s đổi lựa chọn trong cuộc bình chọn: %2$s\"},\"pollId\":9001,\"pollVer\":1793781817422,\"question\":\"Demo time\",\"uid\":1001}",
        "thumb": "",
        "title": "",
        "type": ""
      },
      "cliMsgId": 14001,
      "fromD": "Actor A",
      "fromU": 1001,
      "id": 13001,
      "iv": null,
      "layoutType": 0,
      "mcrypt": 0,
      "msg": "",
      "notify": 0,
      "paramsExt": {
        "containType": 0,
        "countUnread": 0,
        "forceNotify": 0,
        "notifyActionCate": 0,
        "notifyTTL": 0,
        "platformType": 3,
        "refactorType": 0
      },
      "refMessageId": 0,
      "time": 1793781817,
      "to": 9000,
      "ts": 1793781817457,
      "ttl": 0
    },
    "type": "group.poll"
  },
  "ts": 1793781817457
}
"""#
    private let detail = #"""
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
    private func object(_ text: String) throws -> [String:Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with:Data(text.utf8)) as? [String:Any])
    }
    private func message() throws -> ZolaMessage {
        ZolaMessage.fromRawItem(try object(event), selfUid:1002, knownGroupIds:[9000], defaultSource:"socket")
    }
    func testActual201GroupPollRetainsDetailIdentityWithoutInventingOptions() throws {
        let value=try message()
        XCTAssertEqual(value.msgType,"group.poll")
        XCTAssertEqual(value.kind,"board")
        XCTAssertEqual(value.threadId,9000)
        let card=try XCTUnwrap(value.boardCard)
        XCTAssertEqual(card.kind,.poll)
        XCTAssertEqual(card.pollId,"9001")
        XCTAssertEqual(card.title,"Demo time")
        XCTAssertEqual(card.actionText,"đã đổi lựa chọn")
        XCTAssertTrue(card.options.isEmpty)
        XCTAssertNil(card.totalVotes)
        XCTAssertEqual(card.isAnonymous,false)
        XCTAssertFalse(value.rawDebugJson.isEmpty)
        let restored=try JSONDecoder().decode(ZolaMessage.self,from:JSONEncoder().encode(value))
        XCTAssertEqual(restored.boardCard?.pollId,"9001")
    }
    func testActual201CardLinksToSamePollGroupCacheAnd1641Options() async throws {
        let card=try XCTUnwrap(message().boardCard)
        let result=try ZolaGroupPollWire.detail(from:object(detail),expectedPollId:try XCTUnwrap(card.pollId),groupId:9000)
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:dir)}
        let path=dir.appendingPathComponent("polls.json")
        let cache=ZolaGroupPollCache(accountUid:1002,fileURL:path)
        let now=Date(timeIntervalSince1970:1000)
        try await cache.store(result,now:now)
        let reload=ZolaGroupPollCache(accountUid:1002,fileURL:path)
        let cached=await reload.value(pollId:try XCTUnwrap(card.pollId),groupId:9000,now:now)
        let applied=try XCTUnwrap(cached).applying(to:card)
        XCTAssertEqual(applied.pollId,"9001")
        XCTAssertEqual(applied.title,card.title)
        XCTAssertEqual(applied.options.map(\.label),["Afternoon","Morning"])
        XCTAssertEqual(applied.options.map(\.votes),[1,1])
        XCTAssertEqual(applied.totalVotes,2)
        let wrongGroup=await reload.value(pollId:"9001",groupId:9002,now:now)
        XCTAssertNil(wrongGroup)
        XCTAssertEqual(cached?.answers.flatMap(\.voters).map(\.uid),[1003,1001])
    }
    func testUnknownOrBarePollDoesNotClaimCreation() throws {
        for template in [[:], ["en":"Unverified poll update"]] as [[String:String]] {
            var raw=try object(event)
            var wrap=try XCTUnwrap(raw["text"] as? [String:Any]);var inner=try XCTUnwrap(wrap["data"] as? [String:Any]);var attach=try XCTUnwrap(inner["attach"] as? [String:Any])
            var params=try object(try XCTUnwrap(attach["params"] as? String));params["msg"]=template
            attach["params"]=String(data:try JSONSerialization.data(withJSONObject:params),encoding:.utf8)!;inner["attach"]=attach;wrap["data"]=inner;raw["text"]=wrap
            let parsed=ZolaMessage.fromRawItem(raw,selfUid:1002,knownGroupIds:[9000])
            XCTAssertEqual(parsed.boardCard?.actionText,"đã cập nhật bình chọn")
            XCTAssertEqual(parsed.boardCard?.pollId,"9001")
        }
    }
    func testExplicitCreateAndNewSuffixesKeepCreationLabel() throws {
        for type in ["group.poll.create","group.poll.new"] {
            var raw=try object(event);var wrap=try XCTUnwrap(raw["text"] as? [String:Any]);wrap["type"]=type;raw["text"]=wrap
            let parsed=ZolaMessage.fromRawItem(raw,selfUid:1002,knownGroupIds:[9000])
            XCTAssertEqual(parsed.boardCard?.actionText,"đã tạo bình chọn")
        }
    }

}
