import Foundation

/// Keyword shortcuts from Settings → Shortcuts: `⌃⌥R` opens the launcher in `rw` and
/// runs it on the selected text, as if the user typed the keyword and pressed Return.
extension AskConversationModel {
    func runKeywordShortcut(_ hotkey: KeywordHotkey) {
        guard FeatureProcess.owns(.launcher) else {
            if let payload = try? JSONEncoder().encode(FeatureHotkeyEvent(name: "onShortcutRequested", target: .keyword(hotkey.id))) {
                FeatureProcess.send(.init(destination: .launcher, action: "hotkey", payload: payload))
            }
            return
        }
        guard let onShowLauncher else { enterKeywordShortcut(hotkey, refreshingWorkflows: true); return }
        onShowLauncher { [weak self] in self?.enterKeywordShortcut(hotkey, refreshingWorkflows: true) }
    }

    /// Enters the keyword with the launcher's selection. A workflow keyword may arrive with
    /// the workflows the launcher is still reading, so a missing one is looked for once more.
    func enterKeywordShortcut(_ hotkey: KeywordHotkey, refreshingWorkflows: Bool) {
        guard let keyword = hotkey.resolve(in: plugins.availableKeywords), keyword.enabled else {
            if refreshingWorkflows {
                Task { [weak self] in
                    await self?.refreshLauncherWorkflows()
                    self?.enterKeywordShortcut(hotkey, refreshingWorkflows: false)
                }
            } else {
                confirm(L("hotkeys.keyword.unavailable", hotkey.keyword), for: .seconds(4))
            }
            return
        }
        launcherDraft.text = ""
        plugins.enter(keyword)
        plugins.update(text: "", selection: launcherDraft.sentSelection, language: AppLocalization.shared.language,
                       runWhenPlanned: true)
    }
}
