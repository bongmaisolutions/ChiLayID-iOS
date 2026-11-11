import XCTest
@testable import ZolaKit

/// socket 201 group-board fixtures (identities synthetic).
final class NativeGroupBoardLiveWireTests: XCTestCase {
    private let note = #"""
{
  "text": {
    "data": {
      "at": 0,
      "attach": {
        "action": "msginfo.actionlist",
        "childnumber": 0,
        "description": "",
        "href": "",
        "params": "{\"actions\":[{\"actionColor\":-16538118,\"actionData\":\"{\\\"topicId\\\":9201,\\\"topicType\\\":0}\",\"actionLabel\":\"Xem\",\"actionLabelv2\":{\"en\":\"View\",\"my\":\"View\",\"vi\":\"Xem\"},\"actionType\":\"action.open.grouptopic.detail\"}],\"avatarUrl\":[],\"highLights\":[{\"len\":19,\"pos\":0,\"uid\":1001}],\"highLightsV2\":[{\"dpn\":\"Actor A\",\"ignoreNickname\":0,\"ts\":0,\"type\":0,\"uid\":1001},{\"dpn\":\"Demo socket note Synt...\",\"ignoreNickname\":0,\"ts\":0,\"type\":1,\"uid\":0}],\"iconUrl\":\"https://example.invalid/qa\",\"msg\":{\"en\":\"%1$s created a note %2$s.\",\"my\":\"%1$s created a note %2$s.\",\"vi\":\"%1$s tạo ghi chú %2$s.\"},\"totalUpdateMem\":1}",
        "thumb": "",
        "title": "Actor A tạo ghi chú Demo socket note Synt....",
        "type": ""
      },
      "cliMsgId": 11001,
      "fromD": "Actor A",
      "fromU": 1001,
      "id": 12001,
      "iv": null,
      "layoutType": 1,
      "mcrypt": 0,
      "msg": "Actor A tạo ghi chú Demo socket note Synt....",
      "notify": 1,
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
      "time": 1793780617,
      "to": 9000,
      "ts": 1793780617314,
      "ttl": 0
    },
    "type": "[redacted]"
  },
  "ts": 1793780617314
}
"""#
    private let reminder = #"""
{
  "text": {
    "data": {
      "at": 0,
      "attach": {
        "action": "",
        "childnumber": 0,
        "description": "",
        "href": "",
        "params": "{\"collapse\":1,\"customMsg\":{\"actions\":[{\"actionColor\":-16538118,\"actionData\":\"{\\\"eventId\\\":9301}\",\"actionLabel\":\"Xem\",\"actionLabelv2\":{\"en\":\"View\",\"my\":\"View\",\"vi\":\"Xem\"},\"actionType\":\"action.open.calendar.event\"}],\"highLightsV2\":[{\"dpn\":\"Actor A\",\"uid\":1001},{\"dpn\":\"Demo socket reminder\",\"type\":0,\"uid\":0},{\"dpn\":\"[redacted]\",\"ts\":1793784300000,\"type\":1,\"uid\":0}],\"iconUrl\":\"https://example.invalid/qa\",\"msg\":{\"en\":\"%1$s created a new time reminder %2$s – %3$s\",\"my\":\"%1$s created a new time reminder %2$s – %3$s\",\"vi\":\"%1$s tạo nhắc hẹn mới %2$s – %3$s\"}},\"item\":{\"checksum\":\"[redacted]\",\"content_time\":1793780728557,\"data_type\":2,\"data_url\":\"https://example.invalid/qa\",\"version\":1,\"zinstantdata_id\":\"[redacted-id]\"},\"layoutType\":0,\"type\":1}",
        "thumb": "",
        "title": "",
        "type": ""
      },
      "cliMsgId": 11002,
      "fromD": "Actor A",
      "fromU": 1001,
      "id": 12002,
      "iv": null,
      "layoutType": 0,
      "mcrypt": 0,
      "msg": "",
      "notify": 1,
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
      "time": 1793780728,
      "to": 9000,
      "ts": 1793780728556,
      "ttl": 0
    },
    "type": "chat.webcontent"
  },
  "ts": 1793780728556
}
"""#
    private let deleted = #"""
{
  "text": {
    "data": {
      "at": 0,
      "attach": {
        "action": "",
        "childnumber": 0,
        "description": "",
        "href": "",
        "params": "{\"collapse\":1,\"customMsg\":{\"actions\":[{\"actionColor\":-16538118,\"actionData\":\"{}\",\"actionLabel\":\"Tạo mới\",\"actionLabelv2\":{\"en\":\"Create new\",\"my\":\"Create new\",\"vi\":\"Tạo mới\"},\"actionType\":\"action.group.create.reminder\"}],\"highLightsV2\":[{\"dpn\":\"Actor A\",\"uid\":1001},{\"dpn\":\"Demo socket reminder\",\"type\":0,\"uid\":0}],\"iconUrl\":\"https://example.invalid/qa\",\"msg\":{\"en\":\"%1$s removed time reminder %2$s.\",\"my\":\"%1$s removed time reminder %2$s.\",\"vi\":\"%1$s xóa nhắc hẹn %2$s.\"}},\"forceShowMsgInfo\":1,\"item\":{\"checksum\":\"[redacted]\",\"content_time\":1793780777997,\"data_type\":2,\"data_url\":\"https://example.invalid/qa\",\"version\":1,\"zinstantdata_id\":\"[redacted-id]\"},\"layoutType\":0,\"type\":1}",
        "thumb": "",
        "title": "",
        "type": ""
      },
      "cliMsgId": 11003,
      "fromD": "Actor A",
      "fromU": 1001,
      "id": 12003,
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
      "time": 1793780778,
      "to": 9000,
      "ts": 1793780778002,
      "ttl": 0
    },
    "type": "chat.webcontent"
  },
  "ts": 1793780778002
}
"""#

    private func raw(_ text: String) throws -> [String:Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String:Any])
    }
    private func parse(_ text: String, group: Bool = true) throws -> ZolaMessage {
        var object = try raw(text)
        if !group {
            var wrap = try XCTUnwrap(object["text"] as? [String:Any])
            var data = try XCTUnwrap(wrap["data"] as? [String:Any])
            data["to"] = 1002; wrap["data"] = data; object["text"] = wrap
        }
        return ZolaMessage.fromRawItem(object, selfUid: 1002, knownGroupIds: group ? [9000] : [], defaultSource: "socket")
    }
    func testActualNoteActionListRendersOnlyObservedPreview() throws {
        let message = try parse(note)
        XCTAssertEqual(message.kind, "board")
        XCTAssertEqual(message.boardCard?.kind, .note)
        XCTAssertEqual(message.boardCard?.title, "Demo socket note Synt...")
        XCTAssertNil(message.boardCard?.body) // full note body is absent from this wire event
        XCTAssertEqual(message.boardCard?.isPreviewOnly, true)
        XCTAssertEqual(message.text, "Actor A tạo ghi chú Demo socket note Synt....")
        XCTAssertEqual(message.boardCard?.creatorUid, 1001)
        XCTAssertEqual(message.boardCard?.creatorName, "Actor A")
        XCTAssertEqual(message.boardCard?.actionText, "đã tạo ghi chú")
        XCTAssertFalse(message.rawDebugJson.isEmpty)
    }
    func testActualCalendarCreateHasTitleMillisecondsAndNoTemplateAttachment() throws {
        let message = try parse(reminder)
        XCTAssertEqual(message.kind, "board")
        XCTAssertEqual(message.boardCard?.kind, .reminder)
        XCTAssertEqual(message.boardCard?.title, "Demo socket reminder")
        XCTAssertEqual(message.boardCard?.startMs, 1793784300000)
        XCTAssertEqual(message.boardCard?.creatorName, "Actor A")
        XCTAssertTrue(message.attachments.isEmpty)
        XCTAssertNotNil(message.webContent)
    }
    func testActualCalendarDeletionRemainsReadableSystemNotice() throws {
        let message = try parse(deleted)
        XCTAssertEqual(message.kind, "system")
        XCTAssertNil(message.boardCard)
        XCTAssertNotNil(message.webContent)
        XCTAssertTrue(message.attachments.isEmpty)
        XCTAssertEqual(message.text, "Actor A đã xóa nhắc hẹn Demo socket reminder")
        XCTAssertFalse(message.text.contains("%1$s"))
    }
    func testEquivalentDirectWebcontentDoesNotBecomeGroupBoardCard() throws {
        let message = try parse(reminder, group: false)
        XCTAssertNil(message.boardCard)
        XCTAssertNotNil(message.webContent)
    }
    func testUnknownGroupActionKeepsExistingWebcontentFallback() throws {
        var object=try raw(reminder)
        var wrap=try XCTUnwrap(object["text"] as? [String:Any]);var data=try XCTUnwrap(wrap["data"] as? [String:Any]);var attach=try XCTUnwrap(data["attach"] as? [String:Any])
        attach["params"] = "{\"customMsg\":{\"msg\":{\"vi\":\"Thông báo khác\"},\"actions\":[{\"actionType\":\"action.unknown\"}]}}"
        data["attach"]=attach;wrap["data"]=data;object["text"]=wrap
        let message=ZolaMessage.fromRawItem(object,selfUid:1002,knownGroupIds:[9000])
        XCTAssertNil(message.boardCard);XCTAssertNotNil(message.webContent)
    }
    private func changingParams(_ fixture: String, _ change: (inout [String:Any]) throws -> Void) throws -> String {
        var object=try raw(fixture)
        var wrap=try XCTUnwrap(object["text"] as? [String:Any]);var data=try XCTUnwrap(wrap["data"] as? [String:Any]);var attach=try XCTUnwrap(data["attach"] as? [String:Any])
        let encoded=try XCTUnwrap(attach["params"] as? String)
        var params=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(encoded.utf8)) as? [String:Any])
        try change(&params)
        attach["params"]=String(data:try JSONSerialization.data(withJSONObject:params),encoding:.utf8)!
        data["attach"]=attach;wrap["data"]=data;object["text"]=wrap
        return String(data:try JSONSerialization.data(withJSONObject:object),encoding:.utf8)!
    }
    func testUnprovenCreationTemplatesDoNotRelabelUpdateAsCreate() throws {
        let changedNote=try changingParams(note) { $0["msg"]=["en":"%1$s updated a note %2$s.","vi":"%1$s sửa ghi chú %2$s."] }
        XCTAssertNil(try parse(changedNote).boardCard)
        let changedReminder=try changingParams(reminder) { params in
            var custom=try XCTUnwrap(params["customMsg"] as? [String:Any]);custom["msg"]=["en":"%1$s shared %2$s","vi":"%1$s chia sẻ %2$s"];params["customMsg"]=custom
        }
        XCTAssertNil(try parse(changedReminder).boardCard)
        XCTAssertNotNil(try parse(changedReminder).webContent)
    }
    func testSecondsInCalendarTimestampAreNotGuessedIntoMilliseconds() throws {
        let changed=try changingParams(reminder) { params in
            var custom=try XCTUnwrap(params["customMsg"] as? [String:Any]);var highlights=try XCTUnwrap(custom["highLightsV2"] as? [[String:Any]]);highlights[2]["ts"]=1793784300;custom["highLightsV2"]=highlights;params["customMsg"]=custom
        }
        XCTAssertNil(try parse(changed).boardCard)
        XCTAssertNotNil(try parse(changed).webContent)
    }
    func testPreviewFlagRoundTripsAndOldBoardCachesRemainDecodable() throws {
        let card=try XCTUnwrap(parse(note).boardCard)
        let encoded=try JSONEncoder().encode(card)
        XCTAssertEqual(try JSONDecoder().decode(ZolaBoardCard.self,from:encoded).isPreviewOnly,true)
        var object=try XCTUnwrap(JSONSerialization.jsonObject(with:encoded) as? [String:Any]);object.removeValue(forKey:"isPreviewOnly")
        let legacy=try JSONDecoder().decode(ZolaBoardCard.self,from:JSONSerialization.data(withJSONObject:object))
        XCTAssertNil(legacy.isPreviewOnly);XCTAssertEqual(legacy.title,card.title)
    }
    func testNonemptyHrefKeepsExistingWebcontentFallback() throws {
        var object=try raw(reminder);var wrap=try XCTUnwrap(object["text"] as? [String:Any]);var data=try XCTUnwrap(wrap["data"] as? [String:Any]);var attach=try XCTUnwrap(data["attach"] as? [String:Any]);attach["href"]="https://example.invalid/ordinary";data["attach"]=attach;wrap["data"]=data;object["text"]=wrap
        let message=ZolaMessage.fromRawItem(object,selfUid:1002,knownGroupIds:[9000])
        XCTAssertNil(message.boardCard);XCTAssertNotNil(message.webContent)
    }

}
