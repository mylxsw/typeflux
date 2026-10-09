import AppKit
import QuickLookThumbnailing
import QuartzCore
import Quartz
import SwiftUI

/// Something done with a highlighted application or file besides opening it.
enum AskQuickAction: Equatable {
    case open
    /// Lists the applications that can open the file.
    case openWith
    /// Opens the file in one of those applications.
    case openIn(URL)
    case reveal
    case quickLook
    case copyPath
    case copyFile
    case copyName
    /// A new question with the file attached.
    case askAI
    case openInTerminal
    /// File mode limited to this folder.
    case searchInFolder
    case quit
    case trash

    var title: String {
        switch self {
        case .open: L("ask.quick.action.open")
        case .openWith: L("ask.quick.action.openWith")
        case let .openIn(url): FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        case .reveal: L("ask.quick.action.reveal")
        case .quickLook: L("ask.quick.action.quickLook")
        case .copyPath: L("ask.quick.action.copyPath")
        case .copyFile: L("ask.quick.action.copyFile")
        case .copyName: L("ask.quick.action.copyName")
        case .askAI: L("ask.quick.action.askAI")
        case .openInTerminal: L("ask.quick.action.terminal")
        case .searchInFolder: L("ask.quick.action.searchIn")
        case .quit: L("ask.quick.action.quit")
        case .trash: L("ask.quick.action.trash")
        }
    }

    var symbol: String {
        switch self {
        case .open: "arrow.up.forward.app"
        case .openWith, .openIn: "square.grid.2x2"
        case .reveal: "folder"
        case .quickLook: "eye"
        case .copyPath: "link"
        case .copyFile: "doc.on.doc"
        case .copyName: "textformat"
        case .askAI: "sparkles"
        case .openInTerminal: "terminal"
        case .searchInFolder: "magnifyingglass"
        case .quit: "power"
        case .trash: "trash"
        }
    }

    /// The key that does this without opening the panel.
    var shortcut: String? {
        switch self {
        case .open: "↩"
        case .openWith: "⌥↩"
        case .reveal: "⌘R"
        case .quickLook: "⌘Y"
        case .copyPath: "⇧⌘C"
        case .copyFile: "⌥⌘C"
        case .askAI: "⇧⌘↩"
        case .openIn, .copyName, .openInTerminal, .searchInFolder, .quit, .trash: nil
        }
    }

    var destructive: Bool { self == .trash || self == .quit }
}

/// What a highlighted row offers when → opens its actions.
struct AskQuickActionPanel: Equatable {
    enum Target: Equatable {
        case app(AskAppEntry)
        case file(AskFileHit)
    }

    var target: Target
    var actions: [AskQuickAction]
    var highlighted = 0
    /// Moving to the trash waits for a second Return.
    var confirming = false

    var title: String {
        switch target {
        case let .app(app): app.name
        case let .file(file): file.name
        }
    }

    var highlightedAction: AskQuickAction? {
        actions.indices.contains(highlighted) ? actions[highlighted] : nil
    }

    init(target: Target, actions: [AskQuickAction]) {
        self.target = target
        self.actions = actions
    }

    /// The actions for an application, settings pane, file or folder; nil when there is nothing beyond opening.
    static func make(for target: Target, running: (String) -> Bool = AskQuickActionPanel.isRunning) -> AskQuickActionPanel? {
        let actions: [AskQuickAction]
        switch target {
        case let .app(app):
            guard app.kind == .application else { return nil }
            actions = [.open, .reveal, .copyPath] + (app.bundleID.map(running) == true ? [.quit] : [])
        case let .file(file):
            switch file.kind {
            case .folder: actions = [.open, .reveal, .openInTerminal, .copyPath, .searchInFolder, .askAI]
            case .file, .package:
                actions = [.open, .openWith, .reveal, .quickLook, .copyPath, .copyFile, .copyName, .askAI, .trash]
            }
        }
        return AskQuickActionPanel(target: target, actions: actions)
    }

    /// The applications that open `url`, the default first.
    static func applications(for url: URL) -> [AskQuickAction] {
        let all = NSWorkspace.shared.urlsForApplications(toOpen: url)
        return all.prefix(10).map { .openIn($0) }
    }

    static func isRunning(_ bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    mutating func move(_ delta: Int) {
        guard !actions.isEmpty else { return }
        highlighted = ((highlighted + delta) % actions.count + actions.count) % actions.count
        confirming = false
    }
}

/// The actions panel beside the results: ↑↓ choose, ↩ runs, ← or esc closes.
struct AskQuickActionPanelView: View {
    var panel: AskQuickActionPanel
    var onAction: (AskQuickAction) -> Void

    static let width: CGFloat = 268

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(panel.title).font(.system(size: 11)).foregroundStyle(StudioTheme.textTertiary)
                .lineLimit(1).truncationMode(.middle)
                .padding(.horizontal, 8).padding(.top, 4).padding(.bottom, 4)
            ForEach(Array(panel.actions.enumerated()), id: \.offset) { index, action in
                Button { onAction(action) } label: { row(action, highlighted: index == panel.highlighted) }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("ask.quick.action")
            }
        }
        .padding(5)
        .frame(width: Self.width)
        .background(AskTheme.popoverSurface, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(AskTheme.separator, lineWidth: 1))
        .shadow(color: .black.opacity(0.28), radius: 18, y: 8)
    }

    private func row(_ action: AskQuickAction, highlighted: Bool) -> some View {
        let confirm = highlighted && panel.confirming
        let tint: Color = highlighted ? .white : action.destructive ? StudioTheme.danger : StudioTheme.textPrimary
        return HStack(spacing: 8) {
            Group {
                if case let .openIn(url) = action {
                    AskFileIconView(url: url, thumbnail: false)
                } else {
                    Image(systemName: action.symbol).font(.system(size: 11.5, weight: .medium))
                }
            }
            .frame(width: 16, height: 16)
            Text(confirm ? L("ask.quick.action.trash.confirm") : action.title).font(.system(size: 12.5)).lineLimit(1)
            Spacer(minLength: 6)
            if let shortcut = action.shortcut {
                Text(shortcut).font(.system(size: 11)).foregroundStyle(highlighted ? Color.white.opacity(0.8) : StudioTheme.textTertiary)
            }
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(highlighted ? (action.destructive ? StudioTheme.danger : AskTheme.accent) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
    }
}

/// A file's Finder icon, replaced by a thumbnail of its contents for pictures and PDFs.
struct AskFileIconView: View {
    var url: URL
    var thumbnail: Bool
    var modified: Date?
    @State private var image: NSImage?
    @State private var imageURL: URL?

    private var key: AskResultImageCache.Key {
        .init(url: url, thumbnail: thumbnail && AskFileType.hasThumbnail(url.pathExtension.lowercased()),
              modified: modified, scale: NSScreen.main?.backingScaleFactor ?? 2)
    }

    var body: some View {
        Group {
            if let shown = AskResultImageCache.shared.cached(key) ?? (imageURL == url ? image : nil) {
                Image(nsImage: shown).resizable().interpolation(.high).scaledToFit()
            } else {
                Image(systemName: url.hasDirectoryPath ? "folder" : "doc")
                    .resizable().scaledToFit().padding(3).foregroundStyle(StudioTheme.textTertiary)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: thumbnail ? 4 : 0, style: .continuous))
        .accessibilityHidden(true)
        .task(id: key) {
            let loaded = await AskResultImageCache.shared.image(key)
            guard !Task.isCancelled else { return }
            if let loaded { image = loaded; imageURL = url }
        }
    }
}

/// The system's Quick Look panel for one file, opened from the launcher with ⌘Y.
@MainActor
final class AskQuickLook: NSObject, QLPreviewPanelDataSource {
    static let shared = AskQuickLook()
    private var url: URL?

    var isVisible: Bool { QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible }

    /// Shows `url`, or closes the panel when it already shows it.
    func toggle(_ url: URL) {
        if isVisible, self.url == url { close(); return }
        self.url = url
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.reloadData()
        // In front without taking the keyboard, so the launcher keeps it.
        panel.orderFront(nil)
    }

    func close() {
        guard QLPreviewPanel.sharedPreviewPanelExists() else { return }
        QLPreviewPanel.shared().orderOut(nil)
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { 1 }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        MainActor.assumeIsolated { url as NSURL? }
    }
}
