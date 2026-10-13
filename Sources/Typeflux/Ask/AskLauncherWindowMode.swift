import Foundation

/// The empty launcher can be a single search bar; active work expands to fit its content.
enum AskLauncherWindowMode: String, CaseIterable, Sendable {
    case simple
    case complete

    var title: String { L("ask.settings.windowMode." + rawValue) }

    func isCollapsed(draft: AskDraft, engaged: Bool = false) -> Bool {
        self == .simple && !engaged && !draft.hasText
            && (draft.references ?? []).isEmpty && (draft.attachments ?? []).isEmpty
            && (draft.skills ?? []).isEmpty && (draft.mcpServers ?? []).isEmpty
    }

    static var simpleHeight: CGFloat { simpleHeight(for: .liquidGlass) }

    static func simpleHeight(for style: InterfaceStyle) -> CGFloat {
        AskMetrics.launcherHeaderHeight(editor: 32, style: style) + AskMetrics.launcherGutter * 2
    }

    /// Reusing a collapsed panel must not postpone expansion until SwiftUI renders again.
    static func openingHeight(collapsed: Bool, cachedHeight: CGFloat, style: InterfaceStyle) -> CGFloat {
        if collapsed { return simpleHeight(for: style) }
        return max(cachedHeight, AskMetrics.launcherHeight(editor: 32, banners: 0, style: style))
    }
}

extension SettingsStore {
    var askLauncherWindowMode: AskLauncherWindowMode {
        get {
            defaults.string(forKey: "ask.launcher.windowMode")
                .flatMap(AskLauncherWindowMode.init(rawValue:)) ?? .complete
        }
        set { defaults.set(newValue.rawValue, forKey: "ask.launcher.windowMode") }
    }
}

extension AskConversationModel {
    /// Captured context does not expand an otherwise empty launcher.
    var launcherNeedsFullWindow: Bool {
        plugins.isActive || (voiceInput.context == "launcher" && voiceInput.isActive)
            || isLoadingAttachments(launcher: true) || workflowApproval != nil || submissionIssues[true] != nil
    }

    var launcherIsCollapsed: Bool {
        launcherWindowMode.isCollapsed(draft: launcherDraft, engaged: launcherNeedsFullWindow || launcherHistoryMode)
    }
}
