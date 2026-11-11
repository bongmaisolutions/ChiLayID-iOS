import XCTest
@testable import ZolaKit

final class ZolaFeedComposerTests: XCTestCase {
    /// Live cmd 1233/4 body sent by Zalo iOS 261002 on a Mac (deviceType 4) for an "Only me" text post.
    private let liveOnlyMeHex = "00000232968e0f00000000000004000000f272e4aca10100001300000054657374205a6f6c614b2064616e672062616900000000000000f0bf000000000000f0bf0000010000000000000000ffffffffffffffff000000000000f0bfffffffffffffffff0001000100000000"
    private let liveTimestamp: Int64 = 0x0000_01a1_ace4_72f2

    func testOnlyMeTextPostMatchesLiveCaptureByteForByte() throws {
        let body = try ZolaFeedComposer.textPostBody(text: "Test ZolaK dang bai", privacy: .onlyMe,
                                                     clientTimestampMs: liveTimestamp, deviceType: 4)
        XCTAssertEqual(body.count, 108)
        XCTAssertEqual(body.map { String(format: "%02x", $0) }.joined(), liveOnlyMeHex)
    }

    func testFriendsPrivacyOnlyChangesThePrivacyField() throws {
        let onlyMe = try ZolaFeedComposer.textPostBody(text: "Xin chào", privacy: .onlyMe, clientTimestampMs: 1, deviceType: 2)
        let friends = try ZolaFeedComposer.textPostBody(text: "Xin chào", privacy: .friends, clientTimestampMs: 1, deviceType: 2)
        let diff = zip(onlyMe, friends).enumerated().filter { $0.element.0 != $0.element.1 }.map(\.offset)
        let privacyOffset = 2 + 1 + 4 + 2 + 4 + 4 + 8 + 4 + Data("Xin chào".utf8).count + 1 + 8 + 8 + 2
        XCTAssertEqual(diff, [privacyOffset])
        XCTAssertEqual(friends[privacyOffset], 0)
        XCTAssertEqual(onlyMe[privacyOffset], 1)
    }

    func testFramesUseNativeCommands() throws {
        let post = try ZolaCrypto.unpackChatElementFrame(try ZolaFeedComposer.textPostFrame(
            text: "Xin chào", privacy: .friends, clientTimestampMs: 5, srcId: 100_000_103, seqId: 8).payload)
        XCTAssertEqual(post.cmd, 1233)
        XCTAssertEqual(post.subCmd, 4)
        let delete = try ZolaCrypto.unpackChatElementFrame(try ZolaFeedComposer.deleteFrame(feedId: 20_964_100_352, srcId: 100_000_103, seqId: 9).payload)
        XCTAssertEqual(delete.cmd, 296)
        XCTAssertEqual(delete.subCmd, 0)
        XCTAssertEqual(try ZolaFeedComposer.deleteBody(feedId: 20_964_100_352).map { $0 }, [0x00, 0xc9, 0x8e, 0xe1, 0x04, 0, 0, 0]) // 20964100352 = 0x04E18EC900
    }

    func testRejectsEmptyOrInvalidInput() {
        XCTAssertThrowsError(try ZolaFeedComposer.textPostBody(text: "  \n", privacy: .friends, clientTimestampMs: 1))
        XCTAssertThrowsError(try ZolaFeedComposer.textPostBody(text: "ok", privacy: .friends, clientTimestampMs: 0))
        XCTAssertThrowsError(try ZolaFeedComposer.deleteBody(feedId: 0))
    }

    func testPostedFeedIdReadsKnownKeys() {
        XCTAssertEqual(ZolaFeedComposer.postedFeedId(["fid": 123]), 123)
        XCTAssertEqual(ZolaFeedComposer.postedFeedId(["feedId": "456"]), 456)
        XCTAssertEqual(ZolaFeedComposer.postedFeedId(["holder_title": "", "holder_type": 0, "item": ["fid": 20_965_268_933, "ftype": 2]]),
                       20_965_268_933) // live 1796 reply shape
        XCTAssertNil(ZolaFeedComposer.postedFeedId(["status": 1]))
    }

    func testDryRunNeverOpensSocket() async throws {
        let session = try ZolaSession(uid: 100_000_103, sessionKey: "test-session-key", cryptKey: Data(repeating: 7, count: 16))
        let client = ZolaClient(session: session)
        let posted = try await client.postTimelineText("Xin chào", privacy: .onlyMe, dryRun: true)
        XCTAssertNil(posted)
        let deleted = try await client.deleteTimelinePost(feedId: 1, dryRun: true)
        XCTAssertFalse(deleted)
    }

    /// Live cmd 1796/1 body sent by Zalo iOS 261002 on a Mac (deviceType 4) for an "Only me" 1080×1080 photo post
    /// captioned "ZolaK test anh" (the test post was deleted afterwards).
    private let livePhotoOnlyMeHex = "00000232968e0f000001743ba40b00000071db49afa10100000e0000005a6f6c614b207465737420616e680000000004000000000000000000f0bf000000000000f0bf000000000100000000000000380400003804000000000000000000000028001b0000007b2262746e54797065223a312c226576656e7454797065223a307d00000000000000000000000000"

    func testOnlyMePhotoPostMatchesLiveCaptureByteForByte() throws {
        let body = try ZolaFeedComposer.photoPostBody(photoId: 50_000_000_001, caption: "ZolaK test anh", privacy: .onlyMe,
                                                      width: 1080, height: 1080, clientTimestampMs: 1_793_942_215_537, deviceType: 4)
        XCTAssertEqual(body.count, 142)
        XCTAssertEqual(body.map { String(format: "%02x", $0) }.joined(), livePhotoOnlyMeHex)
    }

    func testPhotoPostPrivacyAndEmptyCaption() throws {
        let onlyMe = try ZolaFeedComposer.photoPostBody(photoId: 9, caption: "", privacy: .onlyMe, width: 4, height: 3, clientTimestampMs: 1)
        let friends = try ZolaFeedComposer.photoPostBody(photoId: 9, caption: "", privacy: .friends, width: 4, height: 3, clientTimestampMs: 1)
        let diff = zip(onlyMe, friends).enumerated().filter { $0.element.0 != $0.element.1 }.map(\.offset)
        let privacyOffset = 2 + 1 + 4 + 2 + 8 + 8 + 4 + 4 + 4 + 8 + 8 + 4
        XCTAssertEqual(diff, [privacyOffset])
        XCTAssertEqual(onlyMe[privacyOffset], 1)
        XCTAssertEqual(Array(onlyMe[25..<29]), [0, 0, 0, 0]) // empty caption is a zero length, no text bytes
        XCTAssertEqual(Array(onlyMe[33..<37]), [2, 0, 0, 0]) // default deviceType 2 (iOS)
    }

    func testPhotoFrameUsesNativeCommandAndRejectsBadInput() throws {
        let frame = try ZolaCrypto.unpackChatElementFrame(try ZolaFeedComposer.photoPostFrame(
            photoId: 50_000_000_001, caption: "Ảnh", privacy: .friends, width: 1080, height: 1350,
            clientTimestampMs: 5, srcId: 100_000_103, seqId: 8).payload)
        XCTAssertEqual(frame.cmd, 1796)
        XCTAssertEqual(frame.subCmd, 1)
        XCTAssertThrowsError(try ZolaFeedComposer.photoPostBody(photoId: 0, caption: "", privacy: .friends, width: 1, height: 1, clientTimestampMs: 1))
        XCTAssertThrowsError(try ZolaFeedComposer.photoPostBody(photoId: 1, caption: "", privacy: .friends, width: 0, height: 1, clientTimestampMs: 1))
        XCTAssertThrowsError(try ZolaFeedComposer.photoPostBody(photoId: 1, caption: "", privacy: .friends, width: 1, height: 1, clientTimestampMs: 0))
    }

    func testUploadedPhotoIdReadsNativeKeysInOrder() {
        XCTAssertEqual(ZolaFeedComposer.uploadedPhotoId(["error_code": 0, "data": ["sFileId": "50000000001", "photo_id": 7]]), 50_000_000_001)
        XCTAssertEqual(ZolaFeedComposer.uploadedPhotoId(["error_code": 0, "data": ["photo_id": 42]]), 42)
        XCTAssertEqual(ZolaFeedComposer.uploadedPhotoId(["data": ["data": ["photo_id": "43"]]]), 43)
        XCTAssertNil(ZolaFeedComposer.uploadedPhotoId(["error_code": 0, "data": ["url": "https://example.invalid/a.jpg"]]))
        XCTAssertNil(ZolaFeedComposer.uploadedPhotoId(["error_code": 0, "data": ["media_id": "abcdefghij0123456789"]]))
    }

    func testPhotoDryRunNeverUploadsOrOpensSocket() async throws {
        let session = try ZolaSession(uid: 100_000_103, sessionKey: "test-session-key", cryptKey: Data(repeating: 7, count: 16))
        let client = ZolaClient(session: session)
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10])
        let posted = try await client.postTimelinePhoto(jpegData: jpeg, width: 10, height: 10, caption: "", privacy: .onlyMe, dryRun: true)
        XCTAssertNil(posted)
        do {
            _ = try await client.postTimelinePhoto(jpegData: Data(), width: 10, height: 10, caption: "", privacy: .onlyMe, dryRun: true)
            XCTFail("empty photo must be rejected")
        } catch {}
        do {
            _ = try await client.postTimelinePhoto(jpegData: Data(count: ZolaFeedComposer.maxPhotoBytes + 1), width: 10, height: 10,
                                                   caption: "", privacy: .onlyMe, dryRun: true)
            XCTFail("oversized photo must be rejected")
        } catch {}
    }
}
