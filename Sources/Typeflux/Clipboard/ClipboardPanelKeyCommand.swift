import AppKit
import Foundation

/// Keyboard shortcuts of the clipboard panel. Everything else goes to the search field.
enum ClipboardPanelKeyCommand: Equatable {
    case moveUp
    case moveDown
    case nextCategory
    case previousCategory
    case cancel
    case action(ClipboardEntryAction)
    case quickPaste(Int)

    static func command(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        characters: String?,
        queryIsEmpty: Bool,
        hasTextSelection: Bool
    ) -> ClipboardPanelKeyCommand? {
        let flags = modifiers.intersection([.command, .option, .control, .shift])
        if let command = navigationCommand(keyCode: keyCode, flags: flags, queryIsEmpty: queryIsEmpty) {
            return command
        }
        guard flags == .command, let key = characters?.lowercased() else { return nil }
        if let number = Int(key), (1 ... 9).contains(number) { return .quickPaste(number) }
        switch key {
        case "p": return .action(.togglePin)
        case "y": return .action(.quickLook)
        case "c" where !hasTextSelection: return .action(.copy)
        default: return nil
        }
    }

    private static func navigationCommand(
        keyCode: UInt16,
        flags: NSEvent.ModifierFlags,
        queryIsEmpty: Bool
    ) -> ClipboardPanelKeyCommand? {
        switch keyCode {
        case 126 where flags.isEmpty: return .moveUp
        case 125 where flags.isEmpty: return .moveDown
        case 53: return .cancel
        case 48 where flags.isEmpty: return .nextCategory
        case 48 where flags == .shift: return .previousCategory
        case 36, 76:
            if flags.isEmpty { return .action(.paste) }
            if flags == .command { return .action(.pastePlainText) }
            return nil
        // Backspace deletes the row only when it cannot be editing the search text.
        case 51 where flags == .command && queryIsEmpty: return .action(.delete)
        default: return nil
        }
    }
}
