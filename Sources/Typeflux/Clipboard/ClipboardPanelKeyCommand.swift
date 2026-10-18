import AppKit
import Foundation

/// Keyboard shortcuts of the clipboard panel. Everything else goes to the search field.
enum ClipboardPanelKeyCommand: Equatable {
    case moveUp
    case moveDown
    case moveToFirst
    case moveToLast
    case nextCategory
    case previousCategory
    case cancel
    case action(ClipboardEntryAction)
    case quickPaste(Int)
    case togglePreview
    case showPreview
    case hidePreview
    case togglePause
    case openSettings

    static func command(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        characters: String?,
        queryIsEmpty: Bool,
        hasTextSelection: Bool,
        style: ClipboardPanelStyle = .list
    ) -> ClipboardPanelKeyCommand? {
        let flags = modifiers.intersection([.command, .option, .control, .shift])
        if let command = navigation(keyCode: keyCode, flags: flags, queryIsEmpty: queryIsEmpty,
                                    hasTextSelection: hasTextSelection, style: style) {
            return command
        }
        if let number = AskLauncherNumberShortcuts.number(keyCode: keyCode, modifiers: modifiers, characters: characters) {
            return .quickPaste(number)
        }
        guard let key = characters?.lowercased() else { return nil }
        if flags == [.command, .shift] {
            return key == "p" ? .togglePause : nil
        }
        guard flags == .command else { return nil }
        if key == "c" {
            return hasTextSelection ? nil : .action(.copy)
        }
        return commandLetterShortcuts[key]
    }

    /// `⌘` + key shortcuts other than copy, which yields to a text selection.
    private static let commandLetterShortcuts: [String: ClipboardPanelKeyCommand] = [
        "p": .action(.togglePin),
        "e": .action(.editBeforePaste),
        "y": .action(.quickLook),
        ",": .openSettings,
        "\\": .togglePreview
    ]

    private static func navigation(
        keyCode: UInt16,
        flags: NSEvent.ModifierFlags,
        queryIsEmpty: Bool,
        hasTextSelection: Bool,
        style: ClipboardPanelStyle
    ) -> ClipboardPanelKeyCommand? {
        if style == .shelf, let command = shelfNavigationCommand(keyCode: keyCode, flags: flags,
                                                                 queryIsEmpty: queryIsEmpty) {
            return command
        }
        return navigationCommand(keyCode: keyCode, flags: flags, queryIsEmpty: queryIsEmpty,
                                 hasTextSelection: hasTextSelection)
    }

    /// Plain keys on the shelf: ←/→ select, ↑/↓ open and close the preview.
    private static let shelfKeys: [UInt16: ClipboardPanelKeyCommand] = [
        123: .moveUp, 124: .moveDown, 126: .showPreview, 125: .hidePreview
    ]
    /// `⌘←` / `⌘→` jump to the first or last card.
    private static let shelfCommandKeys: [UInt16: ClipboardPanelKeyCommand] = [123: .moveToFirst, 124: .moveToLast]

    /// The shelf lays cards out left to right, so horizontal arrows always move the selection,
    /// as in Paste; the vertical arrows and Space open and close the preview above the card.
    private static func shelfNavigationCommand(
        keyCode: UInt16,
        flags: NSEvent.ModifierFlags,
        queryIsEmpty: Bool
    ) -> ClipboardPanelKeyCommand? {
        if flags == .command { return shelfCommandKeys[keyCode] }
        guard flags.isEmpty else { return nil }
        // A leading space never starts a search, so it can preview instead.
        if keyCode == 49 { return queryIsEmpty ? .togglePreview : nil }
        return shelfKeys[keyCode]
    }

    private static func navigationCommand(
        keyCode: UInt16,
        flags: NSEvent.ModifierFlags,
        queryIsEmpty: Bool,
        hasTextSelection: Bool
    ) -> ClipboardPanelKeyCommand? {
        switch keyCode {
        case 126 where flags.isEmpty: return .moveUp
        case 125 where flags.isEmpty: return .moveDown
        // Horizontal arrows control the pane only when there is no search text or text selection to edit.
        case 124 where flags.isEmpty && queryIsEmpty && !hasTextSelection: return .showPreview
        case 123 where flags.isEmpty && queryIsEmpty && !hasTextSelection: return .hidePreview
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
