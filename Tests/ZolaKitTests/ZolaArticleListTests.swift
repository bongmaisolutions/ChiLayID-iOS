import Foundation
import XCTest
@testable import ZolaKit

/// Synthetic envelopes exercising existing native card field names; not captured OA payloads.
final class ZolaArticleListTests: XCTestCase {
    private func message(_ payload: Any) -> ZolaMessage {
        ZolaMessage.fromRawItem([
            "msgType": "chat.list.action", "msgId": "article-test", "fromU": 200,
            "to": 100, "ts": 1_700_000_000_000 as Int64, "attach": payload
        ], selfUid: 100)
    }

    func testStructuredArticlesPreserveOrderAndParentTitleWithParamsURL() {
        let msg = message(["title": "Digest", "items": [
            ["title": "First article", "params": ["href": "https://example.test/one"],
             "thumb": "https://example.test/one.jpg"],
            ["title": "Second article", "description": "Summary", "href": "https://example.test/two"]
        ]])
        XCTAssertEqual(msg.articleCards.map(\.title), ["First article", "Second article"])
        XCTAssertEqual(msg.articleCards.first?.url, "https://example.test/one")
        XCTAssertEqual(msg.articleCards.first?.thumbUrl, "https://example.test/one.jpg")
        XCTAssertEqual(msg.previewText, "First article")
        XCTAssertEqual(msg.tsMs, 1_700_000_000_000)
        XCTAssertTrue(msg.text.isEmpty)
    }

    func testStringifiedNestedEnvelopeAndCacheRoundTrip() throws {
        let data = try JSONSerialization.data(withJSONObject: ["articles": [["title": "News", "href": "https://example.test/news"]]])
        let msg = message(["params": String(decoding: data, as: UTF8.self)])
        XCTAssertEqual(msg.articleCards.count, 1)
        let restored = try JSONDecoder().decode(ZolaMessage.self, from: JSONEncoder().encode(msg))
        XCTAssertEqual(restored.articleCards.first?.title, "News")
    }

    func testUnsafeURLsDoNotBecomeActionsOrImages() {
        let msg = message(["items": [["title": "Readable", "href": "javascript:alert(1)",
                                      "thumb": "https://user:password@example.test/a"]]])
        XCTAssertEqual(msg.articleCards.first?.title, "Readable")
        XCTAssertEqual(msg.articleCards.first?.url, "")
        XCTAssertEqual(msg.articleCards.first?.thumbUrl, "")
    }

    func testEmptyTitleStillHasReadablePreviewAndEmptyCardDoesNotRender() {
        let urlOnly = message(["items": [["title": "  ", "href": "https://example.test/read"]]])
        XCTAssertEqual(urlOnly.previewText, "[Bài viết]")
        XCTAssertEqual(urlOnly.articleCards.count, 1)
        let empty = message(["items": [["title": " ", "href": "javascript:void(0)"]]])
        XCTAssertTrue(empty.articleCards.isEmpty)
        XCTAssertEqual(empty.previewText, "[Danh sách bài viết]")
    }

    func testSparseRepeatCannotEraseRichCardsAndOldCacheStillDecodes() throws {
        let rich = message(["items": [["title": "News", "href": "https://example.test/news"]]])
        let sparse = message([:])
        XCTAssertEqual(ZolaMessage.merging(existing: rich, incoming: sparse).articleCards, rich.articleCards)
        XCTAssertEqual(ZolaMessage.merging(existing: sparse, incoming: rich).articleCards, rich.articleCards)
        let old = Data(#"{"id":1,"threadId":200,"msgType":"chat.list.action","text":"[Danh sách bài viết]"}"#.utf8)
        let decoded = try JSONDecoder().decode(ZolaMessage.self, from: old)
        XCTAssertTrue(decoded.articleCards.isEmpty)
        XCTAssertEqual(decoded.previewText, "[Danh sách bài viết]")
    }

    func testUnknownEnvelopeKeepsReadableFallbackAndSanitizedRaw() {
        let msg = message(["action": "unknown", "params": ["token": "private-test-value", "layout": "v99"]])
        XCTAssertTrue(msg.attachments.isEmpty)
        XCTAssertEqual(msg.text, "[Danh sách bài viết]")
        XCTAssertFalse(msg.rawDebugJson.isEmpty)
        XCTAssertFalse(msg.rawDebugJson.contains("private-test-value"))
    }

    func testMalformedAndOversizedJSONCannotLeakIntoBubble() {
        for value in ["{invalid", String(repeating: " ", count: 65_537) + "{\"title\":\"Hidden\"}"] {
            let msg = message(value)
            XCTAssertTrue(msg.attachments.isEmpty)
            XCTAssertEqual(msg.text, "[Danh sách bài viết]")
        }
    }

    func testListBoundAndDuplicateCards() {
        let items = (0..<100).map { ["title": "Article \($0)", "href": "https://example.test/\($0)"] }
        XCTAssertEqual(message(["items": items]).articleCards.count, 20)
        XCTAssertEqual(message(["items": [items[0], items[0]]]).articleCards.count, 1)
    }

    func testDeepUnknownEnvelopeStopsSafely() {
        var node: [String: Any] = ["title": "Too deep"]
        for _ in 0..<30 { node = ["data": node] }
        XCTAssertTrue(message(node).articleCards.isEmpty)
    }

    func testUnrelatedActionListDoesNotBecomeArticle() {
        let msg = ZolaMessage.fromRawItem(["msgType": "msginfo.actionlist", "fromU": 200, "to": 100,
            "content": "System event"], selfUid: 100)
        XCTAssertTrue(msg.articleCards.isEmpty)
    }

    func testReadableNativeTextSurvivesUnknownListLayout() {
        let msg = ZolaMessage.fromRawItem(["msgType": "chat.list.action", "fromU": 200, "to": 100,
            "msg": "Today's news", "attach": ["unknownLayout": true]], selfUid: 100)
        XCTAssertEqual(msg.text, "Today's news")
        XCTAssertTrue(msg.articleCards.isEmpty)
        XCTAssertFalse(msg.rawDebugJson.isEmpty)
    }
}
