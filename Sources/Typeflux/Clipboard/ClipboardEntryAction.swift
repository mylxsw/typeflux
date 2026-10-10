import Foundation

/// Something the user can do with a clipboard panel row.
enum ClipboardEntryAction: Equatable, CaseIterable {
    case paste
    /// Text: same as paste. Files: pastes their paths as text.
    case pastePlainText
    /// Text: edit in the panel, then paste; the stored entry is unchanged.
    case editBeforePaste
    case copy
    case quickLook
    case revealInFinder
    case saveToDownloads
    case copyImageText
    case retryTranscription
    /// Filters the panel to entries copied from the same app.
    case showOnlyApp
    case togglePin
    case delete
    /// Deletes every unpinned entry copied from the same app, after confirming.
    case deleteAllFromApp

    /// Actions that need the entry's files to still exist.
    var requiresContent: Bool {
        switch self {
        case .paste, .pastePlainText, .copy, .quickLook, .revealInFinder, .saveToDownloads, .copyImageText: true
        case .editBeforePaste, .retryTranscription, .showOnlyApp, .togglePin, .delete, .deleteAllFromApp: false
        }
    }

    /// The actions offered for an entry, in menu order.
    static func available(for entry: ClipboardEntry) -> [ClipboardEntryAction] {
        var actions: [ClipboardEntryAction] = [.paste]
        if entry.kind.isTextual || !entry.filePaths.isEmpty {
            actions.append(.pastePlainText)
        }
        if entry.kind.isTextual, entry.text != nil {
            actions.append(.editBeforePaste)
        }
        actions.append(.copy)
        actions += contentActions(for: entry)
        let fromApp = ClipboardAppFilter(entry: entry) != nil
        if fromApp {
            actions.append(.showOnlyApp)
        }
        actions.append(contentsOf: [.togglePin, .delete])
        if fromApp {
            actions.append(.deleteAllFromApp)
        }
        return actions
    }

    /// Previews and file actions, between copying and pinning.
    private static func contentActions(for entry: ClipboardEntry) -> [ClipboardEntryAction] {
        var actions: [ClipboardEntryAction] = []
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
        return actions
    }

    func title(for entry: ClipboardEntry) -> String {
        if self == .pastePlainText, !entry.kind.isTextual { return L("clipboard.action.pastePath") }
        if self == .togglePin, entry.isPinned { return L("clipboard.action.unpin") }
        if self == .showOnlyApp || self == .deleteAllFromApp {
            return L(titleKey, entry.sourceAppName ?? entry.sourceBundleID ?? "")
        }
        return L(titleKey)
    }

    private var titleKey: String {
        switch self {
        case .togglePin: "clipboard.action.pin"
        default: "clipboard.action.\(self)"
        }
    }

    /// The shortcut shown next to the action in the menu.
    var shortcutLabel: String? {
        switch self {
        case .paste: "↩"
        case .pastePlainText: "⌘↩"
        case .editBeforePaste: "⌘E"
        case .copy: "⌘C"
        case .quickLook: "⌘Y"
        case .togglePin: "⌘P"
        case .delete: "⌘⌫"
        case .revealInFinder, .saveToDownloads, .copyImageText, .retryTranscription, .showOnlyApp,
             .deleteAllFromApp: nil
        }
    }
}
