import XCTest
@testable import ZolaKit

final class ZolaFeedCommentsTests: XCTestCase {
    /// Live cmd 191/4 body sent by Zalo iOS 261002 on a Mac (deviceType 4) when opening a post's comments from the Timeline.
    private let liveCommentListHex = "00000232968e0f000004b7838de10400000000000000000000000a000000640000000000000000000000000000000000"

    func testCommentListBodyMatchesLiveCaptureByteForByte() throws {
        let body = try ZolaFeedComments.listBody(feedId: 20_964_017_079, lastCommentId: 0, sourceType: 0, deviceType: 4)
        XCTAssertEqual(body.count, 48)
        XCTAssertEqual(body.map { String(format: "%02x", $0) }.joined(), liveCommentListHex)
    }

    func testCommentListFrameUsesNativeCommandAndRejectsBadInput() throws {
        let frame = try ZolaCrypto.unpackChatElementFrame(try ZolaFeedComments.listFrame(feedId: 20_964_017_079, srcId: 100_000_103, seqId: 4).payload)
        XCTAssertEqual(frame.cmd, 191)
        XCTAssertEqual(frame.subCmd, 4)
        XCTAssertThrowsError(try ZolaFeedComments.listBody(feedId: 0))
        XCTAssertThrowsError(try ZolaFeedComments.listBody(feedId: 1, lastCommentId: -1))
        XCTAssertEqual(try ZolaFeedComments.listBody(feedId: 1)[9], 2, "default deviceType 2 (iOS)")
    }

    /// Same key layout as the live `item.comment` of a 1230 feed item (values are synthetic).
    func testReadsLatestCommentFromFeedItem() throws {
        let item: [String: Any] = [
            "ftype": 2, "fid": 500_001, "cts": 1_793_895_934_575, "islike": 0,
            "header": ["uid": 500_100, "dpn": "Bạn A", "avt": "https://example.invalid/a.jpg"],
            "footer": ["numcmt": 2, "numlike": 3],
            "content": ["caption": "Ảnh", "photo": ["photoid": 9, "thumb": "https://example.invalid/t.jpg", "origin": "https://example.invalid/o.jpg"]],
            "comment": ["comment_id": 700_001, "uid": 500_200, "mapEffect": NSNull(), "cts": 1_793_929_861_158,
                        "avt": "https://example.invalid/b.jpg", "dpn": "Bạn B", "comment": "đẹp"],
        ]
        let post = try XCTUnwrap(ZolaTimelineFeed.post(from: item, groupTitle: ""))
        XCTAssertEqual(post.latestComment, ZolaFeedComment(id: 700_001, authorUid: 500_200, authorName: "Bạn B",
                                                           authorAvatarUrl: "https://example.invalid/b.jpg", text: "đẹp",
                                                           createdAtMs: 1_793_929_861_158))
        var noComment = item
        noComment["comment"] = nil
        XCTAssertNil(try XCTUnwrap(ZolaTimelineFeed.post(from: noComment, groupTitle: "")).latestComment)
    }

    /// Same keys as the live 191/4 reply (`tot,last_cid,list,rmv,rtot,enable_recent_like`) and the native entry parser
    /// (`cid,fid,oid,tim,con,avt,sck,fdn,fun,tvb,prt,tdn`); values are synthetic.
    func testParsesLiveShapeCommentList() throws {
        let page = ZolaFeedComments.parseList([
            "tot": 12, "last_cid": 700_001, "rmv": 0, "rtot": 12, "enable_recent_like": 1,
            "list": [
                ["cid": 700_002, "fid": 500_001, "oid": 500_100, "uid": 500_100, "tim": "2026-11-06 00:05:09", "con": "đẹp",
                 "avt": "https://example.invalid/a.jpg", "sck": "x", "fdn": "Bạn A", "fun": "bana", "tvb": "13 giờ", "prt": 0,
                 "tdn": "Bạn B", "type": 0, "attach": "", "is_like": 0, "recently_liked": NSNull(), "mapEffect": NSNull()],
                ["cid": 700_001, "fid": 500_001, "oid": 500_200, "tim": "2026-11-05 23:45:00", "con": "Aloo",
                 "avt": "", "fdn": "Bạn B", "fun": "banb", "tvb": "", "prt": 0, "tdn": ""],
            ],
        ])
        XCTAssertEqual(page.comments.map(\.id), [700_001, 700_002], "oldest first")
        let first = try XCTUnwrap(page.comments.first)
        XCTAssertEqual(first.createdAtMs, ZolaFeedComments.dateStringMs("2026-11-05 23:45:00"))
        XCTAssertEqual(first.text, "Aloo")
        let last = try XCTUnwrap(page.comments.last)
        XCTAssertEqual(last, ZolaFeedComment(id: 700_002, authorUid: 500_100, authorName: "Bạn A",
                                             authorAvatarUrl: "https://example.invalid/a.jpg", text: "đẹp",
                                             createdAtMs: last.createdAtMs, replyToName: "Bạn B"))
        XCTAssertEqual(last.createdAtMs - first.createdAtMs, (20 * 60 + 9) * 1000, "local date strings keep their order and spacing")
        XCTAssertEqual(page.total, 12)
        XCTAssertEqual(page.nextCursor, 700_001)
        XCTAssertTrue(page.hasMore, "12 in total, 2 here, and a cursor")
        let all = ZolaFeedComments.parseList(["tot": 1, "last_cid": 5, "list": [["cid": 5, "oid": 1, "con": "x", "tim": "2026-11-06 00:05:09"]]])
        XCTAssertFalse(all.hasMore)
        XCTAssertNil(ZolaFeedComments.dateStringMs("13 giờ"))
        XCTAssertNil(ZolaFeedComments.dateStringMs(1_793_929_861_158))
        var utc7 = Calendar(identifier: .gregorian)
        utc7.timeZone = TimeZone.current
        let expected = utc7.date(from: DateComponents(year: 2026, month: 11, day: 6, hour: 0, minute: 5, second: 9))!
        XCTAssertEqual(ZolaFeedComments.dateStringMs("2026-11-06 00:05:09"), Int64(expected.timeIntervalSince1970 * 1000))
        XCTAssertEqual(ZolaFeedComments.shapeDescription(["tot": 1, "list": [["cid": 5, "con": "secret"]]]), "keys=list,tot list[1]=cid,con")
    }

    func testParsesListOldestFirstWithoutDuplicates() {
        let page = ZolaFeedComments.parseList([
            "lmore": 1,
            "comments": [
                ["comment_id": 3, "uid": 2, "dpn": "B", "comment": "mới", "cts": 300],
                ["comment_id": 1, "uid": 1, "dpn": "A", "comment": "cũ", "cts": 100],
                ["comment_id": 3, "uid": 2, "dpn": "B", "comment": "mới", "cts": 300],
            ],
            "photos": [["id": 9, "url": "https://example.invalid/p.jpg"]],
        ])
        XCTAssertEqual(page.comments.map(\.id), [1, 3])
        XCTAssertEqual(page.comments.map(\.text), ["cũ", "mới"])
        XCTAssertTrue(page.hasMore)
    }

    func testFindsCommentsNestedOrInsideJSONStrings() {
        let nested = ZolaFeedComments.parseList(["data": ["list": [["commentId": "42", "userId": 7, "displayName": "C", "content": "hi",
                                                                    "createTime": 1_793_929_861_158]]]])
        XCTAssertEqual(nested.comments, [ZolaFeedComment(id: 42, authorUid: 7, authorName: "C", authorAvatarUrl: "", text: "hi",
                                                         createdAtMs: 1_793_929_861_158)])
        XCTAssertFalse(nested.hasMore)
        let stringified = ZolaFeedComments.parseList(["data": #"[{"comment_id":8,"uid":1,"comment":"x","cts":1}]"#])
        XCTAssertEqual(stringified.comments.map(\.id), [8])
        XCTAssertTrue(ZolaFeedComments.parseList(["photos": [["id": 9]], "lmore": 0]).comments.isEmpty, "arrays with only id are not comments")
    }

    func testShapeDescriptionListsKeyNamesOnly() {
        let shape = ZolaFeedComments.shapeDescription(["lmore": 0, "comments": [["comment_id": 777, "comment": "private words", "dpn": "Tên"]]])
        XCTAssertEqual(shape, "keys=comments,lmore list[1]=comment,comment_id,dpn")
        XCTAssertFalse(shape.contains("777"))
        XCTAssertFalse(shape.contains("private"))
        XCTAssertEqual(ZolaFeedComments.shapeDescription(["status": 1]), "keys=status list=none")
    }

    func testDryRunNeverOpensSocket() async throws {
        let session = try ZolaSession(uid: 100_000_103, sessionKey: "test-session-key", cryptKey: Data(repeating: 7, count: 16))
        let client = ZolaClient(session: session)
        let page = try await client.fetchFeedComments(feedId: 20_964_017_079, dryRun: true)
        XCTAssertNil(page)
    }
}
