import XCTest
@testable import ZolaKit

final class ZolaStoryFeedTests: XCTestCase {
    /// 27-byte body of a live cmd 1340/2 (story bar refresh) sent by Zalo iOS 261002 on a Mac (deviceType 4).
    private let liveStoryBarHex = "000000003200000000000000000000000400000000000000000001"

    func testStoryBarBodyMatchesLiveCaptureByteForByte() {
        let body = ZolaStoryFeed.storyUsersBody(page: 0, lastUserId: 0, deviceType: 4)
        XCTAssertEqual(body.map { String(format: "%02x", $0) }.joined(), liveStoryBarHex)
    }

    func testStoryFramesUseNativeCommands() throws {
        let bar = try ZolaCrypto.unpackChatElementFrame(try ZolaStoryFeed.storyUsersFrame(srcId: 100_000_102, seqId: 3).payload)
        XCTAssertEqual(bar.cmd, 1340)
        XCTAssertEqual(bar.subCmd, 2)
        let user = try ZolaCrypto.unpackChatElementFrame(try ZolaStoryFeed.userStoriesFrame(userId: 500_100, srcId: 100_000_102, seqId: 4).payload)
        XCTAssertEqual(user.cmd, 1341)
        XCTAssertEqual(user.subCmd, 0)
    }

    func testUserStoriesBodyLayout() throws {
        let body = try ZolaStoryFeed.userStoriesBody(userId: 500_100, page: 1, lastStoryId: 77, deviceType: 2)
        XCTAssertEqual(body.count, 24)
        XCTAssertEqual(Array(body[0..<4]), [0x84, 0xA1, 0x07, 0x00]) // 500100 LE
        XCTAssertEqual(Array(body[4..<8]), [1, 0, 0, 0])
        XCTAssertEqual(Array(body[8..<12]), [20, 0, 0, 0])
        XCTAssertEqual(Array(body[12..<16]), [2, 0, 0, 0])
        XCTAssertEqual(Array(body[16..<24]), [77, 0, 0, 0, 0, 0, 0, 0])
        XCTAssertThrowsError(try ZolaStoryFeed.userStoriesBody(userId: 0))
    }

    func testParsesBarWithNestedStoriesAndSenderObject() throws {
        let data: [String: Any] = [
            "version": 9, "lastUserId": 500_200, "lmore": 1,
            "listStory": [
                ["Sender": ["uid": 500_100, "dpn": "Bạn A", "avt": "https://example.invalid/a.jpg"], "is_seen": 0,
                 "listStory": [["storyId": 11, "photo_url": "https://example.invalid/s1.jpg", "thumb_url": "https://example.invalid/t1.jpg",
                                "create_time": 1_793_886_000_000, "expire_time": 1_793_972_400_000],
                               ["storyId": 12, "video_url": "https://example.invalid/v.mp4", "thumb_url": "https://example.invalid/t2.jpg", "duration": 15000]]],
                ["uid": 500_200, "dpn": "Bạn B", "is_seen": 1],
                ["dpn": "Không có uid"],
            ],
        ]
        let page = try ZolaStoryFeed.parseStoryUsers(data)
        XCTAssertEqual(page.users.map(\.uid), [500_100, 500_200])
        XCTAssertEqual(page.users[0].name, "Bạn A")
        XCTAssertTrue(page.users[0].hasUnseen)
        XCTAssertFalse(page.users[1].hasUnseen)
        XCTAssertEqual(page.users[0].stories.map(\.id), [11, 12])
        XCTAssertFalse(page.users[0].stories[0].isVideo)
        XCTAssertTrue(page.users[0].stories[1].isVideo)
        XCTAssertEqual(page.users[0].stories[1].mediaUrl, "https://example.invalid/v.mp4")
        XCTAssertEqual(page.users[0].stories[0].ownerUid, 500_100)
        XCTAssertTrue(page.hasMore)
        XCTAssertEqual(page.lastUserId, 500_200)
    }

    /// Same key layout as the live 1340/2 reply carrying one text story (values are synthetic).
    func testParsesLiveShapeTextStory() throws {
        let data: [String: Any] = [
            "version": 1, "lastUserId": 500_100, "lmore": 0, "status": 1,
            "listStory": [[
                "uid": 500_100, "dpName": "Bạn A", "avt": "", "seen": 0, "time": 1_793_930_324_649, "utype": 0, "isIntro": 0,
                "listStory": [[
                    "id": 31, "type": 3, "status": "Xin chào", "url": "", "urlHls": "", "thumb": "", "width": 0, "height": 0,
                    "delayTime": 5000, "createTime": 1_793_930_324_649, "typoid": 7, "privacy": 2, "seen": 0, "viewCount": 0,
                    "typo_info": ["align": 1, "bg_color": -12_438_751, "text_color": -1, "ratio": 0.85, "type_bg_render": 0],
                    "ownerInfo": ["userId": 500_100, "displayName": "Bạn A", "avatar": "https://example.invalid/a.jpg", "storyId": 31],
                ] as [String: Any]],
            ] as [String: Any]],
        ]
        let page = try ZolaStoryFeed.parseStoryUsers(data)
        XCTAssertEqual(page.users.count, 1)
        let user = try XCTUnwrap(page.users.first)
        XCTAssertEqual(user.name, "Bạn A")
        XCTAssertEqual(user.avatarUrl, "https://example.invalid/a.jpg") // empty `avt` falls back to ownerInfo
        XCTAssertTrue(user.hasUnseen)
        let story = try XCTUnwrap(user.stories.first)
        XCTAssertTrue(story.isText)
        XCTAssertFalse(story.isVideo)
        XCTAssertEqual(story.caption, "Xin chào")
        XCTAssertEqual(story.durationMs, 5000)
        XCTAssertEqual(story.textStyle, ZolaStoryTextStyle(backgroundArgb: -12_438_751, textArgb: -1, alignment: 1))
        XCTAssertEqual(story.ownerUid, 500_100)
    }

    func testMediaStoryIsNotText() {
        let photo = ZolaStoryFeed.storyItem(from: ["id": 41, "type": 1, "url": "https://example.invalid/p.jpg", "thumb": "https://example.invalid/t.jpg"])
        XCTAssertEqual(photo?.isText, false)
        XCTAssertEqual(photo?.isVideo, false)
        let video = ZolaStoryFeed.storyItem(from: ["id": 42, "url": "https://example.invalid/v.mp4", "thumb": "https://example.invalid/t.jpg"])
        XCTAssertEqual(video?.isVideo, true)
        XCTAssertNil(ZolaStoryFeed.storyItem(from: ["id": 43, "type": 1, "url": "", "thumb": ""]))
    }

    func testEmptyBarAndUserStoriesWithJsonStringMetadata() throws {
        let empty = try ZolaStoryFeed.parseStoryUsers(["version": 1, "lmore": 0, "lastUserId": 0])
        XCTAssertTrue(empty.users.isEmpty)
        XCTAssertThrowsError(try ZolaStoryFeed.parseStoryUsers(["status": "ok"]))
        let stories = try ZolaStoryFeed.parseUserStories(
            ["lmore": 0, "lastStoryId": 0, "story": [["storyid": 21, "metadata": "{\"thumb\":\"https://example.invalid/m.jpg\",\"mediaType\":1}"]]],
            ownerUid: 500_100)
        XCTAssertEqual(stories.map(\.id), [21])
        XCTAssertEqual(stories[0].thumbUrl, "https://example.invalid/m.jpg")
    }

    func testShapeDescriptionListsKeyNamesOnly() {
        let shape = ZolaStoryFeed.shapeDescription(["listStory": [["uid": 1, "listStory": [["storyId": 2, "photo_url": "secret"]]]], "lmore": 0])
        XCTAssertEqual(shape, "keys=listStory,lmore listStory[1]=listStory,uid listStory.listStory[1]=photo_url,storyId")
        XCTAssertFalse(shape.contains("secret"))
    }

    func testScalarSummaryHidesIdsAndText() {
        let summary = ZolaStoryFeed.scalarSummary([
            "status": 2, "version": 17, "lastUserId": 500_100, "lmore": 0, "useLocalStory": true,
            "tipInfo": "private words", "listStory": [] as [Any], "populateStory": ["ids": [1, 2]] as [String: Any],
        ])
        XCTAssertEqual(summary, "lastUserId=set listStory[0] lmore=0 populateStory{ids} status=2 tipInfo=s13 useLocalStory=1 version=17")
        XCTAssertFalse(summary.contains("500100"))
        XCTAssertFalse(summary.contains("private"))
    }

    func testFirstItemSummaryHidesTextAndIds() {
        let summary = ZolaStoryFeed.firstItemSummary([
            "listStory": [["uid": 500_100, "listStory": [["id": 31, "type": 3, "status": "private words",
                                                         "typo_info": ["bg_color": -12_438_751]]]]],
        ])
        XCTAssertEqual(summary, "id=set status=s13 type=3 typo_info{bg_color}")
        XCTAssertFalse(summary.contains("private"))
        XCTAssertFalse(summary.contains("500100"))
    }

    func testDryRunNeverOpensSocket() async throws {
        let session = try ZolaSession(uid: 100_000_102, sessionKey: "test-session-key", cryptKey: Data(repeating: 7, count: 16))
        let client = ZolaClient(session: session)
        let bar = try await client.fetchStoryUsers(dryRun: true)
        XCTAssertNil(bar)
        let stories = try await client.fetchUserStories(userId: 500_100, dryRun: true)
        XCTAssertNil(stories)
    }
}
