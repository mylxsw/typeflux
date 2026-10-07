import Foundation

/// Something the user can do with a clipboard panel row.
enum ClipboardEntryAction: Equatable, CaseIterable {
    case paste
    /// Text: same as paste. Files: pastes their paths as text.
    case pastePlainText
    case copy
    case quickLook
    case revealInFinder
    case saveToDownloads
    case copyImageText
    case retryTranscription
    case togglePin
    case delete

    /// Actions that need the entry's files to still exist.
    var requiresContent: Bool {
        switch self {
        case .paste, .pastePlainText, .copy, .quickLook, .revealInFinder, .saveToDownloads, .copyImageText: true
        case .retryTranscription, .togglePin, .delete: false
        }
    }

    /// The actions offered for an entry, in menu order.
    static func available(for entry: ClipboardEntry) -> [ClipboardEntryAction] {
        var actions: [ClipboardEntryAction] = [.paste]
        if entry.kind.isTextual || !entry.filePaths.isEmpty {
            actions.append(.pastePlainText)
        }
        actions.append(.copy)
        if !entry.kind.isTextual {
            actions.append(.quickLook)
        }
        if !entry.filePaths.isEmpty {
            actions.append(.revealInFinder)
        }
        if entry.imagePath != nil {
            actions.append(.saveToDownloads)
        }
        if entry.kind == .image {
            actions.append(.copyImageText)
        }
        if entry.kind == .voice {
            actions.append(.retryTranscription)
        }
        actions.append(contentsOf: [.togglePin, .delete])
        return actions
    }

    func title(for entry: ClipboardEntry) -> String {
        if self == .pastePlainText, !entry.kind.isTextual { return L("clipboard.action.pastePath") }
        if self == .togglePin, entry.isPinned { return L("clipboard.action.unpin") }
        return switch self {
        case .paste: L("clipboard.action.paste")
        case .pastePlainText: L("clipboard.action.pastePlainText")
        case .copy: L("clipboard.action.copy")
        case .quickLook: L("clipboard.action.quickLook")
        case .revealInFinder: L("clipboard.action.revealInFinder")
        case .saveToDownloads: L("clipboard.action.saveToDownloads")
        case .copyImageText: L("clipboard.action.copyImageText")
        case .retryTranscription: L("clipboard.action.retryTranscription")
        case .togglePin: L("clipboard.action.pin")
        case .delete: L("clipboard.action.delete")
        }
    }

    /// The shortcut shown next to the action in the menu.
    var shortcutLabel: String? {
        switch self {
        case .paste: "↩"
        case .pastePlainText: "⌘↩"
        case .copy: "⌘C"
        case .quickLook: "⌘Y"
        case .togglePin: "⌘P"
        case .delete: "⌘⌫"
        case .revealInFinder, .saveToDownloads, .copyImageText, .retryTranscription: nil
        }
    }
}
