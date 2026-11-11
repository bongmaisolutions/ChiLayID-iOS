import XCTest
@testable import ZolaKit

final class ZolaMessageMergeTests: XCTestCase {
    private func message(text: String = "Nội dung đầy đủ", kind: String = "text", reactions: [String] = [], snapshot: Bool? = nil, attachments: [ZolaAttachment] = [], quote: ZolaQuote? = nil) -> ZolaMessage {
        ZolaMessage(id: 900, cliMsgId: 120, threadId: 42, senderId: 42, senderName: "Bạn", toId: 1, tsMs: 1000, kind: kind, text: text, attachments: attachments, quote: quote, isSelf: false, reactions: reactions, hasReactionSnapshot: snapshot)
    }

    func testSparseHistoryCannotEraseReadableContentOrRichFields() {
        let original = message(reactions: ["❤️"], attachments: [ZolaAttachment(kind: "photo", url: "https://example.invalid/photo.jpg")], quote: ZolaQuote(ownerId: 42, text: "Đã trích dẫn"))
        let sparse = message(text: "[Tin nhắn chưa hỗ trợ hiển thị]")
        let merged = ZolaMessage.merging(existing: original, incoming: sparse)
        XCTAssertEqual(merged.text, original.text)
        XCTAssertEqual(merged.attachments, original.attachments)
        XCTAssertEqual(merged.quote, original.quote)
        XCTAssertEqual(merged.reactions, ["❤️"])
    }

    func testExplicitEmptyReactionsClearButMissingReactionsPreserve() throws {
        let original = message(reactions: ["❤️"])
        let cleared = ZolaMessage.merging(existing: original, incoming: message(reactions: [], snapshot: true))
        XCTAssertEqual(cleared.reactions, [])
        XCTAssertTrue(cleared.hasReactionSnapshot)
        XCTAssertEqual(ZolaMessage.merging(existing: original, incoming: message()).reactions, ["❤️"])
        let decoded = try JSONDecoder().decode(ZolaMessage.self, from: JSONEncoder().encode(cleared))
        XCTAssertTrue(decoded.hasReactionSnapshot)
    }

    func testRecallWinsInBothDirectionsAndRichUpdateRepairsPlaceholder() {
        let original = message(attachments: [ZolaAttachment(kind: "photo", url: "https://example.invalid/a")])
        let recall = message(text: "Tin nhắn đã được thu hồi", kind: "recalled")
        XCTAssertEqual(ZolaMessage.merging(existing: original, incoming: recall), recall)
        XCTAssertEqual(ZolaMessage.merging(existing: recall, incoming: original), recall)
        XCTAssertEqual(ZolaMessage.merging(existing: message(text: "[Tin nhắn chưa hỗ trợ hiển thị]"), incoming: original).text, original.text)
    }

    func testSQLitePreservesRichMessageAndExplicitReactionClearAcrossReopen() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("history.sqlite")
        let original = message(reactions: ["❤️"], attachments: [ZolaAttachment(kind: "photo", url: "https://example.invalid/photo.jpg")])
        do {
            let store = try ZolaMessageStore(fileURL: url)
            _ = try store.upsertMessages([original], accountUid: 1, threadId: 42)
            _ = try store.upsertMessages([message(text: "[Tin nhắn chưa hỗ trợ hiển thị]", snapshot: true)], accountUid: 1, threadId: 42)
            _ = try store.upsertMessages([message(text: "Tài khoản khác")], accountUid: 2, threadId: 42)
        }
        let reopened = try ZolaMessageStore(fileURL: url)
        let actual = try XCTUnwrap(reopened.messages(accountUid: 1, threadId: 42).first)
        XCTAssertEqual(actual.text, original.text)
        XCTAssertEqual(actual.attachments, original.attachments)
        XCTAssertEqual(actual.reactions, [])
        XCTAssertEqual(try reopened.messages(accountUid: 2, threadId: 42).first?.text, "Tài khoản khác")
    }

    func testSQLiteReactionTargetLookupDoesNotCrossAccountOrThread() throws {
        let store = try ZolaMessageStore.inMemory()
        _ = try store.upsertMessages([message()], accountUid: 1, threadId: 42)
        XCTAssertEqual(try store.message(accountUid: 1, threadId: 42, messageId: 900)?.text, "Nội dung đầy đủ")
        XCTAssertEqual(try store.message(accountUid: 1, threadId: 42, messageId: 0, cliMsgId: 120)?.id, 900)
        XCTAssertNil(try store.message(accountUid: 2, threadId: 42, messageId: 900))
        XCTAssertNil(try store.message(accountUid: 1, threadId: 43, messageId: 900))
        XCTAssertNil(try store.message(accountUid: 1, threadId: 42, messageId: 999))
    }

    func testEditedTextDoesNotKeepStaleMentionOffsets() {
        let original = ZolaMessage(id: 900, cliMsgId: 120, threadId: 42, senderId: 42, toId: 1,
                                   tsMs: 1000, text: "@An xin chào", isSelf: false,
                                   mentions: [ZolaMention(type: 0, uid: 50, pos: 0, len: 3)])
        let edited = ZolaMessage.merging(existing: original, incoming: message(text: "Văn bản mới"))
        XCTAssertEqual(edited.mentions, [])
        let sparse = ZolaMessage.merging(existing: original, incoming: message(text: ""))
        XCTAssertEqual(sparse.mentions, original.mentions)
        let reaction = original.withReactionSnapshot(["❤️", "❤️"])
        XCTAssertEqual(reaction.mentions, original.mentions)
        XCTAssertEqual(reaction.reactions, ["❤️", "❤️"])
        XCTAssertTrue(reaction.hasReactionSnapshot)
    }

    func testNativeCompactHistoryAliasesAndReactionPresence() {
        let raw: [String: Any] = ["gmi": 900, "cmi": 120, "si": 42, "di": 1, "ts": 1000, "msg": "Nội dung native", "reactions": []]
        let parsed = ZolaMessage.fromRawItem(raw, selfUid: 1)
        XCTAssertEqual(parsed.id, 900)
        XCTAssertEqual(parsed.cliMsgId, 120)
        XCTAssertEqual(parsed.threadId, 42)
        XCTAssertEqual(parsed.text, "Nội dung native")
        XCTAssertTrue(parsed.hasReactionSnapshot)
        XCTAssertFalse(ZolaMessage.fromRawItem(["id": 901, "fromU": 42, "to": 1, "msg": "Khác"], selfUid: 1).hasReactionSnapshot)
    }
}
