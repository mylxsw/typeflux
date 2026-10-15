import Foundation

/// Every global shortcut through one door, for the Shortcuts page and its conflict check.
/// The built-in shortcuts keep their own keys; feature and keyword shortcuts are new.
extension SettingsStore {
    /// Preserve the selection shortcut first, then the input shortcut. Remove both
    /// retired owners before registration/conflict checks can see their bindings.
    func migrateTranslationHotkeys() {
        let key = "hotkey.actions.json"
        guard let data = defaults.data(forKey: key),
              var stored = try? JSONDecoder().decode([String: HotkeyBinding].self, from: data),
              stored["selectionTranslation"] != nil || stored["inputTranslation"] != nil else { return }
        stored["translate"] = stored["translate"] ?? stored["selectionTranslation"] ?? stored["inputTranslation"]
        stored.removeValue(forKey: "selectionTranslation")
        stored.removeValue(forKey: "inputTranslation")
        if let migrated = try? JSONEncoder().encode(stored) {
            defaults.set(migrated, forKey: key)
        }
    }

    func hotkey(_ builtIn: BuiltInHotkey) -> HotkeyBinding? {
        switch builtIn {
        case .activation: activationHotkey
        case .auxiliary: auxiliaryHotkey
        case .persona: personaHotkey
        case .ask: askHotkey
        case .history: historyHotkey
        case .screenshot: screenshotHotkey
        }
    }

    func setHotkey(_ binding: HotkeyBinding?, for builtIn: BuiltInHotkey) {
        switch builtIn {
        case .activation: activationHotkey = binding
        case .auxiliary: auxiliaryHotkey = binding
        case .persona: personaHotkey = binding
        case .ask: askHotkey = binding
        case .history: historyHotkey = binding
        case .screenshot: screenshotHotkey = binding
        }
    }

    /// Shortcuts for features without a default one (open the chat window, notes…).
    var actionHotkeys: [AppHotkeyAction: HotkeyBinding] {
        get {
            guard let data = defaults.data(forKey: "hotkey.actions.json"),
                  let stored = try? JSONDecoder().decode([String: HotkeyBinding].self, from: data)
            else { return [:] }
            return stored.reduce(into: [:]) { result, entry in
                if let action = AppHotkeyAction(rawValue: entry.key) {
                    result[action] = entry.value
                }
            }
        }
        set {
            let stored = Dictionary(uniqueKeysWithValues: newValue.map { ($0.key.rawValue, $0.value) })
            if stored.isEmpty {
                defaults.removeObject(forKey: "hotkey.actions.json")
            } else if let data = try? JSONEncoder().encode(stored) {
                defaults.set(data, forKey: "hotkey.actions.json")
            }
            NotificationCenter.default.post(name: .hotkeySettingsDidChange, object: self)
        }
    }

    func setHotkey(_ binding: HotkeyBinding?, for action: AppHotkeyAction) {
        var hotkeys = actionHotkeys
        hotkeys[action] = binding
        actionHotkeys = hotkeys
    }

    /// Shortcuts that run a launcher keyword, in the order the user added them.
    var keywordHotkeys: [KeywordHotkey] {
        get {
            guard let data = defaults.data(forKey: "hotkey.keywords.json") else { return [] }
            return (try? JSONDecoder().decode([KeywordHotkey].self, from: data)) ?? []
        }
        set {
            if newValue.isEmpty {
                defaults.removeObject(forKey: "hotkey.keywords.json")
            } else if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: "hotkey.keywords.json")
            }
            NotificationCenter.default.post(name: .hotkeySettingsDidChange, object: self)
        }
    }

    /// Every assigned shortcut. Keyword shortcuts that are switched off still hold their keys,
    /// so turning one back on never collides.
    var hotkeyAssignments: [HotkeyTarget: HotkeyBinding] {
        var result: [HotkeyTarget: HotkeyBinding] = [:]
        for builtIn in BuiltInHotkey.allCases {
            if let binding = hotkey(builtIn) {
                result[.builtIn(builtIn)] = binding
            }
        }
        for (action, binding) in actionHotkeys {
            result[.action(action)] = binding
        }
        for hotkey in keywordHotkeys {
            if let binding = hotkey.binding {
                result[.keyword(hotkey.id)] = binding
            }
        }
        return result
    }

    /// A keyword was renamed in the keyword list: its shortcuts follow it.
    func renameKeywordHotkeys(from original: AskKeyword, to renamed: AskKeyword) {
        guard original.keyword.caseInsensitiveCompare(renamed.keyword) != .orderedSame else { return }
        var hotkeys = keywordHotkeys
        var changed = false
        for index in hotkeys.indices where hotkeys[index].pluginID == original.pluginID
            && original.contains(hotkeys[index].keyword) && !renamed.contains(hotkeys[index].keyword) {
            hotkeys[index].keyword = renamed.keyword
            hotkeys[index].pluginID = renamed.pluginID
            changed = true
        }
        if changed {
            keywordHotkeys = hotkeys
        }
    }
}
