import AppKit
import Foundation

/// One check for every global shortcut: Typeflux's own, the feature shortcuts and the
/// keyword shortcuts. Pure, so the rules are tested without the settings window.
enum HotkeyConflictChecker {
    enum Problem: Equatable {
        /// A modifier alone or a double tap: these gestures belong to voice input.
        case gesture
        /// No ⌘, ⌥ or ⌃ (and not an F key): it would fire while typing.
        case needsModifier
        /// Another Typeflux shortcut already has these keys.
        case taken(HotkeyTarget)
    }

    struct Result: Equatable {
        var problem: Problem?
        /// A common macOS shortcut (⌘C, ⌃Space…): allowed, with a warning.
        var overridesSystemShortcut = false

        var canSave: Bool {
            problem == nil
        }
    }

    static let functionKeyCodes: Set<Int> = [
        122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90
    ]

    /// Checks `binding` for `target` against every other assigned shortcut.
    static func check(_ binding: HotkeyBinding, for target: HotkeyTarget,
                      among assignments: [HotkeyTarget: HotkeyBinding]) -> Result {
        if !allowsGestures(target) {
            if binding.isModifierOnlyTrigger || binding.isModifierDoubleTapTrigger || (binding.pressCount ?? 1) > 1
                || binding.modifierKeyCodes != nil || HotkeyBinding.modifierFlag(for: binding.keyCode) != 0 {
                return Result(problem: .gesture)
            }
            if !hasCommandModifier(binding), !functionKeyCodes.contains(binding.keyCode) {
                return Result(problem: .needsModifier)
            }
        }
        if let owner = owner(of: binding, excluding: target, among: assignments) {
            return Result(problem: .taken(owner))
        }
        return Result(overridesSystemShortcut: isCommonSystemShortcut(binding))
    }

    /// The shortcut that already has `binding`, in page order so the answer is stable.
    static func owner(of binding: HotkeyBinding, excluding target: HotkeyTarget,
                      among assignments: [HotkeyTarget: HotkeyBinding]) -> HotkeyTarget? {
        orderedTargets(assignments.keys).first { other in
            guard other != target, let existing = assignments[other] else { return false }
            return existing.signature == binding.signature || existing.conflicts(with: binding)
        }
    }

    /// Typeflux's own shortcuts keep accepting what they always did; voice input needs
    /// gestures, and the others were never limited.
    static func allowsGestures(_ target: HotkeyTarget) -> Bool {
        if case .builtIn = target {
            return true
        }
        return false
    }

    static func hasCommandModifier(_ binding: HotkeyBinding) -> Bool {
        let flags = NSEvent.ModifierFlags(rawValue: binding.modifierFlags)
        return !flags.isDisjoint(with: [.command, .option, .control])
    }

    /// Shortcuts most Mac apps or macOS itself use.
    static func isCommonSystemShortcut(_ binding: HotkeyBinding) -> Bool {
        let flags = NSEvent.ModifierFlags(rawValue: binding.modifierFlags)
            .intersection([.command, .option, .control, .shift])
        return commonSystemShortcuts.contains { $0.keyCode == binding.keyCode && $0.flags == flags }
    }

    private struct SystemShortcut {
        let keyCode: Int
        let flags: NSEvent.ModifierFlags
    }

    private static let commonSystemShortcuts: [SystemShortcut] = {
        let command: NSEvent.ModifierFlags = .command
        let commandShift: NSEvent.ModifierFlags = [.command, .shift]
        // A S D F Z X C V Q W T N O P H M , Tab Space ` and screenshots ⇧⌘3/4/5.
        let commandKeys = [0, 1, 2, 3, 6, 7, 8, 9, 12, 13, 17, 45, 31, 35, 4, 46, 43, 48, 49, 50]
        return commandKeys.map { SystemShortcut(keyCode: $0, flags: command) }
            + [20, 21, 23, 6].map { SystemShortcut(keyCode: $0, flags: commandShift) }
            + [SystemShortcut(keyCode: 49, flags: .control), SystemShortcut(keyCode: 49, flags: [.control, .command]),
               SystemShortcut(keyCode: 49, flags: [.command, .option]), SystemShortcut(
                   keyCode: 53,
                   flags: [.command, .option]
               )]
    }()

    private static func orderedTargets(_ targets: some Sequence<HotkeyTarget>) -> [HotkeyTarget] {
        targets.sorted { rank($0) < rank($1) }
    }

    private static func rank(_ target: HotkeyTarget) -> String {
        switch target {
        case let .builtIn(builtIn):
            "0\(BuiltInHotkey.allCases.firstIndex(of: builtIn) ?? 0)"
        case let .action(action):
            "1\(AppHotkeyAction.allCases.firstIndex(of: action) ?? 0)"
        case let .keyword(id):
            "2\(id.uuidString)"
        }
    }
}
