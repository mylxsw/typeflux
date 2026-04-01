import AppKit
import Foundation

struct HotkeyBinding: Codable, Equatable, Identifiable {
    static let functionKeyCode = 63

    var id: UUID
    var keyCode: Int
    var modifierFlags: UInt

    init(id: UUID = UUID(), keyCode: Int, modifierFlags: UInt) {
        self.id = id
        self.keyCode = keyCode
        self.modifierFlags = modifierFlags
    }

    var signature: String {
        "\(keyCode):\(modifierFlags)"
    }

    var isRightCommandTrigger: Bool {
        keyCode == 54 && modifierFlags == 1_048_576
    }

    var isFunctionTrigger: Bool {
        keyCode == Self.functionKeyCode
            && modifierFlags == UInt(NSEvent.ModifierFlags.function.rawValue)
    }

    var isModifierOnlyTrigger: Bool {
        isRightCommandTrigger || isFunctionTrigger
    }

    func matches(keyCode: Int, modifierFlags: UInt) -> Bool {
        self.keyCode == keyCode && self.modifierFlags == modifierFlags
    }

    static let defaultActivation = HotkeyBinding(
        keyCode: functionKeyCode,
        modifierFlags: UInt(NSEvent.ModifierFlags.function.rawValue)
    )
    static let defaultAsk = HotkeyBinding(
        keyCode: 49,
        modifierFlags: UInt(NSEvent.ModifierFlags.function.rawValue)
    )
    static let defaultPersona = HotkeyBinding(keyCode: 35, modifierFlags: 1_572_864)
}
