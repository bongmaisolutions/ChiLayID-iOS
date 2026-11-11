import Foundation

/// Result of matching a composer draft against the keyword → sticker table.
public struct ZolaStickerKeywordMatch: Equatable, Sendable {
    /// Normalized table key that matched (e.g. "cam on").
    public let keyword: String
    /// The matched words as the user typed them (e.g. "cảm ơn"), for the strip header.
    public let displayLabel: String
    /// True when the whole draft is the keyword, so sending a sticker can replace the draft.
    public let matchedWholeInput: Bool
    public let items: [ZolaStickerItem]
}

/// Zalo iOS suggests stickers from a downloaded `mapsticker` table (keyword → stickers) matched
/// locally against the diacritic-stripped draft; it does not call a server per keystroke.
/// This is the same model over a bundled snapshot of that table (see
/// `tools/StickerKeywords/build_sticker_keywords.py`).
public struct ZolaStickerKeywordMap: Sendable {
    public let snapshot: String
    private let table: [String: [ZolaStickerItem]]

    public var keywordCount: Int { table.count }

    /// Longest phrase tried; Zalo's keys are at most a handful of words.
    static let maxPhraseWords = 6

    public init(table: [String: [ZolaStickerItem]], snapshot: String = "") {
        self.table = table
        self.snapshot = snapshot
    }

    /// Decodes `{"v":1,"snapshot":"…","map":{"kw":[[stickerId,cateId,type],…]}}`.
    public init(jsonData: Data) throws {
        guard let root = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let map = root["map"] as? [String: Any] else {
            throw ZolaError.invalidArgument("Bảng gợi ý sticker không hợp lệ")
        }
        var table: [String: [ZolaStickerItem]] = [:]
        table.reserveCapacity(map.count)
        for (key, value) in map {
            guard let rows = value as? [[Any]] else { continue }
            let items: [ZolaStickerItem] = rows.compactMap { row in
                guard row.count >= 2 else { return nil }
                let sid = (row[0] as? NSNumber)?.int64Value ?? 0
                let cid = (row[1] as? NSNumber)?.int64Value ?? 0
                let type = row.count > 2 ? ((row[2] as? NSNumber)?.intValue ?? 7) : 7
                guard sid > 0 else { return nil }
                return ZolaStickerItem(stickerId: sid, cateId: cid, stickerType: type, label: key)
            }
            if !items.isEmpty { table[Self.normalize(key)] = items }
        }
        self.init(table: table, snapshot: root["snapshot"] as? String ?? "")
    }

    /// Lowercase, strip Vietnamese diacritics (đ → d), collapse whitespace — the same folding the
    /// table keys were built with.
    public static func normalize(_ text: String) -> String {
        let folded = text.replacingOccurrences(of: "đ", with: "d").replacingOccurrences(of: "Đ", with: "D")
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "vi_VN"))
            .lowercased()
        return folded.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private static let trailingPunctuation = CharacterSet(charactersIn: ".,!?~…:;\"'")

    /// Whole draft first, then its last 6…1 words (longest first), like a keyboard "last phrase"
    /// lookup. Single short tokens (<2 letters), URLs and long drafts never match.
    public func match(for input: String, limit: Int = 16) -> ZolaStickerKeywordMatch? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 64, limit > 0 else { return nil }
        let lower = trimmed.lowercased()
        guard !lower.contains("http://"), !lower.contains("https://"), !lower.contains("www.") else { return nil }

        let originalWords = trimmed.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let normalizedWords = originalWords.map { Self.normalize($0) }
        guard !normalizedWords.isEmpty else { return nil }

        let maxWords = min(Self.maxPhraseWords, normalizedWords.count)
        for count in stride(from: maxWords, through: 1, by: -1) {
            let phrase = normalizedWords.suffix(count).joined(separator: " ")
            let candidates = [phrase, phrase.trimmingCharacters(in: Self.trailingPunctuation)]
            for candidate in candidates where candidate.count >= 2 {
                guard let items = table[candidate], !items.isEmpty else { continue }
                let label = originalWords.suffix(count).joined(separator: " ")
                    .trimmingCharacters(in: Self.trailingPunctuation)
                return ZolaStickerKeywordMatch(
                    keyword: candidate,
                    displayLabel: label.isEmpty ? candidate : label,
                    matchedWholeInput: count == normalizedWords.count,
                    items: Array(items.prefix(limit))
                )
            }
        }
        return nil
    }
}
