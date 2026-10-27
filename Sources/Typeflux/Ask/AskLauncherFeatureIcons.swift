import AppKit

/// Shared artwork for home shortcuts, keyword results, the directory and input chips.
@MainActor
enum AskLauncherFeatureIcons {
    enum Style: String, CaseIterable {
        case sculpted
        case light
    }

    static let preferenceKey = "launcherFeatureIconStyle"
    static let names = [
        "chat", "translate", "screenshot", "recording", "notes", "wordbook", "clipboard", "settings",
        "polish", "summarize", "explain", "web-google", "web-baidu", "web-github", "apps", "files",
        "semantic-files", "quick-ask", "directory", "help", "history", "tabs", "bookmarks", "kill-app",
        "monitor", "system-info", "calendar", "worldclock", "terminal", "emoji", "screenshot-full",
        "screenshot-scroll", "screenshot-ai", "ocr", "gif"
    ] + AskSystemCommand.allCases.map { "system-" + $0.rawValue }
    private static var cache: [String: NSImage] = [:]

    /// Resolve semantic destinations, never the user's editable keyword spelling.
    static func name(for keyword: AskKeyword) -> String? {
        if let command = AskSystemCommand(pluginID: keyword.pluginID) { return "system-" + command.rawValue }
        switch keyword.pluginID {
        case AskOpenChatPlugin.id: return "chat"
        case AskTranslatePlugin.id:
            return AskTranslatePlugin.opensWordBook(keyword.options) ? "wordbook" : "translate"
        case AskScreenshotPlugin.id:
            if ScreenshotFollowUp(options: keyword.options) == .askAI { return "screenshot-ai" }
            switch ScreenshotMode(options: keyword.options) {
            case .region: return "screenshot"
            case .fullScreen: return "screenshot-full"
            case .scrolling: return "screenshot-scroll"
            case .recording: return "recording"
            case .gif: return "gif"
            }
        case AskScreenshotTextPlugin.id: return "ocr"
        case AskNotesPlugin.id: return "notes"
        case AskClipboardPlugin.id: return "clipboard"
        case AskSettingsPlugin.id: return "settings"
        case AskPromptPlugin.id:
            guard keyword.options[AskPromptPlugin.promptOption]?
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false else { return nil }
            return keyword.options[AskPromptPlugin.presetOption].flatMap(AskPromptPlugin.Preset.init(rawValue:))?
                .rawValue
        case AskWebSearchPlugin.id:
            guard keyword.options[AskWebSearchPlugin.urlOption]?
                .trimmingCharacters(in: .whitespaces).isEmpty != false else { return nil }
            let engine = keyword.options[AskWebSearchPlugin.engineOption]
                .flatMap(AskWebSearchPlugin.Engine.init(rawValue:)) ?? .google
            return "web-" + engine.rawValue
        case AskAppSearchPlugin.id: return "apps"
        case AskFileSearchPlugin.id: return "files"
        case AskSemanticFileSearchPlugin.id: return "semantic-files"
        case AskQuickAskPlugin.id: return "quick-ask"
        case AskPrefixPlugin.id: return "directory"
        case AskHelpPlugin.id: return "help"
        case AskHistoryPlugin.id: return "history"
        case AskBrowserSearchPlugin.tabsID: return "tabs"
        case AskBrowserSearchPlugin.bookmarksID: return "bookmarks"
        case AskKillAppPlugin.id: return "kill-app"
        case AskSystemMonitorPlugin.id: return "monitor"
        case AskSystemInfoPlugin.id: return "system-info"
        case AskCalendarPlugin.id: return "calendar"
        case AskWorldClockPlugin.id: return "worldclock"
        case AskTerminalCommandPlugin.id: return "terminal"
        case AskEmojiPlugin.id: return "emoji"
        default: return nil
        }
    }

    static func image(for rowID: String, style: Style) -> NSImage? {
        let name = rowID.hasPrefix("feature.") ? String(rowID.dropFirst("feature.".count)) : rowID
        guard names.contains(name) else { return nil }
        let resource = "launcher-feature-" + style.rawValue + "-" + name
        if let cached = cache[resource] { return cached }
        // Extended keyword artwork uses the selected sculpted family; the original light set remains switchable.
        guard let url = Bundle.module.url(forResource: resource, withExtension: "png")
            ?? Bundle.module.url(forResource: "launcher-feature-sculpted-" + name, withExtension: "png"),
            let image = NSImage(contentsOf: url) else { return nil }
        cache[resource] = image
        return image
    }
}
