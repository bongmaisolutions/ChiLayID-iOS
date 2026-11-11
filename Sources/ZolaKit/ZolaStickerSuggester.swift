import Foundation

/// Represents a single Zalo sticker with its native `stickerId`, `cateId`, `stickerType`, and CDN preview URL.
public struct ZolaStickerItem: Codable, Sendable, Identifiable, Equatable, Hashable {
    public var id: Int64 { stickerId }
    public let stickerId: Int64
    public let cateId: Int64
    public let stickerType: Int
    public let label: String

    public var cdnUrl: String {
        ZolaAttachment.stickerCdnUrl(stickerId: stickerId, cateId: cateId)
    }

    public init(
        stickerId: Int64,
        cateId: Int64 = 0,
        stickerType: Int = 0,
        label: String = ""
    ) {
        self.stickerId = stickerId
        self.cateId = cateId
        self.stickerType = stickerType > 0 ? stickerType : ((cateId == 0 && (1...30).contains(stickerId)) ? 2 : 0)
        self.label = label
    }
}

/// Curated or pinned Zalo sticker pack metadata for the sticker picker tray.
public struct ZolaStickerPack: Codable, Sendable, Identifiable, Equatable {
    public let id: Int64
    public let title: String
    public let stickers: [ZolaStickerItem]

    public init(id: Int64, title: String, stickers: [ZolaStickerItem]) {
        self.id = id
        self.title = title
        self.stickers = stickers
    }
}

/// Public Zalo Sticker Store category summary (`https://stickers.zaloapp.com/sticker` & `https://zalo-api.zadn.vn/api/emoticon/pcweb/getAllCate`).
public struct ZolaStickerStorePack: Codable, Sendable, Identifiable, Equatable {
    public let id: Int64
    public let storeCid: String
    public let name: String
    public let desc: String
    public let totalImage: Int
    public let iconUrl: String
    public let thumbImg: String

    private enum CodingKeys: String, CodingKey {
        case id, storeCid, name, desc, totalImage, iconUrl, thumbImg
    }

    public init(
        id: Int64,
        storeCid: String = "",
        name: String,
        desc: String = "",
        totalImage: Int = 0,
        iconUrl: String = "",
        thumbImg: String = ""
    ) {
        self.id = id
        self.storeCid = storeCid
        self.name = name
        self.desc = desc
        self.totalImage = totalImage
        self.iconUrl = iconUrl
        self.thumbImg = thumbImg
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int64.self, forKey: .id)
        storeCid = try c.decodeIfPresent(String.self, forKey: .storeCid) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        desc = try c.decodeIfPresent(String.self, forKey: .desc) ?? ""
        totalImage = try c.decodeIfPresent(Int.self, forKey: .totalImage) ?? 0
        iconUrl = try c.decodeIfPresent(String.self, forKey: .iconUrl) ?? ""
        thumbImg = try c.decodeIfPresent(String.self, forKey: .thumbImg) ?? ""
    }

    public var previewUrl: String {
        !iconUrl.isEmpty ? iconUrl : thumbImg
    }

    private static func isInternalTestPackName(_ rawName: String) -> Bool {
        let lowerName = rawName.lowercased()
        return lowerName == "test"
            || lowerName.hasPrefix("test ")
            || lowerName.hasSuffix(" test")
            || lowerName.contains(" test ")
            || lowerName.hasPrefix("bộ test")
    }

    private static func extractNumericCateId(iconUrl: String, thumbImg: String) -> Int64 {
        let combined = "\(iconUrl) \(thumbImg)"
        guard let range = combined.range(of: #"(?<=/)[0-9]+(?=/(?:icon|preview))"#, options: .regularExpression),
              let val = Int64(combined[range]), val > 0
        else {
            return 0
        }
        return val
    }

    private static func parseStickerCount(_ raw: Any?) -> Int {
        let direct = ZolaJSON.int(raw)
        if direct > 0 { return direct }
        let s = ZolaJSON.string(raw)
        guard let range = s.range(of: #"[0-9]+"#, options: .regularExpression),
              let val = Int(s[range])
        else { return 0 }
        return max(0, val)
    }

    /// Parses `https://stickers.zaloapp.com/sticker` (`value.{hot, popular, event, all}`).
    public static func parseStoreLandingCatalog(from rawData: Data) -> [ZolaStickerStorePack] {
        let unzipped = ZolaRequestBuilder.gunzipDecompress(rawData) ?? rawData
        guard let root = try? JSONSerialization.jsonObject(with: unzipped) as? [String: Any],
              let valueDict = (root["value"] as? [String: Any]) ?? (root["data"] as? [String: Any])
        else { return [] }

        var combinedRows: [[String: Any]] = []
        for section in ["hot", "event", "popular", "all"] {
            if let rows = valueDict[section] as? [[String: Any]] {
                combinedRows.append(contentsOf: rows)
            }
        }
        guard !combinedRows.isEmpty else { return [] }

        var seen = Set<Int64>()
        var packs: [ZolaStickerStorePack] = []
        for item in combinedRows {
            let rawName = ZolaJSON.string(item["name"] ?? item["title"]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rawName.isEmpty, !isInternalTestPackName(rawName) else { continue }
            let rawCidStr = ZolaJSON.string(item["id"] ?? item["storeCid"] ?? item["cid"]).trimmingCharacters(in: .whitespacesAndNewlines)
            let icon = ZolaAttachment.normalizeMediaUrl(ZolaJSON.string(item["iconUrl"] ?? item["icon"]))
            let thumb = ZolaAttachment.normalizeMediaUrl(ZolaJSON.string(item["thumbImg"] ?? item["thumbUrl"] ?? item["iconUrl"]))
            let directNum = ZolaJSON.int64(item["cateId"])
            let resolvedNumId = directNum > 0
                ? directNum
                : (Int64(rawCidStr) ?? extractNumericCateId(iconUrl: icon, thumbImg: thumb))
            guard resolvedNumId > 0, seen.insert(resolvedNumId).inserted else { continue }
            let uploader = ZolaJSON.string(item["source"] ?? item["desc"]).trimmingCharacters(in: .whitespacesAndNewlines)
            packs.append(
                ZolaStickerStorePack(
                    id: resolvedNumId,
                    storeCid: rawCidStr,
                    name: rawName,
                    desc: uploader,
                    totalImage: parseStickerCount(item["totalImage"] ?? item["numSticker"]),
                    iconUrl: icon,
                    thumbImg: thumb
                )
            )
        }
        return packs.sorted { $0.id > $1.id }
    }

    /// Parses `https://stickers.zaloapp.com/cate-stickers?cid=<storeCid>` into `[ZolaStickerItem]`.
    public static func parseCateStickers(
        from rawData: Data,
        cateId: Int64,
        fallbackLabel: String = ""
    ) -> [ZolaStickerItem] {
        let unzipped = ZolaRequestBuilder.gunzipDecompress(rawData) ?? rawData
        guard let root = try? JSONSerialization.jsonObject(with: unzipped) as? [String: Any],
              let list = (root["value"] as? [[String: Any]]) ?? (root["data"] as? [[String: Any]])
        else { return [] }

        let cleanLabel = fallbackLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        var seen = Set<Int64>()
        var out: [ZolaStickerItem] = []
        for row in list {
            let urlStr = ZolaJSON.string(row["url"] ?? row["stickerUrl"] ?? row[" stickerSpriteUrl"])
            var eid = ZolaJSON.int64(row["eid"] ?? row["stickerId"])
            if eid <= 0, let range = urlStr.range(of: #"(?<=eid=)[0-9]+"#, options: .regularExpression) {
                eid = Int64(urlStr[range]) ?? 0
            }
            guard eid > 0, seen.insert(eid).inserted else { continue }
            let stype = ZolaJSON.int(row["type"] ?? row["stickerType"], default: 0)
            out.append(
                ZolaStickerItem(
                    stickerId: eid,
                    cateId: max(0, cateId),
                    stickerType: max(0, stype),
                    label: cleanLabel
                )
            )
        }
        return out
    }

    public static func parseCatalog(from rawData: Data) -> [ZolaStickerStorePack] {
        let landing = parseStoreLandingCatalog(from: rawData)
        if !landing.isEmpty { return landing }

        let unzipped = ZolaRequestBuilder.gunzipDecompress(rawData) ?? rawData
        guard let root = try? JSONSerialization.jsonObject(with: unzipped) else { return [] }
        let listRaw: [[String: Any]] = {
            if let arr = root as? [[String: Any]] { return arr }
            if let dict = root as? [String: Any] {
                if let all = dict["all"] as? [[String: Any]] { return all }
                if let list = dict["list"] as? [[String: Any]] { return list }
                if let cates = dict["categories"] as? [[String: Any]] { return cates }
                if let dataDict = dict["data"] as? [String: Any] {
                    if let all = dataDict["all"] as? [[String: Any]] { return all }
                    if let list = dataDict["list"] as? [[String: Any]] { return list }
                    if let cates = dataDict["categories"] as? [[String: Any]] { return cates }
                    if let items = dataDict["items"] as? [[String: Any]] { return items }
                }
                if let dataArr = dict["data"] as? [[String: Any]] { return dataArr }
            }
            return []
        }()

        var seen = Set<Int64>()
        var packs: [ZolaStickerStorePack] = []
        for item in listRaw {
            let cid = ZolaJSON.int64(item["id"] ?? item["cateId"] ?? item["cid"])
            let rawName = ZolaJSON.string(item["name"] ?? item["title"]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard cid > 0, !rawName.isEmpty, !isInternalTestPackName(rawName), seen.insert(cid).inserted else { continue }
            let total = parseStickerCount(item["totalImage"] ?? item["numSticker"] ?? item["total"])
            let icon = ZolaAttachment.normalizeMediaUrl(
                ZolaJSON.string(item["iconUrl"] ?? item["icon"] ?? item["thumbUrl"] ?? item["thumbImg"])
            )
            let thumb = ZolaAttachment.normalizeMediaUrl(
                ZolaJSON.string(item["thumbImg"] ?? item["thumbUrl"] ?? item["sourceUrl"] ?? item["iconUrl"])
            )
            packs.append(
                ZolaStickerStorePack(
                    id: cid,
                    storeCid: ZolaJSON.string(item["storeCid"]),
                    name: rawName,
                    desc: ZolaJSON.string(item["desc"] ?? item["description"]).trimmingCharacters(in: .whitespacesAndNewlines),
                    totalImage: total,
                    iconUrl: icon,
                    thumbImg: thumb
                )
            )
        }
        return packs.sorted { $0.id > $1.id }
    }
}

/// Built-in catalog of verified Zalo sticker packs (`zalo-api.zadn.vn` `magic = 20000` verified `eid` + `cateId`).
public enum ZolaStickerCatalog {
    public static let popularPackId: Int64 = -1
    public static let onionPackId: Int64 = 0

    private static let onionLabels: [Int64: String] = [
        1: "củ hành cười vui vẻ hi",
        2: "củ hành nháy mắt tinh nghịch",
        3: "củ hành ngạc nhiên ồ wow",
        4: "củ hành lè lưỡi trêu",
        5: "củ hành cười lớn haha",
        6: "củ hành bối rối ngại ngùng",
        7: "củ hành khóc buồn huhu",
        8: "củ hành giận dữ tức bốc khói",
        9: "củ hành thả tim yêu thương",
        10: "củ hành suy nghĩ đắn đo",
        11: "củ hành ngầu kính đen",
        12: "củ hành ngủ ngon khò khò",
        13: "củ hành đổ mồ hôi lo lắng",
        14: "củ hành choáng váng xỉu",
        15: "củ hành hôn gió chụt",
        16: "củ hành lườm nghi ngờ",
        17: "củ hành cười gian hehe",
        18: "củ hành ôm đầu trời ơi",
        19: "củ hành đói bụng chảy nước miếng",
        20: "củ hành xin lỗi cúi đầu",
        21: "củ hành like chuẩn ok tuyệt",
        22: "củ hành vẫy tay tạm biệt chào",
        23: "củ hành cố lên quyết tâm",
        24: "củ hành hóng chuyện ngó",
        25: "củ hành gật đầu đồng ý",
        26: "củ hành lắc đầu không chịu",
        27: "củ hành chúc mừng tung hoa",
        28: "củ hành cảm ơn đa tạ",
        29: "củ hành uống trà thư giãn",
        30: "củ hành hết pin mệt mỏi",
    ]

    public static let onionPack: ZolaStickerPack = ZolaStickerPack(
        id: onionPackId,
        title: "Củ hành",
        stickers: (Int64(1)...Int64(30)).map { sid in
            ZolaStickerItem(
                stickerId: sid,
                cateId: 0,
                stickerType: 2,
                label: onionLabels[sid] ?? "củ hành \(sid)"
            )
        }
    )

    public static let packs: [ZolaStickerPack] = [
        ZolaStickerPack(
            id: popularPackId,
            title: "Phổ biến",
            stickers: [
                ZolaStickerItem(stickerId: 18082, cateId: 10134, label: "xin chào vẫy tay hello hi"),
                ZolaStickerItem(stickerId: 18083, cateId: 10134, label: "cười vui haha hihi"),
                ZolaStickerItem(stickerId: 18084, cateId: 10134, label: "yêu thả tim thương love"),
                ZolaStickerItem(stickerId: 18085, cateId: 10134, label: "cảm ơn thanks tks biết ơn"),
                ZolaStickerItem(stickerId: 18086, cateId: 10134, label: "ok đồng ý duyệt nhất trí"),
                ZolaStickerItem(stickerId: 18087, cateId: 10134, label: "buồn khóc tủi thân huhu"),
                ZolaStickerItem(stickerId: 18088, cateId: 10134, label: "cố lên quyết tâm fighting"),
                ZolaStickerItem(stickerId: 18089, cateId: 10134, label: "ngủ ngon chúc ngủ ngon g9"),
                ZolaStickerItem(stickerId: 23285, cateId: 10417, label: "chúc mừng sinh nhật hpbd tung hoa"),
                ZolaStickerItem(stickerId: 23286, cateId: 10417, label: "tuyệt vời đỉnh quá like"),
                ZolaStickerItem(stickerId: 46601, cateId: 11980, label: "thả tim yêu quá nhớ"),
                ZolaStickerItem(stickerId: 43586, cateId: 11790, label: "hóng bất ngờ wow"),
            ]
        ),
        onionPack,
        ZolaStickerPack(
            id: 10134,
            title: "Cảm xúc",
            stickers: [
                ZolaStickerItem(stickerId: 18082, cateId: 10134, label: "xin chào hi hello"),
                ZolaStickerItem(stickerId: 18083, cateId: 10134, label: "cười vui vẻ haha"),
                ZolaStickerItem(stickerId: 18084, cateId: 10134, label: "yêu thương tim"),
                ZolaStickerItem(stickerId: 18085, cateId: 10134, label: "cảm ơn đa tạ"),
                ZolaStickerItem(stickerId: 18086, cateId: 10134, label: "ok chuẩn luôn"),
                ZolaStickerItem(stickerId: 18087, cateId: 10134, label: "buồn khóc huhu"),
                ZolaStickerItem(stickerId: 18088, cateId: 10134, label: "cố lên mạnh mẽ"),
                ZolaStickerItem(stickerId: 18089, cateId: 10134, label: "ngủ ngon mơ đẹp"),
                ZolaStickerItem(stickerId: 18090, cateId: 10134, label: "xin lỗi ngại quá"),
            ]
        ),
        ZolaStickerPack(
            id: 10239,
            title: "Đáng yêu",
            stickers: [
                ZolaStickerItem(stickerId: 19885, cateId: 10239, label: "chào bạn hi đáng yêu"),
                ZolaStickerItem(stickerId: 19886, cateId: 10239, label: "nhớ quá thương yêu"),
                ZolaStickerItem(stickerId: 19887, cateId: 10239, label: "vui sướng cười tít"),
                ZolaStickerItem(stickerId: 19888, cateId: 10239, label: "đói bụng ăn thôi đi ăn"),
                ZolaStickerItem(stickerId: 19889, cateId: 10239, label: "mệt quá xỉu nghỉ ngơi"),
                ZolaStickerItem(stickerId: 19890, cateId: 10239, label: "giận dỗi hờn"),
                ZolaStickerItem(stickerId: 19891, cateId: 10239, label: "xin lỗi mà tha lỗi"),
                ZolaStickerItem(stickerId: 19892, cateId: 10239, label: "đi chơi dạo phố"),
            ]
        ),
        ZolaStickerPack(
            id: 10417,
            title: "Vui nhộn",
            stickers: [
                ZolaStickerItem(stickerId: 23285, cateId: 10417, label: "chúc mừng tung hoa thắng lợi"),
                ZolaStickerItem(stickerId: 23286, cateId: 10417, label: "ok tuyệt vời duyệt"),
                ZolaStickerItem(stickerId: 23287, cateId: 10417, label: "hóng drama ngạc nhiên"),
                ZolaStickerItem(stickerId: 23288, cateId: 10417, label: "cười lăn haha lầy"),
                ZolaStickerItem(stickerId: 23289, cateId: 10417, label: "cố lên chiến thôi"),
            ]
        ),
        ZolaStickerPack(
            id: 11790,
            title: "Hài hước",
            stickers: [
                ZolaStickerItem(stickerId: 43586, cateId: 11790, label: "hóng chuyện ngó nghiêng"),
                ZolaStickerItem(stickerId: 43587, cateId: 11790, label: "cười khoái chí hehe"),
                ZolaStickerItem(stickerId: 43588, cateId: 11790, label: "buồn thiu chán quá"),
                ZolaStickerItem(stickerId: 43589, cateId: 11790, label: "giận bốc khói tức"),
                ZolaStickerItem(stickerId: 43590, cateId: 11790, label: "mệt mỏi đuối sức"),
                ZolaStickerItem(stickerId: 43591, cateId: 11790, label: "cảm ơn bạn hiền"),
                ZolaStickerItem(stickerId: 43592, cateId: 11790, label: "ok chốt đơn đồng ý"),
                ZolaStickerItem(stickerId: 43593, cateId: 11790, label: "tạm biệt bye hẹn gặp lại"),
            ]
        ),
        ZolaStickerPack(
            id: 11917,
            title: "Công sở",
            stickers: [
                ZolaStickerItem(stickerId: 45600, cateId: 11917, label: "dạ vâng đã rõ nhận việc"),
                ZolaStickerItem(stickerId: 45601, cateId: 11917, label: "cảm ơn sếp đồng nghiệp"),
                ZolaStickerItem(stickerId: 45602, cateId: 11917, label: "cố lên deadline tăng ca"),
                ZolaStickerItem(stickerId: 45603, cateId: 11917, label: "mệt quá hết pin tan làm"),
                ZolaStickerItem(stickerId: 45604, cateId: 11917, label: "chúc mừng thành công xong việc"),
            ]
        ),
        ZolaStickerPack(
            id: 11980,
            title: "Thả tim",
            stickers: [
                ZolaStickerItem(stickerId: 46601, cateId: 11980, label: "yêu thương thả tim love"),
                ZolaStickerItem(stickerId: 46602, cateId: 11980, label: "nhớ anh nhớ em ôm"),
                ZolaStickerItem(stickerId: 46603, cateId: 11980, label: "ngủ ngon mơ đẹp yêu"),
                ZolaStickerItem(stickerId: 46604, cateId: 11980, label: "đói quá đi ăn trà sữa"),
                ZolaStickerItem(stickerId: 46605, cateId: 11980, label: "dỗi hờn giận nhẹ"),
                ZolaStickerItem(stickerId: 46606, cateId: 11980, label: "vui quá hạnh phúc"),
                ZolaStickerItem(stickerId: 46607, cateId: 11980, label: "xin lỗi thương mà"),
            ]
        ),
        ZolaStickerPack(
            id: 11711,
            title: "Tán gẫu",
            stickers: [
                ZolaStickerItem(stickerId: 42158, cateId: 11711, label: "xin chào alo hú"),
                ZolaStickerItem(stickerId: 42159, cateId: 11711, label: "đi chơi lên đường quẩy"),
                ZolaStickerItem(stickerId: 42160, cateId: 11711, label: "khóc ròng buồn quá"),
                ZolaStickerItem(stickerId: 42161, cateId: 11711, label: "tuyệt vời quá đỉnh"),
            ]
        ),
    ]

    /// Deduplicated flat list across all built-in packs for local offline keyword filtering.
    public static let allUniqueStickers: [ZolaStickerItem] = {
        var seen = Set<Int64>()
        var out: [ZolaStickerItem] = []
        for pack in packs {
            for item in pack.stickers where seen.insert(item.stickerId).inserted {
                out.append(item)
            }
        }
        return out
    }()
}

/// Result of matching a Vietnamese chat draft against contextual sticker triggers.
public struct ZolaContextualStickerMatch: Sendable, Equatable {
    public let canonicalKeyword: String
    public let queryKeyword: String
    public let displayLabel: String
    public let matchedWholeInput: Bool
    public let presets: [ZolaStickerItem]

    public init(
        canonicalKeyword: String,
        queryKeyword: String,
        displayLabel: String,
        matchedWholeInput: Bool,
        presets: [ZolaStickerItem]
    ) {
        self.canonicalKeyword = canonicalKeyword
        self.queryKeyword = queryKeyword
        self.displayLabel = displayLabel
        self.matchedWholeInput = matchedWholeInput
        self.presets = presets
    }
}

/// Telex-safe Vietnamese contextual sticker matcher for composer auto-suggestions and local picker search.
public enum ZolaStickerSuggester {
    private struct IntentRule: Sendable {
        let canonicalKeyword: String
        let queryKeyword: String
        let displayLabel: String
        let accentedTriggers: Set<String>
        let asciiTriggers: Set<String>
        let presets: [ZolaStickerItem]
    }

    private static let rules: [IntentRule] = [
        IntentRule(
            canonicalKeyword: "xin chao",
            queryKeyword: "xin chào",
            displayLabel: "Xin chào",
            accentedTriggers: ["xin chào", "chào", "chào buổi sáng", "chào nhé", "chào bạn", "chào sếp", "chào em", "chào anh", "chào chị"],
            asciiTriggers: ["xin chao", "chao", "hi", "hello", "helo", "alo", "hey", "hii", "hiii"],
            presets: [
                ZolaStickerItem(stickerId: 18082, cateId: 10134, label: "Xin chào"),
                ZolaStickerItem(stickerId: 19885, cateId: 10239, label: "Chào bạn"),
                ZolaStickerItem(stickerId: 42158, cateId: 11711, label: "Alo"),
            ]
        ),
        IntentRule(
            canonicalKeyword: "cam on",
            queryKeyword: "cảm ơn",
            displayLabel: "Cảm ơn",
            accentedTriggers: ["cảm ơn", "cám ơn", "cảm ơn nhé", "cảm ơn nhiều", "cảm ơn bạn", "cảm ơn sếp", "cảm ơn em", "cảm ơn anh", "cảm ơn chị", "đa tạ", "biết ơn"],
            asciiTriggers: ["cam on", "cam on nhe", "cam on nhieu", "tks", "tkss", "thanks", "thank", "thank you", "ths", "🙏"],
            presets: [
                ZolaStickerItem(stickerId: 18085, cateId: 10134, label: "Cảm ơn"),
                ZolaStickerItem(stickerId: 45601, cateId: 11917, label: "Cảm ơn"),
                ZolaStickerItem(stickerId: 43591, cateId: 11790, label: "Cảm ơn"),
            ]
        ),
        IntentRule(
            canonicalKeyword: "ok",
            queryKeyword: "ok",
            displayLabel: "Đồng ý",
            accentedTriggers: ["đồng ý", "nhất trí", "đã rõ", "dạ vâng", "chuẩn luôn", "chốt đơn", "duyệt", "được nhé", "ok nhé", "oke nhé"],
            asciiTriggers: ["ok", "oke", "oki", "okay", "okie", "okela", "dong y", "nhat tri", "duyet", "chot", "chot don", "👍", "👌"],
            presets: [
                ZolaStickerItem(stickerId: 18086, cateId: 10134, label: "OK"),
                ZolaStickerItem(stickerId: 23286, cateId: 10417, label: "Đồng ý"),
                ZolaStickerItem(stickerId: 43592, cateId: 11790, label: "Chốt"),
                ZolaStickerItem(stickerId: 45600, cateId: 11917, label: "Đã rõ"),
            ]
        ),
        IntentRule(
            canonicalKeyword: "haha",
            queryKeyword: "haha",
            displayLabel: "Vui vẻ",
            accentedTriggers: ["cười", "vui quá", "cười xỉu", "mắc cười", "buồn cười", "vui vẻ", "hạnh phúc"],
            asciiTriggers: ["haha", "hahaha", "hihi", "hehe", "hoho", "kaka", "kkk", "cuoi", "vui qua", ":)", ":))", "=))", ":d", "^^", "😂", "🤣", "😆", "😄"],
            presets: [
                ZolaStickerItem(stickerId: 18083, cateId: 10134, label: "Haha"),
                ZolaStickerItem(stickerId: 23288, cateId: 10417, label: "Cười"),
                ZolaStickerItem(stickerId: 43587, cateId: 11790, label: "Hehe"),
                ZolaStickerItem(stickerId: 19887, cateId: 10239, label: "Vui quá"),
            ]
        ),
        IntentRule(
            canonicalKeyword: "yeu",
            queryKeyword: "yêu",
            displayLabel: "Yêu thương",
            accentedTriggers: ["yêu", "yêu quá", "thương", "thương quá", "thả tim", "yêu anh", "yêu em", "cưng quá"],
            asciiTriggers: ["yeu", "yeu qua", "iu", "iu qua", "thuong", "tha tim", "love", "luv", "<3", ":3", "❤️", "💕", "🥰", "😍", "😘"],
            presets: [
                ZolaStickerItem(stickerId: 18084, cateId: 10134, label: "Yêu"),
                ZolaStickerItem(stickerId: 46601, cateId: 11980, label: "Thả tim"),
                ZolaStickerItem(stickerId: 46606, cateId: 11980, label: "Hạnh phúc"),
            ]
        ),
        IntentRule(
            canonicalKeyword: "nho",
            queryKeyword: "nhớ",
            displayLabel: "Nhớ nhung",
            accentedTriggers: ["nhớ", "nhớ quá", "nhớ anh", "nhớ em", "nhớ bạn", "ôm cái"],
            asciiTriggers: ["nho qua", "nho anh", "nho em", "miss you", "🤗"],
            presets: [
                ZolaStickerItem(stickerId: 19886, cateId: 10239, label: "Nhớ quá"),
                ZolaStickerItem(stickerId: 46602, cateId: 11980, label: "Nhớ"),
                ZolaStickerItem(stickerId: 18084, cateId: 10134, label: "Thương"),
            ]
        ),
        IntentRule(
            canonicalKeyword: "buon",
            queryKeyword: "buồn",
            displayLabel: "Buồn",
            accentedTriggers: ["buồn", "buồn quá", "chán", "chán quá", "tủi thân", "thất vọng", "sầu"],
            asciiTriggers: ["buon", "buon qua", "chan qua", "sad", ":(", ":((", "😔", "😞", "🥺"],
            presets: [
                ZolaStickerItem(stickerId: 18087, cateId: 10134, label: "Buồn"),
                ZolaStickerItem(stickerId: 43588, cateId: 11790, label: "Chán quá"),
                ZolaStickerItem(stickerId: 42160, cateId: 11711, label: "Tủi thân"),
            ]
        ),
        IntentRule(
            canonicalKeyword: "khoc",
            queryKeyword: "khóc",
            displayLabel: "Khóc",
            accentedTriggers: ["khóc", "khóc luôn", "rớt nước mắt"],
            asciiTriggers: ["khoc", "huhu", "huhuhu", "hic", "hichic", "T_T", "t_t", "😭", "😢"],
            presets: [
                ZolaStickerItem(stickerId: 42160, cateId: 11711, label: "Khóc"),
                ZolaStickerItem(stickerId: 18087, cateId: 10134, label: "Huhu"),
            ]
        ),
        IntentRule(
            canonicalKeyword: "co len",
            queryKeyword: "cố lên",
            displayLabel: "Cố lên",
            accentedTriggers: ["cố lên", "cố gắng", "quyết tâm", "chiến thôi", "mạnh mẽ"],
            asciiTriggers: ["co len", "co gang", "quyet tam", "fighting", "💪", "🔥"],
            presets: [
                ZolaStickerItem(stickerId: 18088, cateId: 10134, label: "Cố lên"),
                ZolaStickerItem(stickerId: 23289, cateId: 10417, label: "Chiến thôi"),
                ZolaStickerItem(stickerId: 45602, cateId: 11917, label: "Quyết tâm"),
            ]
        ),
        IntentRule(
            canonicalKeyword: "chuc mung",
            queryKeyword: "chúc mừng",
            displayLabel: "Chúc mừng",
            accentedTriggers: ["chúc mừng", "sinh nhật vui vẻ", "chúc mừng sinh nhật", "tung hoa", "thành công"],
            asciiTriggers: ["chuc mung", "hpbd", "happy birthday", "cmsn", "congrats", "🎉", "🥳", "🎂"],
            presets: [
                ZolaStickerItem(stickerId: 23285, cateId: 10417, label: "Chúc mừng"),
                ZolaStickerItem(stickerId: 45604, cateId: 11917, label: "Thành công"),
                ZolaStickerItem(stickerId: 23286, cateId: 10417, label: "Tuyệt vời"),
            ]
        ),
        IntentRule(
            canonicalKeyword: "tuyet voi",
            queryKeyword: "tuyệt vời",
            displayLabel: "Tuyệt vời",
            accentedTriggers: ["tuyệt vời", "tuyệt quá", "đỉnh quá", "quá đỉnh", "xuất sắc", "hay quá"],
            asciiTriggers: ["tuyet voi", "dinh qua", "qua dinh", "xuat sac", "hay qua", "awesome", "👏", "💯"],
            presets: [
                ZolaStickerItem(stickerId: 23286, cateId: 10417, label: "Tuyệt vời"),
                ZolaStickerItem(stickerId: 42161, cateId: 11711, label: "Quá đỉnh"),
                ZolaStickerItem(stickerId: 18086, cateId: 10134, label: "Chuẩn"),
            ]
        ),
        IntentRule(
            canonicalKeyword: "ngu ngon",
            queryKeyword: "ngủ ngon",
            displayLabel: "Ngủ ngon",
            accentedTriggers: ["ngủ ngon", "chúc ngủ ngon", "mơ đẹp", "đi ngủ", "buồn ngủ"],
            asciiTriggers: ["ngu ngon", "chuc ngu ngon", "g9", "good night", "goodnight", "😴", "🌙"],
            presets: [
                ZolaStickerItem(stickerId: 18089, cateId: 10134, label: "Ngủ ngon"),
                ZolaStickerItem(stickerId: 46603, cateId: 11980, label: "Mơ đẹp"),
            ]
        ),
        IntentRule(
            canonicalKeyword: "met qua",
            queryKeyword: "mệt quá",
            displayLabel: "Mệt mỏi",
            accentedTriggers: ["mệt", "mệt quá", "mệt mỏi", "đuối quá", "xỉu", "kiệt sức", "hết pin"],
            asciiTriggers: ["met qua", "met moi", "duoi qua", "het pin", "😩", "😫", "😮‍💨"],
            presets: [
                ZolaStickerItem(stickerId: 19889, cateId: 10239, label: "Mệt quá"),
                ZolaStickerItem(stickerId: 43590, cateId: 11790, label: "Đuối"),
                ZolaStickerItem(stickerId: 45603, cateId: 11917, label: "Hết pin"),
            ]
        ),
        IntentRule(
            canonicalKeyword: "xin loi",
            queryKeyword: "xin lỗi",
            displayLabel: "Xin lỗi",
            accentedTriggers: ["xin lỗi", "xin lỗi nhé", "tha lỗi", "ngại quá", "thông cảm"],
            asciiTriggers: ["xin loi", "sorry", "sr", "srr", "🙇"],
            presets: [
                ZolaStickerItem(stickerId: 18090, cateId: 10134, label: "Xin lỗi"),
                ZolaStickerItem(stickerId: 19891, cateId: 10239, label: "Tha lỗi"),
                ZolaStickerItem(stickerId: 46607, cateId: 11980, label: "Thương mà"),
            ]
        ),
        IntentRule(
            canonicalKeyword: "gian",
            queryKeyword: "giận",
            displayLabel: "Giận dỗi",
            accentedTriggers: ["giận", "giận quá", "giận dỗi", "dỗi", "hờn", "tức quá", "bực mình", "ghét"],
            asciiTriggers: ["gian qua", "gian doi", "tuc qua", "buc minh", "😡", "😠", "😤"],
            presets: [
                ZolaStickerItem(stickerId: 19890, cateId: 10239, label: "Dỗi"),
                ZolaStickerItem(stickerId: 43589, cateId: 11790, label: "Giận"),
                ZolaStickerItem(stickerId: 46605, cateId: 11980, label: "Hờn"),
            ]
        ),
        IntentRule(
            canonicalKeyword: "doi",
            queryKeyword: "đói",
            displayLabel: "Đói bụng",
            accentedTriggers: ["đói", "đói quá", "đói bụng", "đi ăn", "ăn cơm", "trà sữa", "nhậu"],
            asciiTriggers: ["doi qua", "doi bung", "di an", "an com", "tra sua", "🍜", "🧋", "😋"],
            presets: [
                ZolaStickerItem(stickerId: 19888, cateId: 10239, label: "Đói bụng"),
                ZolaStickerItem(stickerId: 46604, cateId: 11980, label: "Đi ăn"),
            ]
        ),
        IntentRule(
            canonicalKeyword: "di choi",
            queryKeyword: "đi chơi",
            displayLabel: "Đi chơi",
            accentedTriggers: ["đi chơi", "dạo phố", "lên đường", "quẩy", "cà phê"],
            asciiTriggers: ["di choi", "len duong", "ca phe", "cafe", "🚀"],
            presets: [
                ZolaStickerItem(stickerId: 19892, cateId: 10239, label: "Đi chơi"),
                ZolaStickerItem(stickerId: 42159, cateId: 11711, label: "Quẩy"),
            ]
        ),
        IntentRule(
            canonicalKeyword: "hong",
            queryKeyword: "hóng",
            displayLabel: "Hóng",
            accentedTriggers: ["hóng", "bất ngờ", "ngạc nhiên", "thật hả", "ủa"],
            asciiTriggers: ["hong", "wow", "omg", "😮", "😲", "👀"],
            presets: [
                ZolaStickerItem(stickerId: 43586, cateId: 11790, label: "Hóng"),
                ZolaStickerItem(stickerId: 23287, cateId: 10417, label: "Ngạc nhiên"),
            ]
        ),
        IntentRule(
            canonicalKeyword: "tam biet",
            queryKeyword: "tạm biệt",
            displayLabel: "Tạm biệt",
            accentedTriggers: ["tạm biệt", "hẹn gặp lại", "về nhé", "về đây"],
            asciiTriggers: ["tam biet", "bye", "byebye", "bai bai", "👋"],
            presets: [
                ZolaStickerItem(stickerId: 43593, cateId: 11790, label: "Tạm biệt"),
                ZolaStickerItem(stickerId: 18082, cateId: 10134, label: "Tạm biệt"),
            ]
        ),
    ]

    private static let accentedLookup: [String: IntentRule] = {
        var map: [String: IntentRule] = [:]
        for rule in rules {
            for phrase in rule.accentedTriggers {
                let norm = ZolaTextNormalizer.normalizePreservingDiacritics(phrase)
                if !norm.isEmpty && map[norm] == nil {
                    map[norm] = rule
                }
            }
        }
        return map
    }()

    private static let asciiLookup: [String: IntentRule] = {
        var map: [String: IntentRule] = [:]
        for rule in rules {
            for phrase in rule.asciiTriggers {
                let norm = ZolaTextNormalizer.normalizePreservingDiacritics(phrase)
                if !norm.isEmpty && map[norm] == nil {
                    map[norm] = rule
                }
            }
        }
        return map
    }()

    /// Single-word ASCII tokens that are natural whole-message triggers (`"hi"`, `"buon"`, `"yeu"`, `"sr"`, `"chao"`)
    /// but collide with common multi-word Vietnamese compounds when unaccented (`"hi vọng"`, `"thoi gian"`, `"chao đèn"`).
    private static let wholeOnlyAsciiTokens: Set<String> = [
        "chao", "hi", "hey", "ths", "chot", "cuoi", "yeu", "iu",
        "thuong", "buon", "khoc", "sr", "srr", "gian", "hong",
    ]

    /// Vietnamese negation prefixes that invert emotion/intent (`"không buồn"`, `"đừng khóc"`, `"chưa đói"`, `"hết mệt"`).
    private static let negationTokens: Set<String> = [
        "không", "khong", "ko", "k", "chưa", "chua", "đừng", "dung",
        "chẳng", "chang", "chả", "cha", "hết", "het", "đỡ", "do", "khỏi", "khoi",
    ]

    private static func stripEdgePunctuation(_ raw: String) -> String {
        let trimChars = CharacterSet(charactersIn: ".,!?;:\"'“”‘’~`•-–—()[]{}")
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: trimChars)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func matchCandidate(_ rawCandidate: String, allowWholeOnlyAscii: Bool = true) -> IntentRule? {
        let trimmed = rawCandidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Check exact emoticon/emoji first before punctuation stripping (`:)`, `:(`, `<3`, `:3`, `^^`).
        let exactPreserved = ZolaTextNormalizer.normalizePreservingDiacritics(trimmed)
        if !ZolaTextNormalizer.hasVietnameseDiacritics(exactPreserved),
           let emoticonRule = asciiLookup[exactPreserved] {
            if !allowWholeOnlyAscii && wholeOnlyAsciiTokens.contains(exactPreserved) {
                return nil
            }
            return emoticonRule
        }

        let cleaned = stripEdgePunctuation(trimmed)
        guard !cleaned.isEmpty else { return nil }
        let normalized = ZolaTextNormalizer.normalizePreservingDiacritics(cleaned)
        guard !normalized.isEmpty else { return nil }

        // Telex-safe Vietnamese rule:
        // When the candidate already carries Vietnamese diacritics (e.g. `"buôn"` mid-Telex before `f` -> `"buồn"`),
        // ONLY match exact accented Vietnamese triggers — never fold diacritics down to `"buon"`!
        if ZolaTextNormalizer.hasVietnameseDiacritics(normalized) {
            return accentedLookup[normalized]
        } else {
            if !allowWholeOnlyAscii && wholeOnlyAsciiTokens.contains(normalized) {
                return nil
            }
            return asciiLookup[normalized]
        }
    }

    /// Evaluates composer draft `rawInput` in `< 0.1ms` and returns a Telex-safe `ZolaContextualStickerMatch` when applicable.
    ///
    /// - Supports 1..6 word chat phrases (`whole` -> `tail3` -> `tail2` -> `lastWord` -> `head2` -> `firstWord`).
    /// - Respects Vietnamese negation prefixes (`"không buồn"`, `"đừng khóc"`, `"chưa đói"`) and homograph guards.
    /// - Ignores URLs, slash commands, and long multi-sentence paragraphs (`> 6` words).
    public static func instantMatch(for rawInput: String) -> ZolaContextualStickerMatch? {
        let trimmed = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 64 else { return nil }
        let lower = trimmed.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("/") {
            return nil
        }

        let words = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty, words.count <= 6 else { return nil }

        if let wholeRule = matchCandidate(trimmed, allowWholeOnlyAscii: true) {
            return ZolaContextualStickerMatch(
                canonicalKeyword: wholeRule.canonicalKeyword,
                queryKeyword: wholeRule.queryKeyword,
                displayLabel: wholeRule.displayLabel,
                matchedWholeInput: true,
                presets: wholeRule.presets
            )
        }

        guard words.count >= 2 else { return nil }
        var partialSlices: [(startIndex: Int, text: String)] = []
        if words.count >= 3 {
            partialSlices.append((words.count - 3, words.suffix(3).joined(separator: " ")))
        }
        partialSlices.append((words.count - 2, words.suffix(2).joined(separator: " ")))
        if let last = words.last {
            partialSlices.append((words.count - 1, last))
        }
        partialSlices.append((0, words.prefix(2).joined(separator: " ")))
        if let first = words.first {
            partialSlices.append((0, first))
        }

        for slice in partialSlices {
            if slice.startIndex > 0 {
                let prevNorm = ZolaTextNormalizer.normalizePreservingDiacritics(
                    stripEdgePunctuation(words[slice.startIndex - 1])
                )
                if negationTokens.contains(prevNorm) {
                    continue
                }
            }
            if let rule = matchCandidate(slice.text, allowWholeOnlyAscii: false) {
                return ZolaContextualStickerMatch(
                    canonicalKeyword: rule.canonicalKeyword,
                    queryKeyword: rule.queryKeyword,
                    displayLabel: rule.displayLabel,
                    matchedWholeInput: false,
                    presets: rule.presets
                )
            }
        }
        return nil
    }

    /// Instant local search across `ZolaStickerCatalog` + contextual intent rules (used in the Sticker Picker search bar).
    public static func searchCatalog(query: String) -> [ZolaStickerItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ZolaStickerCatalog.packs.first?.stickers ?? [] }

        var seen = Set<Int64>()
        var results: [ZolaStickerItem] = []

        if let match = instantMatch(for: trimmed) {
            for item in match.presets where seen.insert(item.stickerId).inserted {
                results.append(item)
            }
        }

        let hasDiacritics = ZolaTextNormalizer.hasVietnameseDiacritics(trimmed)
        let normPreserved = ZolaTextNormalizer.normalizePreservingDiacritics(trimmed)
        let normFolded = ZolaTextNormalizer.foldVietnamese(trimmed)

        for item in ZolaStickerCatalog.allUniqueStickers where !seen.contains(item.stickerId) {
            let labelPreserved = ZolaTextNormalizer.normalizePreservingDiacritics(item.label)
            let labelFolded = ZolaTextNormalizer.foldVietnamese(item.label)
            let matched = hasDiacritics
                ? labelPreserved.contains(normPreserved)
                : (labelFolded.contains(normFolded) || String(item.stickerId) == normFolded)
            if matched, seen.insert(item.stickerId).inserted {
                results.append(item)
            }
        }
        return results
    }
}

// MARK: - Native Zalo iOS Sticker Suggestion & Search (`https://stickers.zaloapp.com`, `zpw_type = 24`)

extension ZolaClient {
    /// Optional sink for sanitized sticker-suggestion diagnostics (status/code/counts only). The app
    /// routes it to its on-disk diagnostics so the path can be verified on a real device.
    nonisolated(unsafe) public static var stickerDiagnosticHandler: (@Sendable (String) -> Void)?

    private func resolvedNativeStickerBaseURL() -> String {
        if let host = session.serviceHosts?["sticker"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !host.isEmpty,
           !Self.isForbiddenWebWpaURL(host) {
            return host
        }
        return "https://stickers.zaloapp.com"
    }

    /// Executes an encrypted Mode-2 (`zcid`) GET call against `https://stickers.zaloapp.com` without ever
    /// latching `session.markExpired` on auxiliary sticker-service errors.
    private func callNativeStickerEndpoint(
        endpoint: String,
        params: [String: Any]
    ) async throws -> [String: Any] {
        try assertSessionAlive()
        guard session.zcidIsNative else {
            return [:]
        }
        var inner = params
        if inner["imei"] == nil {
            inner["imei"] = ZolaCrypto.extractZCIDIdentity(zcid: session.zcid).imei
        }
        let baseURL = resolvedNativeStickerBaseURL()
        let fullURL = "\(baseURL)/\(endpoint)"
        guard !Self.isForbiddenWebWpaURL(fullURL) else {
            return [:]
        }
        let req = try ZolaRequestBuilder.buildEncryptedRequest(
            url: fullURL,
            innerParams: inner,
            session: session,
            method: "GET"
        )
        let (status, raw) = try await executeSessionRequest(req)
        let body = ZolaRequestBuilder.gunzipDecompress(raw) ?? raw
        let shortName = endpoint.components(separatedBy: "/").last ?? endpoint
        // Sanitized diagnostics (status/code/key names/count only): this path used to fail silently.
        func note(_ code: Int, _ data: [String: Any]) {
            let count = Self.parseStickerItems(from: data).count
            NSLog("zolakit sticker-suggest ep=%@ http=%d code=%d keys=%@ items=%d",
                  shortName, status, code, data.keys.sorted().joined(separator: ","), count)
            Self.stickerDiagnosticHandler?("sticker ep=\(shortName) http=\(status) code=\(code) keys=\(data.keys.sorted().joined(separator: ",")) items=\(count)")
        }
        guard let env = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
            NSLog("zolakit sticker-suggest ep=%@ http=%d non-json bytes=%d", shortName, status, body.count)
            Self.stickerDiagnosticHandler?("sticker ep=\(shortName) http=\(status) non-json bytes=\(body.count)")
            return [:]
        }
        let code = env["error_code"] != nil ? ZolaJSON.int(env["error_code"]) : 0
        guard code == 0 else {
            note(code, [:])
            return [:]
        }
        if let hex = env["data"] as? String, !hex.isEmpty {
            let decoded = (try? ZolaCrypto.decryptZCIDParams(hex, zcid: session.zcid)) ?? [:]
            note(code, decoded)
            return decoded
        }
        if let dict = env["data"] as? [String: Any] {
            note(code, dict)
            return dict
        }
        note(code, [:])
        return [:]
    }

    internal static func parseStickerItems(
        from data: [String: Any],
        fallbackLabel: String = "",
        defaultCateId: Int64 = 0
    ) -> [ZolaStickerItem] {
        var seen = Set<Int64>()
        var out: [ZolaStickerItem] = []

        func appendItem(sid: Int64, cid: Int64 = 0, stype: Int = 0, text: String = "") {
            guard sid > 0, seen.insert(sid).inserted else { return }
            let resolvedCid = cid > 0 ? cid : max(0, defaultCateId)
            out.append(
                ZolaStickerItem(
                    stickerId: sid,
                    cateId: resolvedCid,
                    stickerType: max(0, stype),
                    label: text.isEmpty ? fallbackLabel : text
                )
            )
        }

        func ingestEntry(_ anyVal: Any) {
            if let dict = anyVal as? [String: Any] {
                let sid = ZolaJSON.int64(dict["id"] ?? dict["stickerId"] ?? dict["sid"] ?? dict["eid"])
                let cid = ZolaJSON.int64(dict["cateId"] ?? dict["catId"] ?? dict["cid"])
                let stype = ZolaJSON.int(dict["type"] ?? dict["stickerType"], default: 0)
                let lbl = ZolaJSON.string(dict["text"] ?? dict["keyword"] ?? dict["name"])
                appendItem(sid: sid, cid: cid, stype: stype, text: lbl)
            } else {
                let sid = ZolaJSON.int64(anyVal)
                appendItem(sid: sid)
            }
        }

        for key in ["stickers", "sids", "list", "items", "data"] {
            if let arr = data[key] as? [Any] {
                for entry in arr {
                    ingestEntry(entry)
                }
            }
        }
        return out
    }

    public static let stickerStoreLandingURL = "https://stickers.zaloapp.com/sticker"
    public static let stickerStoreCatalogCDNURL = "https://zalo-api.zadn.vn/api/emoticon/pcweb/getAllCate"

    /// Fetches the public Zalo Sticker Store pack catalog (`https://stickers.zaloapp.com/sticker` with
    /// fallback to `https://zalo-api.zadn.vn/api/emoticon/pcweb/getAllCate`), sorted newest first.
    public func fetchStickerStorePacks() async -> [ZolaStickerStorePack] {
        for candidateURL in [Self.stickerStoreLandingURL, Self.stickerStoreCatalogCDNURL] {
            guard let url = URL(string: candidateURL) else { continue }
            var req = URLRequest(url: url)
            req.httpMethod = "GET"
            req.timeoutInterval = 8
            req.setValue("application/json, */*", forHTTPHeaderField: "Accept")
            if let (status, raw) = try? await executeSessionRequest(req), status == 200, !raw.isEmpty {
                let parsed = ZolaStickerStorePack.parseCatalog(from: raw)
                if !parsed.isEmpty {
                    for pack in parsed where pack.id > 0 && !pack.storeCid.isEmpty {
                        stickerStoreCidCache[pack.id] = pack.storeCid
                    }
                    return parsed
                }
            }
        }
        return ZolaStickerCatalog.packs
            .filter { $0.id >= 0 }
            .map { pack in
                let firstPreview = pack.stickers.first?.cdnUrl ?? ""
                return ZolaStickerStorePack(
                    id: pack.id,
                    name: pack.title,
                    desc: "Bộ nhãn dán tích hợp sẵn",
                    totalImage: pack.stickers.count,
                    iconUrl: firstPreview,
                    thumbImg: firstPreview
                )
            }
    }

    /// Resolves all sticker items inside a Sticker Store pack (`cateId`), querying
    /// `GET https://stickers.zaloapp.com/cate-stickers?cid=<storeCid>` when `storeCid` is known,
    /// falling back to native `api/message/sticker/category/sticker_detail`, built-in packs, or keyword search.
    public func fetchStickerPackItems(
        cateId: Int64,
        storeCid: String = "",
        fallbackTitle: String = ""
    ) async -> [ZolaStickerItem] {
        if cateId == ZolaStickerCatalog.onionPackId {
            return ZolaStickerCatalog.onionPack.stickers
        }
        if cateId == ZolaStickerCatalog.popularPackId {
            return ZolaStickerCatalog.packs.first(where: { $0.id == ZolaStickerCatalog.popularPackId })?.stickers ?? []
        }
        guard cateId > 0 else { return [] }

        let trimmedStoreCid = storeCid.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedStoreCid.isEmpty {
            stickerStoreCidCache[cateId] = trimmedStoreCid
        } else if stickerStoreCidCache[cateId] == nil, transport is ZolaURLSessionTransport {
            _ = await fetchStickerStorePacks()
        }

        if let resolvedStoreCid = stickerStoreCidCache[cateId], !resolvedStoreCid.isEmpty {
            let encodedCid = ZolaRequestBuilder.urlEncode(resolvedStoreCid)
            let baseHost = resolvedNativeStickerBaseURL().replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
            if let url = URL(string: "\(baseHost)/cate-stickers?cid=\(encodedCid)") {
                var req = URLRequest(url: url)
                req.httpMethod = "GET"
                req.timeoutInterval = 8
                req.setValue("application/json, */*", forHTTPHeaderField: "Accept")
                if let (status, raw) = try? await executeSessionRequest(req), status == 200, !raw.isEmpty {
                    let parsed = ZolaStickerStorePack.parseCateStickers(
                        from: raw,
                        cateId: cateId,
                        fallbackLabel: fallbackTitle
                    )
                    if !parsed.isEmpty {
                        return parsed
                    }
                }
            }
        }

        if !session.isExpired, session.zcidIsNative {
            for endpoint in [
                "api/message/sticker/category/sticker_detail",
                "api/message/sticker/cate_detail",
            ] {
                if let data = try? await callNativeStickerEndpoint(
                    endpoint: endpoint,
                    params: ["cid": String(cateId)]
                ) {
                    let parsed = Self.parseStickerItems(from: data, fallbackLabel: fallbackTitle, defaultCateId: cateId)
                    if !parsed.isEmpty {
                        return parsed
                    }
                }
            }
            if !fallbackTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let searched = try? await searchStickers(fallbackTitle, limit: 24),
               !searched.isEmpty {
                let sameCate = searched.filter { $0.cateId == cateId }
                return sameCate.isEmpty ? searched : sameCate
            }
        }

        if let builtin = ZolaStickerCatalog.packs.first(where: { $0.id == cateId }) {
            return builtin.stickers
        }
        if !fallbackTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let local = ZolaStickerSuggester.searchCatalog(query: fallbackTitle)
            if !local.isEmpty {
                return local
            }
        }
        return []
    }

    /// Queries native `GET https://stickers.zaloapp.com/api/message/sticker/search` (`Mode 2` `zcid`).
    public func searchStickers(_ keyword: String, limit: Int = 20) async throws -> [ZolaStickerItem] {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, limit > 0 else { return [] }
        let clampedLimit = min(max(1, limit), 40)
        let data = try await callNativeStickerEndpoint(
            endpoint: "api/message/sticker/search",
            params: [
                "keyword": trimmed,
                "limit": clampedLimit,
                "gif": 1,
            ]
        )
        return Array(Self.parseStickerItems(from: data, fallbackLabel: trimmed).prefix(clampedLimit))
    }

    /// Queries native `suggest/stickers` and `sticker/search` in parallel on `https://stickers.zaloapp.com`
    /// and merges them with verified `ZolaStickerSuggester` presets (deduplicated by `stickerId`).
    public func suggestContextualStickers(
        for rawInput: String,
        limit: Int = 16
    ) async -> [ZolaStickerItem] {
        guard limit > 0 else { return [] }
        let match = ZolaStickerSuggester.instantMatch(for: rawInput)
        let query: String
        let presets: [ZolaStickerItem]
        if let match {
            query = match.queryKeyword
            presets = match.presets
        } else {
            let trimmed = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.count <= 32 else { return [] }
            query = trimmed
            presets = ZolaStickerSuggester.searchCatalog(query: trimmed)
        }

        // The hand-picked preset IDs were labelled by guess (e.g. 18082 "Xin chào" is a baby "chụt chụt"),
        // so the strip only shows what Zalo itself suggests for the keyword. Without a native session
        // there is no source of truth: show nothing rather than unrelated stickers.
        _ = presets
        if session.isExpired || !session.zcidIsNative {
            NSLog("zolakit sticker-suggest skipped expired=%d native=%d", session.isExpired ? 1 : 0, session.zcidIsNative ? 1 : 0)
            Self.stickerDiagnosticHandler?("sticker skipped expired=\(session.isExpired ? 1 : 0) native=\(session.zcidIsNative ? 1 : 0)")
            return []
        }

        let clampedLimit = min(max(4, limit), 32)
        async let suggestDataTask: [String: Any]? = try? await callNativeStickerEndpoint(
            endpoint: "api/message/sticker/suggest/stickers",
            params: [
                "keyword": query,
                "gif": 1,
                "guggy": 0,
            ]
        )
        async let searchDataTask: [String: Any]? = try? await callNativeStickerEndpoint(
            endpoint: "api/message/sticker/search",
            params: [
                "keyword": query,
                "limit": clampedLimit,
                "gif": 1,
            ]
        )

        let (suggestData, searchData) = await (suggestDataTask, searchDataTask)
        let suggestedItems = suggestData.map { Self.parseStickerItems(from: $0, fallbackLabel: query) } ?? []
        let searchedItems = searchData.map { Self.parseStickerItems(from: $0, fallbackLabel: query) } ?? []

        var mergedById: [Int64: ZolaStickerItem] = [:]
        var orderedIds: [Int64] = []

        func merge(_ item: ZolaStickerItem) {
            guard item.stickerId > 0 else { return }
            if let existing = mergedById[item.stickerId] {
                if existing.cateId == 0 && item.cateId > 0 {
                    mergedById[item.stickerId] = ZolaStickerItem(
                        stickerId: existing.stickerId,
                        cateId: item.cateId,
                        stickerType: item.stickerType,
                        label: existing.label.isEmpty ? item.label : existing.label
                    )
                }
            } else {
                mergedById[item.stickerId] = item
                orderedIds.append(item.stickerId)
            }
        }

        // Zalo's keyword suggestions first, then keyword search results; no local presets.
        for s in suggestedItems { merge(s) }
        for s in searchedItems { merge(s) }

        return orderedIds.prefix(limit).compactMap { mergedById[$0] }
    }
}
