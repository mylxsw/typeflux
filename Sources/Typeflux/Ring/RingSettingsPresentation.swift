import Foundation

/// Text and rules for the ring that do not need AppKit, so they are tested directly.
enum RingSettingsPresentation {
    static let symbol = "circle.circle"
    /// Longer names do not fit on a slice label.
    static let titleLimit = 24

    /// Symbols offered in the editor's icon picker.
    static let symbolChoices = [
        "mic", "sparkles", "bubble.left.and.bubble.right", "camera.viewfinder", "text.viewfinder", "character.bubble",
        "doc.on.clipboard", "note.text", "character.book.closed", "person.crop.rectangle.stack", "wand.and.stars",
        "command", "app", "keyboard", "link", "folder", "circle.lefthalf.filled", "speaker.slash", "rectangle.3.group",
        "lock", "face.smiling", "bolt", "moon", "square.stack.3d.up", "star", "heart", "globe", "timer", "envelope",
        "terminal", "magnifyingglass", "bookmark",
        // Navigation and browser actions.
        "chevron.left", "chevron.right", "arrow.left", "arrow.right", "arrow.up", "arrow.down",
        "arrow.clockwise", "arrow.counterclockwise", "house", "safari", "network", "plus.square",
        "xmark.square", "square.on.square", "arrow.up.right.square", "sidebar.left", "sidebar.right",
        // Editing, text and documents.
        "scissors", "doc.on.doc", "doc", "doc.text", "doc.badge.plus", "pencil", "square.and.pencil",
        "pencil.tip", "eraser", "textformat", "bold", "italic", "underline", "strikethrough",
        "list.bullet", "list.number", "checklist", "text.alignleft", "text.aligncenter", "text.alignright",
        "quote.bubble", "curlybraces", "chevron.left.forwardslash.chevron.right", "number", "at",
        // Files and organization.
        "folder.badge.plus", "folder.badge.gearshape", "tray", "tray.and.arrow.down", "tray.and.arrow.up",
        "archivebox", "trash", "externaldrive", "internaldrive", "icloud", "icloud.and.arrow.down",
        "icloud.and.arrow.up", "arrow.down.doc", "arrow.up.doc", "paperclip", "tag", "pin",
        "calendar", "clock", "alarm", "stopwatch", "book", "books.vertical",
        // Windows, display and system controls.
        "macwindow", "rectangle.split.2x1", "rectangle.split.1x2", "rectangle.grid.2x2",
        "arrow.up.left.and.arrow.down.right", "arrow.down.right.and.arrow.up.left", "desktopcomputer",
        "display", "laptopcomputer", "sun.max", "sun.min", "lightbulb", "power", "gearshape",
        "slider.horizontal.3", "wifi", "antenna.radiowaves.left.and.right", "lock.open", "shield",
        "eye", "eye.slash", "bell", "bell.slash", "battery.100", "cpu", "memorychip",
        // Audio, video and images.
        "play", "pause", "stop", "backward.end", "forward.end", "gobackward.10", "goforward.10",
        "repeat", "shuffle", "speaker.wave.2", "speaker.plus", "speaker.minus", "mic.slash",
        "headphones", "music.note", "music.note.list", "video", "camera", "photo", "photo.on.rectangle",
        "record.circle", "crop", "paintbrush", "paintpalette", "eyedropper",
        // Communication and useful markers.
        "bubble.left", "paperplane", "phone", "person", "person.2", "hand.thumbsup", "flag",
        "checkmark.circle", "xmark.circle", "exclamationmark.triangle", "questionmark.circle",
        "info.circle", "location", "map", "cart", "gift", "wrench.and.screwdriver"
    ]

    /// What exactly a slice runs, without its type: the second line of a slice in Settings.
    static func summary(of action: RingAction, keywordName: (String, String) -> String? = { _, _ in nil }) -> String {
        switch action.kind {
        case let .feature(feature): feature.detail
        case let .system(system): system.detail
        case let .keyword(keyword, pluginID): keywordName(keyword, pluginID).map { "\(keyword) · \($0)" } ?? keyword
        case let .app(bundleIdentifier, name): "\(name) · \(bundleIdentifier)"
        case let .keys(binding): HotkeyFormat.display(binding)
        case let .shortcut(name): name
        case let .url(url): url
        case let .folder(path): path
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

    /// Why a slice cannot run any more, or nil when it can. The checks are passed in so the rule is
    /// tested without touching the system.
    static func issue(of action: RingAction, keywordExists: (String, String) -> Bool,
                      appExists: (String) -> Bool, folderExists: (String) -> Bool) -> String? {
        switch action.kind {
        case let .keyword(keyword, pluginID):
            keywordExists(keyword, pluginID) ? nil : L("ring.issue.keywordMissing", keyword)
        case let .app(bundleIdentifier, name):
            appExists(bundleIdentifier) ? nil : L("ring.error.appMissing", name)
        case let .url(url):
            webURL(url) == nil ? L("ring.error.invalidURL") : nil
        case let .folder(path):
            folderExists(expandedFolderPath(path)) ? nil : L("ring.error.folderMissing", path)
        case .feature, .system, .keys, .shortcut:
            nil
        }
    }

    /// The compass direction of slice `index` out of `count`, starting at the top, clockwise.
    static func direction(of index: Int, count: Int) -> String {
        guard count > 0 else { return "" }
        let names = ["up", "upRight", "right", "downRight", "down", "downLeft", "left", "upLeft"]
        let sector = Int((Double(index) * 8 / Double(count)).rounded()) % names.count
        return L("ring.direction." + names[sector])
    }
}
