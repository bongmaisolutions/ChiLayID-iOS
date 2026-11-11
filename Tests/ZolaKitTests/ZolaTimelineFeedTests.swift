import XCTest
@testable import ZolaKit

final class ZolaTimelineFeedTests: XCTestCase {
    /// 52-byte body of a live "load more" CMD 1230/6 sent by Zalo iOS 261002 (running on a Mac, deviceType 4).
    private let liveLoadMoreHex = "0232968e0f0400000000020000001400000037ddaab30400000037ddaab304000000eb0e90da0400000069b2cefc8c5a06000800"

    func testLoadMoreBodyMatchesLiveCaptureByteForByte() {
        let cursor = ZolaFeedCursor(page: 2, lastFeedId: 20_194_188_599, maxFeedId: 20_846_743_275,
                                    feedVersion: 1_788_411_443_589_737)
        let body = ZolaTimelineFeed.requestBody(cursor: cursor, deviceType: 4)
        XCTAssertEqual(body.map { String(format: "%02x", $0) }.joined(), liveLoadMoreHex)
    }

    func testFirstLoadUsesZeroCursorAndLoadType3() {
        let body = ZolaTimelineFeed.requestBody(cursor: nil)
        XCTAssertEqual(body.count, 52)
        XCTAssertEqual(body[0], 2) // client type iOS
        XCTAssertEqual(Array(body[5..<9]), [2, 0, 0, 0]) // default device type
        XCTAssertEqual(body[9], 0) // main timeline tab
        XCTAssertEqual(Array(body[10..<14]), [0, 0, 0, 0]) // page 0
        XCTAssertEqual(Array(body[14..<18]), [20, 0, 0, 0]) // 20 per page
        XCTAssertTrue(body[18..<50].allSatisfy { $0 == 0 })
        XCTAssertEqual(Array(body[50..<52]), [3, 0])
    }

    func testFrameUsesCommand1230SubCommand6AndRejectsBadCursor() throws {
        let frame = try ZolaTimelineFeed.requestFrame(cursor: nil, srcId: 100_000_102, seqId: 7)
        let element = try ZolaCrypto.unpackChatElementFrame(frame.payload)
        XCTAssertEqual(element.cmd, 1230)
        XCTAssertEqual(element.subCmd, 6)
        XCTAssertEqual(element.seqId, 7)
        XCTAssertThrowsError(try ZolaTimelineFeed.requestFrame(
            cursor: ZolaFeedCursor(page: 0, lastFeedId: 5, maxFeedId: 9, feedVersion: 0), srcId: 1, seqId: 1))
        XCTAssertThrowsError(try ZolaTimelineFeed.requestFrame(cursor: nil, srcId: 0, seqId: 1))
    }

    private func item(_ fid: Int64, ftype: Int = 2, photos: Int = 0, caption: String = "Bài thử") -> [String: Any] {
        var content: [String: Any] = ["caption": caption, "voice_url": "", "typofeed": 0]
        if ftype == 3 {
            content["photos"] = (0..<photos).map { ["photoid": $0 + 1, "thumb": "https://example.invalid/t\($0).jpg",
                                                     "origin": "https://example.invalid/o\($0).jpg", "layout": [String: Any]()] }
        } else if photos > 0 {
            content["photo"] = ["photoid": 9, "thumb": "https://example.invalid/t.jpg", "origin": "https://example.invalid/o.jpg"]
            content["photo_dimension"] = ["width": 1080, "height": 1350]
        }
        return ["fid": fid, "ftype": ftype, "cts": 1_793_886_000_000, "islike": 1, "privacy": 0,
                "header": ["uid": 500_100, "dpn": "Người Thử", "avt": "https://example.invalid/a.jpg", "utype": 0, "uidto": 0],
                "footer": ["numlike": 4, "numcmt": 2, "reaction_info": ["top_reactions": [["id": 1, "count": 4]]]],
                "content": content]
    }

    func testParsesSinglesGroupsAndSkipsSponsoredPosts() throws {
        let sponsored: [String: Any] = ["fid": 299, "ftype": 110, "cts": 1, "track_ads": ["campid": 1], "content": [String: Any]()]
        let data: [String: Any] = ["feeds": [
            ["item": item(300, ftype: 3, photos: 2), "holder_type": 0, "holder_title": ""],
            ["item": sponsored, "holder_type": 0],
            ["items": [item(298, photos: 1), item(297, caption: "")], "holder_type": 2, "holder_title": "Shared 2 activities"],
        ]]
        let page = try ZolaTimelineFeed.parse(data, previous: nil)
        XCTAssertEqual(page.posts.map(\.id), [300, 298, 297])
        XCTAssertEqual(page.posts[0].photos.count, 2)
        XCTAssertEqual(page.posts[0].photos[1].url, "https://example.invalid/o1.jpg")
        XCTAssertEqual(page.posts[1].photos.first?.width, 1080)
        XCTAssertEqual(page.posts[1].groupTitle, "Shared 2 activities")
        XCTAssertEqual(page.posts[0].authorName, "Người Thử")
        XCTAssertEqual(page.posts[0].likeCount, 4)
        XCTAssertEqual(page.posts[0].commentCount, 2)
        XCTAssertTrue(page.posts[0].isLiked)
        XCTAssertFalse(page.posts[2].hasRenderableContent)
        XCTAssertEqual(page.nextCursor, ZolaFeedCursor(page: 1, lastFeedId: 297, maxFeedId: 300, feedVersion: 0))
    }

    func testFindsNestedListAndCarriesPagingForward() throws {
        let previous = ZolaFeedCursor(page: 1, lastFeedId: 297, maxFeedId: 300, feedVersion: 55)
        let data: [String: Any] = ["result": ["list": [["item": item(250)], ["item": item(240)]]], "version": 77]
        let page = try ZolaTimelineFeed.parse(data, previous: previous)
        XCTAssertEqual(page.posts.map(\.id), [250, 240])
        XCTAssertEqual(page.nextCursor, ZolaFeedCursor(page: 2, lastFeedId: 240, maxFeedId: 300, feedVersion: 77))
        XCTAssertEqual(ZolaTimelineFeed.shapeDescription(data), "keys=result,version list=result.list n=2 gop=0 lmore=-")
    }

    func testEmptyListEndsPagingButUnrelatedReplyThrows() throws {
        let previous = ZolaFeedCursor(page: 3, lastFeedId: 10, maxFeedId: 99, feedVersion: 0)
        let page = try ZolaTimelineFeed.parse(["feeds": [Any]()], previous: previous)
        XCTAssertTrue(page.posts.isEmpty)
        XCTAssertNil(page.nextCursor)
        XCTAssertThrowsError(try ZolaTimelineFeed.parse(["status": "ok", "count": 3], previous: nil))
    }

    func testNativeWrapperKeysDrivePaging() throws {
        let data: [String: Any] = ["feeds": [["item": item(500)], ["item": item(490)]],
                                   "last_feed_id": 480, "ver": 1_788_411_443_589_737, "lmore": 1]
        let page = try ZolaTimelineFeed.parse(data, previous: nil)
        XCTAssertEqual(page.posts.map(\.id), [500, 490])
        XCTAssertEqual(page.nextCursor, ZolaFeedCursor(page: 1, lastFeedId: 480, maxFeedId: 500,
                                                       feedVersion: 1_788_411_443_589_737))
        var last = data
        last["lmore"] = 0
        XCTAssertNil(try ZolaTimelineFeed.parse(last, previous: nil).nextCursor, "lmore=0 ends paging")
    }

    func testDryRunNeverOpensSocket() async throws {
        let session = try ZolaSession(uid: 100_000_102, sessionKey: "test-session-key",
                                      cryptKey: Data(repeating: 7, count: 16))
        let client = ZolaClient(session: session)
        let page = try await client.fetchTimelineFeed(cursor: nil, dryRun: true)
        XCTAssertNil(page)
    }
}
