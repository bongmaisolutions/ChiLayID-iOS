import XCTest
@testable import ZolaKit

final class ZolaStickerKeywordMapTests: XCTestCase {
    private func item(_ id: Int64) -> ZolaStickerItem {
        ZolaStickerItem(stickerId: id, cateId: 10, stickerType: 7, label: "")
    }

    private var sample: ZolaStickerKeywordMap {
        ZolaStickerKeywordMap(table: [
            "ok": [item(1), item(2)],
            "cam on": [item(3)],
            "buon qua": [item(4)],
            "ts khong?": [item(5)],
        ])
    }

    func testNormalizeStripsVietnameseDiacriticsAndCase() {
        XCTAssertEqual(ZolaStickerKeywordMap.normalize("  Cảm   Ơn "), "cam on")
        XCTAssertEqual(ZolaStickerKeywordMap.normalize("Đừng buồn"), "dung buon")
    }

    func testWholeDraftAndTrailingPhraseMatch() throws {
        let whole = try XCTUnwrap(sample.match(for: "Ok"))
        XCTAssertEqual(whole.keyword, "ok")
        XCTAssertTrue(whole.matchedWholeInput)
        XCTAssertEqual(whole.items.map(\.stickerId), [1, 2])

        let tail = try XCTUnwrap(sample.match(for: "hôm nay em buồn quá!"))
        XCTAssertEqual(tail.keyword, "buon qua")
        XCTAssertEqual(tail.displayLabel, "buồn quá")
        XCTAssertFalse(tail.matchedWholeInput)

        XCTAssertEqual(sample.match(for: "cảm ơn nhé")?.keyword, nil, "Only the trailing words are looked up")
        XCTAssertEqual(sample.match(for: "anh cảm ơn")?.keyword, "cam on")
        XCTAssertEqual(sample.match(for: "ts khong?")?.keyword, "ts khong?", "Keys may keep their punctuation")
    }

    func testNoMatchForUrlsShortTokensAndLongDrafts() {
        XCTAssertNil(sample.match(for: "https://zalo.me/ok"))
        XCTAssertNil(sample.match(for: "o"))
        XCTAssertNil(sample.match(for: String(repeating: "a ", count: 40) + "ok"))
        XCTAssertNil(sample.match(for: "   "))
    }

    /// The keyword snapshot ships with the host app, not with ZolaKit. Found next to the package when it is
    /// vendored inside the app checkout (`<app>/ZolaKit` + `<app>/App/Resources/...`), or via
    /// `ZOLAKIT_STICKER_KEYWORDS_JSON`; skipped in a standalone ZolaKit checkout.
    func testBundledSnapshotSuggestsCommonPhrases() throws {
        let sibling = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("App/Resources/StickerSuggest/sticker-keywords.json")
        let url = ProcessInfo.processInfo.environment["ZOLAKIT_STICKER_KEYWORDS_JSON"]
            .map { URL(fileURLWithPath: $0) } ?? sibling
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("App sticker-keywords.json snapshot not found next to this ZolaKit checkout")
        }
        let map = try ZolaStickerKeywordMap(jsonData: Data(contentsOf: url))
        XCTAssertGreaterThan(map.keywordCount, 1000)
        for phrase in ["ok", "Alo", "cảm ơn", "buồn quá", "xin chào"] {
            let match = map.match(for: phrase)
            XCTAssertNotNil(match, "\(phrase) must suggest stickers like Zalo")
            XCTAssertFalse(match?.items.isEmpty ?? true)
            XCTAssertTrue(match?.items.allSatisfy { $0.stickerId > 0 } ?? false)
        }
    }
}
