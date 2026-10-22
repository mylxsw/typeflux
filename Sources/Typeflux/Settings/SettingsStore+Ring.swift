import AppKit
import Foundation

extension Notification.Name {
    static let ringSettingsDidChange = Notification.Name("SettingsStore.ringSettingsDidChange")
}

/// Settings → Ring. The ring's shortcut is the `.ring` feature shortcut, so it shares the
/// Shortcuts page and its conflict check.
extension SettingsStore {
    private static let ringConfigurationKey = "ring.configuration.json"
    private static let ringHotkeySeededKey = "ring.hotkeySeeded"

    var ringConfiguration: RingConfiguration {
        get {
            guard let data = defaults.data(forKey: Self.ringConfigurationKey),
                  var configuration = try? JSONDecoder().decode(RingConfiguration.self, from: data)
            else { return RingConfiguration() }
            if configuration.migrateLegacyChatTitles(), let migrated = try? JSONEncoder().encode(configuration) {
                defaults.set(migrated, forKey: Self.ringConfigurationKey)
            }
            return configuration
        }
        set {
            let wasUsable = ringConfiguration.isUsable
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            defaults.set(data, forKey: Self.ringConfigurationKey)
            NotificationCenter.default.post(name: .ringSettingsDidChange, object: self)
            // The shortcut is registered only while the ring can open.
            if wasUsable != newValue.isUsable {
                NotificationCenter.default.post(name: .hotkeySettingsDidChange, object: self)
            }
        }
    }

    /// Gives the ring ⌃⌥Space the first time this version runs, unless another Typeflux shortcut
    /// or macOS (e.g. "Select next input source") already uses those keys. Runs once, so a
    /// shortcut the user removed stays removed.
    func seedRingHotkeyIfNeeded(systemShortcuts: @autoclosure () -> SystemSymbolicHotkeys = .current) {
        guard !defaults.bool(forKey: Self.ringHotkeySeededKey) else { return }
        defaults.set(true, forKey: Self.ringHotkeySeededKey)
        guard actionHotkeys[.ring] == nil else { return }
        let binding = RingConfiguration.defaultHotkey
        guard HotkeyConflictChecker.owner(of: binding, excluding: .action(.ring), among: hotkeyAssignments) == nil,
              !systemShortcuts().contains(binding)
        else { return }
        setHotkey(binding, for: .ring)
    }
}

/// The keyboard shortcuts macOS itself has switched on (System Settings → Keyboard → Keyboard Shortcuts).
struct SystemSymbolicHotkeys: Equatable {
    struct Shortcut: Equatable {
        var keyCode: Int
        var modifierFlags: UInt
    }

    static let none = SystemSymbolicHotkeys(enabled: [])

    var enabled: [Shortcut]

    static var current: SystemSymbolicHotkeys {
        let value = CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString,
                                              "com.apple.symbolichotkeys" as CFString)
        return SystemSymbolicHotkeys(preferences: value as? [String: Any] ?? [:])
    }

    init(enabled: [Shortcut]) {
        self.enabled = enabled
    }

    /// Each entry looks like `{enabled = 1; value = {parameters = (32, 49, 786432); type = standard;};}`.
    init(preferences: [String: Any]) {
        enabled = preferences.values.compactMap { entry in
            guard let entry = entry as? [String: Any], (entry["enabled"] as? NSNumber)?.boolValue == true,
                  let value = entry["value"] as? [String: Any],
                  let parameters = (value["parameters"] as? [NSNumber])?.map(\.intValue), parameters.count >= 3,
                  parameters[1] != 65535
            else { return nil }
            return Shortcut(keyCode: parameters[1], modifierFlags: UInt(max(parameters[2], 0)))
        }
    }

    func contains(_ binding: HotkeyBinding) -> Bool {
        let mask: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
        let flags = NSEvent.ModifierFlags(rawValue: binding.modifierFlags).intersection(mask)
        return enabled.contains { shortcut in
            shortcut.keyCode == binding.keyCode
                && NSEvent.ModifierFlags(rawValue: shortcut.modifierFlags).intersection(mask) == flags
        }
    }
}
