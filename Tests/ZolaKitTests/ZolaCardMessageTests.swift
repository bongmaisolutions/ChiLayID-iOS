import Foundation
import XCTest
@testable import ZolaKit

/// Covers the "card" message types (VIỆC 2): contact cards (`chat.recommend` / `recommened.user`),
/// e-cards, Official Account `chat.webcontent` cards, the "danh sách bài viết" placeholder, and the
/// genuinely-unknown `[Tin nhắn chưa hỗ trợ hiển thị]` fallback. Pure parsing only — no network, no
/// Zalo session is touched, so these run safely without `dryRun`.
final class ZolaCardMessageTests: XCTestCase {
    private let selfUid: Int64 = 100
    private let peerUid: Int64 = 200
    private let tsMs: Int64 = 1_700_000_000_000

    // MARK: - Danh thiếp (contact card)

    func testContactCardRecommendedUserParsesAsCard() {
        let attach: [String: Any] = [
            "action": "recommened.user",
            "params": [
                "uid": "550055",
                "title": "Nguyễn Văn A",
                "avatar": "https://cdn.zalo/avatar.jpg",
                "phone": "0900000000",
            ],
        ]
        let att = ZolaAttachment.fromRaw(msgType: "chat.recommended", attach: attach)
        XCTAssertEqual(att.kind, "card")
        XCTAssertEqual(att.title, "Nguyễn Văn A")
        // Card URL pins the contact UID so tapping can open a 1-1 thread.
        XCTAssertEqual(att.url, "550055")
        XCTAssertTrue(att.thumbUrl.contains("avatar.jpg"), "avatar should become the card thumbnail: \(att.thumbUrl)")
    }

    func testContactCardMessageAppendsCardAttachment() {
        let raw: [String: Any] = [
            "msgType": "chat.recommended",
            "fromU": peerUid,
            "to": selfUid,
            "ts": tsMs,
            "attach": [
                "action": "recommened.user",
                "params": [
                    "uid": "550055",
                    "title": "Nguyễn Văn A",
                    "avatar": "https://cdn.zalo/avatar.jpg",
                ],
            ],
        ]
        let msg = ZolaMessage.fromRawItem(raw, selfUid: selfUid)
        XCTAssertEqual(msg.kind, "card")
        XCTAssertEqual(msg.attachments.count, 1)
        XCTAssertEqual(msg.attachments.first?.kind, "card")
        XCTAssertEqual(msg.attachments.first?.title, "Nguyễn Văn A")
        // The card carries its own fields, so no raw JSON leaks into the bubble text.
        XCTAssertFalse(msg.text.contains("recommened"))
    }

    func testCardWithoutNameKeepsCardKindForUIFallback() {
        // When Zalo sends a card with no readable name, parsing keeps kind "card" with an empty title;
        // the UI (contactCardAttachmentView) is what substitutes "Danh thiếp Zalo".
        let attach: [String: Any] = [
            "action": "recommend.user",
            "params": ["uid": "771177"],
        ]
        let att = ZolaAttachment.fromRaw(msgType: "chat.recommended", attach: attach)
        XCTAssertEqual(att.kind, "card")
        XCTAssertTrue(att.title.isEmpty)
        XCTAssertEqual(att.url, "771177")
    }

    // MARK: - E-card

    func testEcardParsesAsEcard() {
        let attach: [String: Any] = [
            "title": "Chúc mừng sinh nhật",
            "thumb": "https://cdn.zalo/ecard.png",
            "params": ["href": "https://cdn.zalo/ecard.png"],
        ]
        let att = ZolaAttachment.fromRaw(msgType: "chat.ecard", attach: attach)
        XCTAssertEqual(att.kind, "ecard")
        XCTAssertFalse(att.thumbUrl.isEmpty)
    }

    func testEcardMessageWithThumbAppendsEcardAttachment() {
        let raw: [String: Any] = [
            "msgType": "chat.ecard",
            "fromU": peerUid,
            "to": selfUid,
            "ts": tsMs,
            "attach": [
                "title": "Chúc mừng sinh nhật",
                "thumb": "https://cdn.zalo/ecard.png",
                "params": ["href": "https://cdn.zalo/ecard.png"],
            ],
        ]
        let msg = ZolaMessage.fromRawItem(raw, selfUid: selfUid)
        XCTAssertEqual(msg.attachments.count, 1)
        XCTAssertEqual(msg.attachments.first?.kind, "ecard")
    }

    // MARK: - Danh sách bài viết placeholder

    func testListActionShowsArticleListPlaceholder() {
        let raw: [String: Any] = [
            "msgType": "chat.list.action",
            "fromU": peerUid,
            "to": selfUid,
            "ts": tsMs,
        ]
        let msg = ZolaMessage.fromRawItem(raw, selfUid: selfUid)
        XCTAssertTrue(msg.attachments.isEmpty)
        XCTAssertEqual(msg.text, "[Danh sách bài viết]")
        // Retain sanitized unknown wire data so a future parser can recover these articles.
        XCTAssertFalse(msg.rawDebugJson.isEmpty)
    }

    // MARK: - Genuinely unsupported fallback

    func testTrulyUnknownEmptyMessageShowsUnsupportedPlaceholder() {
        let raw: [String: Any] = [
            "msgType": "chat.mystery.format",
            "fromU": peerUid,
            "to": selfUid,
            "ts": tsMs,
        ]
        let msg = ZolaMessage.fromRawItem(raw, selfUid: selfUid)
        XCTAssertTrue(msg.attachments.isEmpty)
        XCTAssertEqual(msg.text, "[Tin nhắn chưa hỗ trợ hiển thị]")
        // Truly-unknown messages keep the sanitized wire item for a local-only "copy raw data" action.
        XCTAssertFalse(msg.rawDebugJson.isEmpty)
        XCTAssertTrue(msg.rawDebugJson.contains("chat.mystery.format"))
    }

    func testKnownCardMessageHasNoRawDebugPayload() {
        let raw: [String: Any] = [
            "msgType": "chat.recommended",
            "fromU": peerUid,
            "to": selfUid,
            "ts": tsMs,
            "attach": [
                "action": "recommened.user",
                "params": ["uid": "550055", "title": "Nguyễn Văn A"],
            ],
        ]
        let msg = ZolaMessage.fromRawItem(raw, selfUid: selfUid)
        XCTAssertEqual(msg.kind, "card")
        // Known/renderable messages never retain a raw debug payload.
        XCTAssertTrue(msg.rawDebugJson.isEmpty)
    }

    // MARK: - Official Account webcontent card

    func testWebContentCardParsesReadableFields() throws {
        let attach: [String: Any] = [
            "title": "Khuyến mãi tháng 11",
            "description": "Giảm 50% toàn bộ sản phẩm",
            "thumb": "https://oa.zalo/promo.jpg",
            "href": "https://oa.zalo/promo",
        ]
        let card = try XCTUnwrap(ZolaWebContent.parse(msgType: "chat.webcontent", attach: attach))
        XCTAssertEqual(card.version, 1)
        XCTAssertTrue(card.hasCardContent)
        XCTAssertEqual(card.displayTitle, "Khuyến mãi tháng 11")
        XCTAssertEqual(card.displayDescription, "Giảm 50% toàn bộ sản phẩm")
        XCTAssertEqual(card.safeHref, "https://oa.zalo/promo")
        XCTAssertEqual(card.cardAttachment.kind, "webcontent")
        XCTAssertEqual(card.cardAttachment.title, "Khuyến mãi tháng 11")
    }

    func testWebContentRejectsInsecureHttpHref() {
        // Safety gate: only https links are ever opened from an OA card.
        let attach: [String: Any] = [
            "title": "Tin OA",
            "href": "http://insecure.example/landing",
        ]
        let content = ZolaWebContent.parse(msgType: "chat.webcontent", attach: attach)
        XCTAssertEqual(content?.safeHref, "")
    }

    func testWebContentMessageAppendsWebContentAttachment() {
        let raw: [String: Any] = [
            "msgType": "chat.webcontent",
            "fromU": peerUid,
            "to": selfUid,
            "ts": tsMs,
            "attach": [
                "title": "Khuyến mãi tháng 11",
                "description": "Giảm 50% toàn bộ sản phẩm",
                "thumb": "https://oa.zalo/promo.jpg",
                "href": "https://oa.zalo/promo",
            ],
        ]
        let msg = ZolaMessage.fromRawItem(raw, selfUid: selfUid)
        XCTAssertEqual(msg.attachments.count, 1)
        XCTAssertEqual(msg.attachments.first?.kind, "webcontent")
        XCTAssertEqual(msg.attachments.first?.title, "Khuyến mãi tháng 11")
    }
}
