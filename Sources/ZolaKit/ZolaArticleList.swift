import Foundation

/// Conservative extraction of readable cards from OA list envelopes. Unknown native templates
/// remain a readable placeholder; this is not a renderer for executable OA actions or HTML.
internal enum ZolaArticleList {
    static func parse(_ roots: [Any]) -> [ZolaAttachment] {
        var cards: [ZolaAttachment] = []
        var visited = 0
        var seen = Set<String>()
        let containers = ["articles", "items", "list", "data", "params", "attach", "content", "msg"]

        func decoded(_ value: Any) -> Any {
            guard let string = value as? String, string.utf8.count <= 65_536,
                  let first = string.trimmingCharacters(in: .whitespacesAndNewlines).first,
                  first == "{" || first == "[",
                  let data = string.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) else { return value }
            return object
        }
        func text(_ value: Any?) -> String {
            guard let string = value as? String else { return "" }
            let value = string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard value != "sendBubbleMessage", !value.hasPrefix("{"), !value.hasPrefix("[") else { return "" }
            return String(value.prefix(8_192))
        }
        func url(_ value: Any?) -> String {
            let value = text(value)
            guard let components = URLComponents(string: value),
                  components.scheme?.lowercased() == "https", components.host?.isEmpty == false,
                  components.user == nil, components.password == nil else { return "" }
            return value
        }
        func walk(_ value: Any, depth: Int) {
            guard depth <= 6, visited < 256, cards.count < 20 else { return }
            visited += 1
            let node = decoded(value)
            if let array = node as? [Any] {
                for child in array.prefix(64) { walk(child, depth: depth + 1) }
                return
            }
            guard let item = node as? [String: Any] else { return }
            let before = cards.count
            // Preserve list order and prefer leaf cards over envelope headings.
            for key in containers {
                if let child = item[key] {
                    if key == "params", let dictionary = decoded(child) as? [String: Any],
                       !containers.contains(where: { dictionary[$0] != nil }) { continue }
                    walk(child, depth: depth + 1)
                }
            }
            guard cards.count == before else { return }
            let params = item["params"].map(decoded) as? [String: Any] ?? [:]
            let title = text(item["title"] ?? params["title"])
            let description = text(item["description"] ?? item["desc"] ?? params["description"])
            let href = url(item["href"] ?? item["url"] ?? params["href"] ?? params["url"])
            let thumb = url(item["thumb"] ?? item["thumbUrl"] ?? params["thumb"])
            guard !title.isEmpty || !description.isEmpty || !href.isEmpty || !thumb.isEmpty else { return }
            let identity = [title, description, href, thumb].joined(separator: "\u{0}")
            guard seen.insert(identity).inserted else { return }
            cards.append(ZolaAttachment(kind: "article", url: href, thumbUrl: thumb,
                                        title: title, descriptionText: description))
        }
        for root in roots { walk(root, depth: 0) }
        return cards
    }
}
