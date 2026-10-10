import AppKit
import Foundation

struct HotkeyBinding: Codable, Equatable, Identifiable {
    static let rightCommandKeyCode = 54
    static let rightOptionKeyCode = 61
    static let functionKeyCode = 63
    static let oKeyCode = 31

    var id: UUID
    var keyCode: Int
    var modifierFlags: UInt
    var pressCount: Int?
    /// Physical keys for modifier chords; nil preserves legacy bindings.
    var modifierKeyCodes: [Int]?

    init(id: UUID = UUID(), keyCode: Int, modifierFlags: UInt, pressCount: Int? = nil, modifierKeyCodes: [Int]? = nil) {
        self.id = id
        self.keyCode = keyCode
        self.modifierFlags = modifierFlags
        self.pressCount = pressCount
        self.modifierKeyCodes = modifierKeyCodes?.sorted()
    }

    var signature: String {
        "\(keyCode):\(modifierFlags):\(pressCount ?? 1)" + (modifierKeyCodes.map { ":" + $0.sorted().map(String.init).joined(separator: ",") } ?? "")
    }

    var isRightCommandTrigger: Bool {
        keyCode == Self.rightCommandKeyCode
            && modifierFlags == UInt(NSEvent.ModifierFlags.command.rawValue)
            && (pressCount ?? 1) == 1
    }

    var isRightOptionTrigger: Bool {
        keyCode == Self.rightOptionKeyCode
            && modifierFlags == UInt(NSEvent.ModifierFlags.option.rawValue)
            && (pressCount ?? 1) == 1
    }

    var isFunctionTrigger: Bool {
        keyCode == Self.functionKeyCode
            && modifierFlags == UInt(NSEvent.ModifierFlags.function.rawValue)
            && (pressCount ?? 1) == 1
    }

    var isModifierOnlyTrigger: Bool {
        isRightCommandTrigger || isRightOptionTrigger || isFunctionTrigger
    }

    var isModifierDoubleTapTrigger: Bool {
        guard pressCount == 2 else { return false }
        return (
            keyCode == Self.rightCommandKeyCode
                && modifierFlags == UInt(NSEvent.ModifierFlags.command.rawValue)
        ) || (
            keyCode == Self.rightOptionKeyCode
                && modifierFlags == UInt(NSEvent.ModifierFlags.option.rawValue)
        ) || (
            keyCode == Self.functionKeyCode
                && modifierFlags == UInt(NSEvent.ModifierFlags.function.rawValue)
        )
    }

    func matches(keyCode: Int, modifierFlags: UInt) -> Bool {
        (pressCount ?? 1) == 1 && self.keyCode == keyCode && self.modifierFlags == modifierFlags
    }

    static let defaultActivation = HotkeyBinding(
        keyCode: functionKeyCode,
        modifierFlags: UInt(NSEvent.ModifierFlags.function.rawValue)
    )
    static let defaultAuxiliary = auxiliaryChord(baseKeyCode: functionKeyCode)

    static func auxiliaryChord(baseKeyCode: Int) -> HotkeyBinding {
        HotkeyBinding(
            keyCode: 56,
            modifierFlags: modifierFlag(for: baseKeyCode) | modifierFlag(for: 56),
            modifierKeyCodes: [baseKeyCode, 56]
        )
    }

    static func modifierFlag(for keyCode: Int) -> UInt {
        switch keyCode {
        case 54, 55: UInt(NSEvent.ModifierFlags.command.rawValue)
        case 56, 60: UInt(NSEvent.ModifierFlags.shift.rawValue)
        case 58, 61: UInt(NSEvent.ModifierFlags.option.rawValue)
        case 59, 62: UInt(NSEvent.ModifierFlags.control.rawValue)
        case 63: UInt(NSEvent.ModifierFlags.function.rawValue)
        default: 0
        }
    }

    var physicalModifierKeys: [Int] {
        modifierKeyCodes ?? (Self.modifierFlag(for: keyCode) != 0 ? [keyCode] : [])
    }

    func conflicts(with other: HotkeyBinding) -> Bool {
        guard (pressCount ?? 1) == (other.pressCount ?? 1), modifierFlags == other.modifierFlags else {
            return false
        }
        if keyCode == other.keyCode, modifierKeyCodes == nil || other.modifierKeyCodes == nil { return true }
        if !physicalModifierKeys.isEmpty, !other.physicalModifierKeys.isEmpty {
            return physicalModifierKeys.sorted() == other.physicalModifierKeys.sorted()
        }
        return keyCode == other.keyCode
    }

    static let defaultAsk = HotkeyBinding(
        keyCode: 49,
        modifierFlags: UInt(NSEvent.ModifierFlags.command.rawValue)
    )
    static let defaultPersona = HotkeyBinding(keyCode: 35, modifierFlags: 1_572_864)
    static let defaultHistory = HotkeyBinding(
        keyCode: oKeyCode,
        modifierFlags: UInt(NSEvent.ModifierFlags.command.union(.option).rawValue)
    )

    /// ⌥⌘A: free in most apps, and the default the screenshot design settled on.
    static let defaultScreenshot = HotkeyBinding(
        keyCode: 0,
        modifierFlags: UInt(NSEvent.ModifierFlags.command.union(.option).rawValue)
    )

    static let rightCommandActivation = HotkeyBinding(
        keyCode: rightCommandKeyCode,
        modifierFlags: UInt(NSEvent.ModifierFlags.command.rawValue)
    )
    static let rightCommandAsk = HotkeyBinding(
        keyCode: rightCommandKeyCode,
        modifierFlags: UInt(NSEvent.ModifierFlags.command.rawValue),
        pressCount: 2
    )
    static let rightOptionActivation = HotkeyBinding(
        keyCode: rightOptionKeyCode,
        modifierFlags: UInt(NSEvent.ModifierFlags.option.rawValue)
    )
    static let rightOptionAsk = HotkeyBinding(
        keyCode: rightOptionKeyCode,
        modifierFlags: UInt(NSEvent.ModifierFlags.option.rawValue),
        pressCount: 2
    )
}
