import Foundation

/// Text and rules for the ring that do not need AppKit, so they are tested directly.
enum RingSettingsPresentation {
    static let symbol = "circle.circle"

    /// Symbols offered in the editor's icon picker.
    static let symbolChoices = [
        "mic", "sparkles", "bubble.left.and.bubble.right", "camera.viewfinder", "text.viewfinder", "character.bubble",
        "doc.on.clipboard", "note.text", "character.book.closed", "person.crop.rectangle.stack", "wand.and.stars",
        "command", "app", "keyboard", "link", "folder", "circle.lefthalf.filled", "speaker.slash", "rectangle.3.group",
        "lock", "face.smiling", "bolt", "moon", "square.stack.3d.up", "star", "heart", "globe", "timer", "envelope",
        "terminal", "magnifyingglass", "bookmark"
    ]

    /// The second line of a row's description hint: what the slice runs.
    static func detail(of action: RingAction, keywordName: (String, String) -> String? = { _, _ in nil }) -> String {
        let type = action.kind.type.title
        switch action.kind {
        case let .feature(feature):
            return "\(type) · \(feature.detail)"
        case let .keyword(keyword, pluginID):
            return "\(type) · \(keyword)" + (keywordName(keyword, pluginID).map { " · \($0)" } ?? "")
        case let .app(_, name):
            return "\(type) · \(name)"
        case let .keys(binding):
            return "\(type) · \(HotkeyFormat.display(binding))"
        case let .system(system):
            return "\(type) · \(system.detail)"
        case let .shortcut(name):
            return "\(type) · \(name)"
        case let .url(url):
            return "\(type) · \(url)"
        case let .folder(path):
            return "\(type) · \(path)"
        }
    }

    /// OpieMenu draws a label line per "\n" without wrapping: keep labels to two short lines.
    static func sliceLabel(_ title: String, lineLimit: Int = 7, wideLineLimit: Int = 14) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let isWide = trimmed.unicodeScalars.contains { $0.value >= 0x2E80 }
        let limit = isWide ? lineLimit : wideLineLimit
        guard trimmed.count > limit else { return trimmed }
        let words = trimmed.split(separator: " ")
        if words.count > 1 {
            var first = ""
            var index = 0
            while index < words.count, (first.isEmpty ? 0 : first.count + 1) + words[index].count <= limit {
                first += (first.isEmpty ? "" : " ") + words[index]
                index += 1
            }
            if !first.isEmpty {
                let rest = words[index...].joined(separator: " ")
                return rest.isEmpty ? first : first + "\n" + truncate(rest, to: limit)
            }
        }
        let characters = Array(trimmed)
        return String(characters.prefix(limit)) + "\n" + truncate(String(characters.dropFirst(limit)), to: limit)
    }

    private static func truncate(_ text: String, to limit: Int) -> String {
        text.count <= limit ? text : String(text.prefix(limit - 1)) + "…"
    }

    /// Only web pages: the ring never opens `file:` or custom schemes from a typed URL.
    static func webURL(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host, host.contains("."), !host.hasPrefix("."), !host.hasSuffix(".")
        else { return nil }
        return components.url
    }

    /// A suggested slice title for a web page: its host without "www.".
    static func title(forURL text: String) -> String? {
        guard let host = webURL(text)?.host else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    static func expandedFolderPath(_ path: String) -> String {
        (path.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
    }

    /// The compass direction of slice `index` out of `count`, starting at the top, clockwise.
    static func direction(of index: Int, count: Int) -> String {
        guard count > 0 else { return "" }
        let names = ["up", "upRight", "right", "downRight", "down", "downLeft", "left", "upLeft"]
        let sector = Int((Double(index) * 8 / Double(count)).rounded()) % names.count
        return L("ring.direction." + names[sector])
    }
}
