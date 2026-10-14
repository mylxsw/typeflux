import AppKit

enum AskTranslationPanelKeyCommand: Equatable {
    case submit, clear, escape, pin, swap
    case copy(Int), move(Int), history(Int), language(Int)
    case action(AskPluginAction.Shortcut)

    private static let commandKeys: [UInt16: AskTranslationPanelKeyCommand] = [
        35: .pin, 51: .clear, 126: .move(-1), 125: .move(1),
        15: .action(.commandR), 1: .action(.commandS),
        11: .action(.commandB), 8: .action(.commandC)
    ]
    private static let plainKeys: [UInt16: AskTranslationPanelKeyCommand] = [
        36: .submit, 76: .submit, 53: .escape, 48: .language(1)
    ]

    static func command(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, characters: String? = nil,
                        atStart: Bool = false, atEnd: Bool = false, hasSelection: Bool = false) -> Self? {
        let flags = modifiers.intersection([.command, .shift, .option, .control])
        if let number = AskLauncherNumberShortcuts.number(keyCode: keyCode, modifiers: flags, characters: characters) {
            return .copy(number)
        }
        if !flags.isEmpty {
            return modifiedKey(keyCode, flags: flags, hasSelection: hasSelection)
        }
        if keyCode == 126, atStart, !hasSelection {
            return .history(-1)
        }
        if keyCode == 125, atEnd, !hasSelection {
            return .history(1)
        }
        return plainKeys[keyCode]
    }

    private static func modifiedKey(_ keyCode: UInt16, flags: NSEvent.ModifierFlags, hasSelection: Bool) -> Self? {
        if flags == .command {
            return keyCode == 8 && hasSelection ? nil : commandKeys[keyCode]
        }
        if flags == [.command, .shift] {
            return [UInt16(1): swap, 8: .action(.shiftCommandC)][keyCode]
        }
        if flags == .option, [36, 76].contains(keyCode) {
            return .action(.optionEnter)
        }
        if flags == .shift, keyCode == 48 {
            return .language(-1)
        }
        return nil
    }
}
