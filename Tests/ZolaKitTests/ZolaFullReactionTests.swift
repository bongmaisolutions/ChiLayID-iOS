import XCTest
@testable import ZolaKit

final class ZolaFullReactionTests: XCTestCase {
    private func raw(icon: String, type: Int = 0, count: Int = 1) -> [String: Any] {
        ["id": 800, "fromU": 42, "to": 1,
         "rIcon": icon, "rType": type, "rCount": count,
         "rMsg": [["gMsgID": 900, "cMsgID": 120]]]
    }

    func testUnicodeReactionOutsideLegacySixSurvivesNativeEvent() throws {
        // Zalo 261002 NativeEmoji.plist contains this exact scalar sequence.
        let update = try XCTUnwrap(ZolaReactionUpdate.fromRawItem(raw(icon: "🤔"), selfUid: 1).first)
        XCTAssertEqual(update.emoji, "🤔")
    }

    func testSkinToneAndJoinedEmojiStayIntact() throws {
        for icon in ["👍🏽", "👩‍💻"] {
            let update = try XCTUnwrap(ZolaReactionUpdate.fromRawItem(raw(icon: icon), selfUid: 1).first)
            XCTAssertEqual(update.emoji, icon)
        }
    }

    func testUnknownPlainTextDoesNotBecomeReactionOrRemoval() {
        XCTAssertTrue(ZolaReactionUpdate.fromRawItem(raw(icon: "not-an-emoji"), selfUid: 1).isEmpty)
    }
    func testNativeCountRemovalAndEnvelopeIdentityArePreserved() throws {
        let added = try XCTUnwrap(ZolaReactionUpdate.fromRawItem(raw(icon: "🤔", type: 9, count: 7), selfUid: 1).first)
        XCTAssertEqual(added.count, 7)
        XCTAssertEqual(added.reactionType, 9)
        XCTAssertEqual(added.envelopeId, 800)
        let removed = try XCTUnwrap(ZolaReactionUpdate.fromRawItem(raw(icon: "/-heart", type: -1), selfUid: 1).first)
        XCTAssertEqual(removed.emoji, "❤️")
        XCTAssertEqual(removed.reactionType, -1)
    }

    func testNativeBundleAliasAndMalformedText() {
        XCTAssertEqual(ZolaReactionCatalog.displayEmoji(for: ":heart_eyes:"), "😍")
        for text in ["hello", "12", "❤️hello", "🤔🤔", "unsupported-symbol"] {
            XCTAssertNil(ZolaReactionCatalog.displayEmoji(for: text))
        }
    }

    func testOutgoingTypesMatchNativeConstructorProbe() throws {
        for (icon, expected) in [("🤔", 1809834), ("👍🏽", 1763246511), ("👩‍💻", -1990343777), ("🔥", 1810360), ("😂", 1817211), ("😠", 1818141)] {
            let wire = try XCTUnwrap(ZolaReactionCatalog.wireReaction(for: icon))
            XCTAssertEqual(wire.rIcon, icon)
            XCTAssertEqual(wire.rType, expected)
        }
        XCTAssertEqual(ZolaReactionCatalog.wireReaction(for: "")?.rType, -1)
        XCTAssertNil(ZolaReactionCatalog.wireReaction(for: "not-an-emoji"))
        // Native probe includes one empty sentinel, excluded from the picker.
        XCTAssertEqual(ZolaReactionCatalog.supportedEmoji.count, 2756)
        for emoji in ZolaReactionCatalog.supportedEmoji {
            XCTAssertNotNil(ZolaReactionCatalog.wireReaction(for: emoji), emoji)
        }
    }

}
