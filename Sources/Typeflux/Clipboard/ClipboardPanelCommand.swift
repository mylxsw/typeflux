import Foundation

/// Panel-level requests the clipboard panel model forwards to its owner, as opposed to actions
/// on a single entry (`ClipboardEntryAction`).
enum ClipboardPanelCommand: Equatable {
    case togglePause
    case openSettings
    /// Deletes every unpinned clipboard item; voice history is kept.
    case clearUnpinned
    /// Deletes the unpinned clipboard items copied from one app.
    case deleteApp(bundleID: String)
    /// Pastes text edited in the panel; the stored item is unchanged.
    case pasteText(String)
}

/// A destructive panel command waiting for the user to confirm it in the panel.
enum ClipboardPanelConfirmation: Equatable {
    case clearUnpinned(count: Int)
    case deleteApp(ClipboardAppFilter, count: Int)

    var command: ClipboardPanelCommand {
        switch self {
        case .clearUnpinned: .clearUnpinned
        case let .deleteApp(app, _): .deleteApp(bundleID: app.bundleID)
        }
    }

    var message: String {
        switch self {
        case let .clearUnpinned(count): L("clipboard.confirm.clearUnpinned", count)
        case let .deleteApp(app, count): L("clipboard.confirm.deleteApp", count, app.name)
        }
    }
}

/// Restricts the panel to entries copied from one app.
struct ClipboardAppFilter: Equatable {
    let bundleID: String
    let name: String

    init(bundleID: String, name: String) {
        self.bundleID = bundleID
        self.name = name
    }

    /// The app an entry came from; `nil` for voice results and records without a source.
    init?(entry: ClipboardEntry) {
        guard case .clipboard = entry.origin, let bundleID = entry.sourceBundleID, !bundleID.isEmpty else {
            return nil
        }
        self.init(bundleID: bundleID, name: entry.sourceAppName ?? bundleID)
    }
}
