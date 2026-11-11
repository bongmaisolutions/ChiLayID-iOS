import XCTest
@testable import ZolaKit

final class ZolaSocialActionsTests: XCTestCase {
    // Captured live from Zalo iOS 261002 on 2026-11-05: user liked then commented "Aloo" on feed 20964017079.
    private let feedId: Int64 = 20_964_017_079
    private let liveLikeHex = "00000232968e0f0000b7838de1040000006500570000007b226e65775f7265616374696f6e5f6964223a312c2263757272656e745f7265616374696f6e5f6964223a302c22656e61626c655f7265616374696f6e73223a747275652c2272656163745f636f6e74657874223a307d0000010000000000000000000000"
    private let liveCommentHex = "00000232968e0f0000b7838de1040000006400000004000000416c6f6f00000000000000000000000000000000000000000000000043a099aca101000065000000000000000000000000000000000000000000"
    private let liveCommentTs: Int64 = 1_793_897_111_619

    func testLikeBodyMatchesLiveCaptureByteForByte() throws {
        let body = try ZolaSocialActions.reactionBody(feedId: feedId, newReactionId: 1, currentReactionId: 0)
        XCTAssertEqual(body.map { String(format: "%02x", $0) }.joined(), liveLikeHex)
    }

    func testCommentBodyMatchesLiveCaptureByteForByte() throws {
        let body = try ZolaSocialActions.commentBody(feedId: feedId, text: "Aloo", timestampMs: liveCommentTs)
        XCTAssertEqual(body.map { String(format: "%02x", $0) }.joined(), liveCommentHex)
    }

    func testReactionFrameUsesCmd189Sub5() throws {
        let frame = try ZolaSocialActions.reactionFrame(feedId: feedId, newReactionId: 1, currentReactionId: 0, srcId: 100_000_102, seqId: 9)
        let element = try ZolaCrypto.unpackChatElementFrame(frame.payload)
        XCTAssertEqual(element.cmd, 189)
        XCTAssertEqual(element.subCmd, 5)
        XCTAssertEqual(element.seqId, 9)
    }

    func testCommentFrameUsesCmd188Sub5() throws {
        let frame = try ZolaSocialActions.commentFrame(feedId: feedId, text: "Aloo", timestampMs: liveCommentTs, srcId: 100_000_102, seqId: 4)
        let element = try ZolaCrypto.unpackChatElementFrame(frame.payload)
        XCTAssertEqual(element.cmd, 188)
        XCTAssertEqual(element.subCmd, 5)
    }

    func testUnlikeFlipsReactionIdsInsideJson() throws {
        let body = try ZolaSocialActions.reactionBody(feedId: feedId, newReactionId: 0, currentReactionId: 1)
        let json = String(data: body.suffix(from: 23).prefix(while: { $0 != 0 }), encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains("\"new_reaction_id\":0"))
        XCTAssertTrue(json.contains("\"current_reaction_id\":1"))
    }

    func testInvalidInputsThrow() {
        XCTAssertThrowsError(try ZolaSocialActions.reactionBody(feedId: 0, newReactionId: 1, currentReactionId: 0))
        XCTAssertThrowsError(try ZolaSocialActions.commentBody(feedId: feedId, text: "   ", timestampMs: 1))
    }

    func testDryRunNeverOpensSocket() async throws {
        let session = try ZolaSession(uid: 100_000_102, sessionKey: "test-session-key", cryptKey: Data(repeating: 7, count: 16))
        let client = ZolaClient(session: session)
        let liked = try await client.reactToFeed(feedId: feedId, like: true, dryRun: true)
        XCTAssertFalse(liked)
        let commented = try await client.commentOnFeed(feedId: feedId, text: "Xin chào", dryRun: true)
        XCTAssertFalse(commented)
    }
}
