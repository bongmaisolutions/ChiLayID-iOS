import Foundation

/// Narrow native201 schemas verified against live group traffic.
/// No detail endpoint/template URL is fetched; note events carry only a preview.
internal enum ZolaNativeGroupBoardNotice {
    struct Result {
        let kind: String
        let text: String?
        let resolvedMsgType: String?
        let card: ZolaBoardCard?
    }

    static func parse(msgType: String, attach: [String: Any], senderUid: Int64, senderName: String) -> Result? {
        guard ZolaJSON.string(attach["href"]).isEmpty,
              let params = dictionary(attach["params"]) else { return nil }
        let isNote = ZolaJSON.string(attach["action"]) == "msginfo.actionlist"
        let isCalendar = msgType.lowercased() == "chat.webcontent"
        guard isNote || isCalendar else { return nil }
        let info: [String: Any]
        if isNote { info = params }
        else { guard let custom = params["customMsg"] as? [String: Any] else { return nil }; info = custom }
        guard let actions = info["actions"] as? [[String: Any]], actions.count == 1,
              let highlights = info["highLightsV2"] as? [[String: Any]], (2...3).contains(highlights.count),
              ZolaJSON.int64(highlights[0]["uid"]) == senderUid, senderUid > 0,
              ZolaJSON.int64(highlights[1]["uid"]) == 0,
              let title = boundedText(highlights[1]["dpn"]) else { return nil }
        let creator = boundedText(highlights[0]["dpn"]) ?? boundedText(senderName) ?? "Một thành viên"
        let action = ZolaJSON.string(actions[0]["actionType"])
        guard let actionData = dictionary(actions[0]["actionData"]) else { return nil }

        let templates = info["msg"] as? [String: Any]
        if isNote {
            guard ZolaJSON.string(templates?["en"]) == "%1$s created a note %2$s."
                    || ZolaJSON.string(templates?["vi"]) == "%1$s tạo ghi chú %2$s." else { return nil }
            guard action == "action.open.grouptopic.detail",
                  ZolaJSON.int64(actionData["topicId"]) > 0,
                  ZolaJSON.int64(actionData["topicType"], default: -1) == 0,
                  highlights.count == 2,
                  ZolaJSON.int64(highlights[1]["type"], default: -1) == 1 else { return nil }
            return Result(kind: "board", text: nil, resolvedMsgType: "msginfo.actionlist",
                card: ZolaBoardCard(kind: .note, title: title, creatorUid: senderUid,
                    creatorName: creator, actionText: "đã tạo ghi chú", isPreviewOnly: true))
        }
        guard ZolaJSON.int64(highlights[1]["type"], default: -1) == 0 else { return nil }
        if action == "action.open.calendar.event" {
            guard ZolaJSON.string(templates?["en"]) == "%1$s created a new time reminder %2$s – %3$s"
                    || ZolaJSON.string(templates?["vi"]) == "%1$s tạo nhắc hẹn mới %2$s – %3$s" else { return nil }
            guard ZolaJSON.int64(actionData["eventId"]) > 0, highlights.count == 3,
                  ZolaJSON.int64(highlights[2]["uid"]) == 0,
                  ZolaJSON.int64(highlights[2]["type"], default: -1) == 1 else { return nil }
            let startMs = ZolaJSON.int64(highlights[2]["ts"])
            // Captured native field is milliseconds. Do not infer seconds for this schema.
            guard (1_000_000_000_000...253_402_300_799_999).contains(startMs) else { return nil }
            return Result(kind: "board", text: "\(creator) đã tạo nhắc hẹn \(title)", resolvedMsgType: nil,
                card: ZolaBoardCard(kind: .reminder, title: title, startMs: startMs,
                    creatorUid: senderUid, creatorName: creator, actionText: "đã tạo nhắc hẹn"))
        }
        guard action == "action.group.create.reminder", actionData.isEmpty,
              highlights.count == 2, ZolaJSON.int64(params["forceShowMsgInfo"]) == 1,
              ZolaJSON.string(templates?["en"]) == "%1$s removed time reminder %2$s."
                || ZolaJSON.string(templates?["vi"]) == "%1$s xóa nhắc hẹn %2$s." else { return nil }
        return Result(kind: "system", text: "\(creator) đã xóa nhắc hẹn \(title)", resolvedMsgType: nil, card: nil)
    }

    private static func dictionary(_ value: Any?) -> [String: Any]? {
        if let dict = value as? [String: Any], dict.count <= 64 { return dict }
        guard let text = value as? String, text.utf8.count <= 64 * 1024,
              let data = text.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any], dict.count <= 64 else { return nil }
        return dict
    }

    private static func boundedText(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, cleaned.utf8.count <= 4096 else { return nil }
        return cleaned
    }
}
