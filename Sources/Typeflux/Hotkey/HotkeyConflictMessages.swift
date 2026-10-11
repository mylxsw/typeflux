import Foundation

/// Names and conflict messages for the Shortcuts page and the older shortcut cards.
enum HotkeyConflictMessages {
    static func name(of target: HotkeyTarget, in settingsStore: SettingsStore) -> String {
        switch target {
        case let .builtIn(builtIn):
            return builtIn.title
        case let .action(action):
            return action.title
        case let .keyword(id):
            let keyword = settingsStore.keywordHotkeys.first { $0.id == id }?.keyword ?? ""
            return L("hotkeys.keyword.name", keyword)
        }
    }

    /// The toast a built-in shortcut card shows; the older cards kept their own wording.
    static func builtIn(_ builtIn: BuiltInHotkey, takenBy owner: HotkeyTarget,
                        in settingsStore: SettingsStore) -> String {
        if builtIn == .auxiliary || owner == .builtIn(.auxiliary) {
            return L("settings.shortcuts.auxiliaryConflict")
        }
        guard case .builtIn = owner else {
            return L("hotkeys.conflict.usedBy", name(of: owner, in: settingsStore))
        }
        if builtIn == .screenshot {
            return L("settings.shortcuts.screenshotConflict")
        }
        if owner == .builtIn(.screenshot) {
            return L("settings.shortcuts.usedByScreenshot")
        }
        return L("settings.shortcuts.\(builtIn.rawValue)Conflict")
    }

    /// The line under a shortcut field on the Shortcuts page.
    static func describe(_ problem: HotkeyConflictChecker.Problem, in settingsStore: SettingsStore) -> String {
        switch problem {
        case .gesture: L("hotkeys.conflict.gesture")
        case .needsModifier: L("hotkeys.conflict.needsModifier")
        case let .taken(owner): L("hotkeys.conflict.usedBy", name(of: owner, in: settingsStore))
        }
    }
}
