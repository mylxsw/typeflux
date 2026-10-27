import AppKit

/// Both families ship together; switching this preference needs no asset replacement or rebuild.
@MainActor
enum AskLauncherFeatureIcons {
    enum Style: String, CaseIterable {
        case sculpted
        case light
    }

    static let preferenceKey = "launcherFeatureIconStyle"
    static let names = ["chat", "translate", "screenshot", "recording", "notes", "wordbook", "clipboard", "settings"]
    private static var cache: [String: NSImage] = [:]

    /// Resolve semantic destinations, never the user's editable keyword spelling.
    static func name(for keyword: AskKeyword) -> String? {
        switch keyword.pluginID {
        case AskOpenChatPlugin.id: return "chat"
        case AskTranslatePlugin.id:
            return AskTranslatePlugin.opensWordBook(keyword.options) ? "wordbook" : "translate"
        case AskScreenshotPlugin.id:
            let mode = ScreenshotMode(options: keyword.options)
            return mode == .recording || mode == .gif ? "recording" : "screenshot"
        case AskScreenshotTextPlugin.id: return "screenshot"
        case AskNotesPlugin.id: return "notes"
        case AskClipboardPlugin.id: return "clipboard"
        case AskSettingsPlugin.id: return "settings"
        default: return nil
        }
    }

    static func image(for rowID: String, style: Style) -> NSImage? {
        let name = rowID.hasPrefix("feature.") ? String(rowID.dropFirst("feature.".count)) : rowID
        guard names.contains(name) else { return nil }
        let resource = "launcher-feature-" + style.rawValue + "-" + name
        if let cached = cache[resource] { return cached }
        guard let url = Bundle.module.url(forResource: resource, withExtension: "png"),
              let image = NSImage(contentsOf: url) else { return nil }
        cache[resource] = image
        return image
    }
}
