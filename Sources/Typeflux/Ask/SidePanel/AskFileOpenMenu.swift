import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Opening a workspace file outside Typeflux. The file row's hover button, its context
/// menu and the file tab's toolbar all offer these same actions.
@MainActor
struct AskFileExternalActions {
    struct Application: Equatable, Identifiable {
        let url: URL
        let name: String
        var id: URL { url }
    }

    /// The Launch Services and Finder calls, replaceable in tests.
    struct System {
        var defaultApplication: (URL) -> URL?
        var applications: (URL) -> [URL]
        var open: (URL) -> Void
        var openWith: (URL, URL) -> Void
        var reveal: (URL) -> Void

        static let live = System(
            defaultApplication: { NSWorkspace.shared.urlForApplication(toOpen: $0) },
            applications: { NSWorkspace.shared.urlsForApplications(toOpen: $0) },
            open: { NSWorkspace.shared.open($0) },
            openWith: { file, application in
                NSWorkspace.shared.open([file], withApplicationAt: application,
                                        configuration: NSWorkspace.OpenConfiguration())
            },
            reveal: { NSWorkspace.shared.activateFileViewerSelecting([$0]) }
        )
    }

    var system = System.live
    var pasteboard: NSPasteboard = .general

    static func isHTML(_ url: URL) -> Bool { ["html", "htm"].contains(url.pathExtension.lowercased()) }

    func defaultApplication(for file: URL) -> Application? {
        system.defaultApplication(file).map(Self.application)
    }

    func defaultBrowser() -> Application? {
        URL(string: "https://example.com").flatMap(system.defaultApplication).map(Self.application)
    }

    /// Apps that can open the file, the default first, without duplicates.
    func applications(for file: URL, limit: Int = 16) -> [Application] {
        var seen = Set<String>()
        return system.applications(file)
            .filter { seen.insert($0.standardizedFileURL.path).inserted }
            .prefix(limit)
            .map(Self.application)
    }

    static func application(_ url: URL) -> Application {
        let name = FileManager.default.displayName(atPath: url.path)
        return Application(url: url, name: name.hasSuffix(".app") ? String(name.dropLast(4)) : name)
    }

    func openWithDefaultApplication(_ file: URL) { system.open(file) }

    func open(_ file: URL, with application: URL) { system.openWith(file, application) }

    /// HTML in the default browser rather than whichever editor claims `.html`.
    func openInBrowser(_ file: URL) {
        guard let browser = defaultBrowser() else { system.open(file); return }
        open(file, with: browser.url)
    }

    func revealInFinder(_ file: URL) { system.reveal(file) }

    func copyFile(_ file: URL) {
        pasteboard.clearContents()
        pasteboard.writeObjects([file as NSURL])
    }

    func copyPath(_ file: URL) {
        pasteboard.clearContents()
        pasteboard.setString(file.path, forType: .string)
    }

    /// Copies the file to a location the user picks.
    func saveAs(_ file: URL) throws {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = AskWorkspaceFile.displayName(file.path)
        if let type = UTType(filenameExtension: file.pathExtension) { panel.allowedContentTypes = [type] }
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        try Self.export(file, to: destination)
    }

    /// The save panel already confirmed replacing an existing file.
    static func export(_ file: URL, to destination: URL) throws {
        guard file.standardizedFileURL != destination.standardizedFileURL else { return }
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: copy(file, near: destination))
        } else {
            try FileManager.default.copyItem(at: file, to: destination)
        }
    }

    private static func copy(_ file: URL, near destination: URL) throws -> URL {
        let staged = destination.deletingLastPathComponent()
            .appendingPathComponent(".typeflux-" + UUID().uuidString + "-" + destination.lastPathComponent)
        try FileManager.default.copyItem(at: file, to: staged)
        return staged
    }
}

/// The shared menu items for one file. With `showsShortcuts`, ⌘⇧R is listed beside
/// their items; a file row's hover menu leaves them out, so a list of rows never claims them.
struct AskFileOpenMenuItems: View {
    let file: URL
    var actions = AskFileExternalActions()
    var showsShortcuts = true
    /// Adds the file to the composer; listed first when the conversation can take it.
    var onReference: (() -> Void)?
    var onError: (String) -> Void = { _ in }

    /// Both the row context menu and the toolbar use these commands and their order.
    private enum Entry {
        case action(String, shortcut: Bool = false, () -> Void)
        case applications(String, [AskFileExternalActions.Application])
        case divider
    }

    private var entries: [Entry] {
        var entries: [Entry] = []
        if let onReference {
            entries += [.action(L("ask.sidePanel.reference"), onReference), .divider]
        }
        let app = actions.defaultApplication(for: file)
        let openTitle = app.map { L("ask.sidePanel.open.withApp", $0.name) } ?? L("ask.sidePanel.open.default")
        entries.append(.action(openTitle) { actions.openWithDefaultApplication(file) })
        if AskFileExternalActions.isHTML(file) {
            entries.append(.action(L("ask.sidePanel.open.browser")) { actions.openInBrowser(file) })
        }
        entries += [
            .applications(L("ask.sidePanel.open.with"), actions.applications(for: file)), .divider,
            .action(L("ask.sidePanel.revealInFinder"), shortcut: showsShortcuts) { actions.revealInFinder(file) },
            .action(L("ask.sidePanel.copyFile")) { actions.copyFile(file) },
            .action(L("ask.sidePanel.copyPath")) { actions.copyPath(file) }, .divider,
            .action(L("ask.sidePanel.saveAs")) {
                do { try actions.saveAs(file) } catch { onError(error.localizedDescription) }
            }
        ]
        return entries
    }

    var body: some View {
        ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
            switch entry {
            case let .action(title, shortcut, perform):
                Button(title, action: perform)
                    .keyboardShortcut(shortcut ? KeyboardShortcut("r", modifiers: [.command, .shift]) : nil)
            case let .applications(title, apps):
                Menu(title) {
                    if apps.isEmpty { Text(L("ask.sidePanel.open.noApps")) }
                    ForEach(apps) { app in
                        Button(app.name) { actions.open(file, with: app.url) }
                    }
                }
            case .divider: Divider()
            }
        }
    }

    /// Present only the menu. The toolbar's ordinary icon button owns all drawing and hit testing.
    func popUp(below anchor: NSView) {
        let menu = NSMenu()
        for entry in entries {
            switch entry {
            case let .action(title, shortcut, perform):
                let item = CommandItem(title: title, perform: perform)
                if shortcut {
                    item.keyEquivalent = "r"
                    item.keyEquivalentModifierMask = [.command, .shift]
                }
                menu.addItem(item)
            case let .applications(title, apps):
                let submenu = NSMenu(title: title)
                if apps.isEmpty { submenu.addItem(withTitle: L("ask.sidePanel.open.noApps"), action: nil, keyEquivalent: "") }
                for app in apps {
                    submenu.addItem(CommandItem(title: app.name) { actions.open(file, with: app.url) })
                }
                menu.addItem(withTitle: title, action: nil, keyEquivalent: "").submenu = submenu
            case .divider: menu.addItem(.separator())
            }
        }
        let bottom = anchor.isFlipped ? anchor.bounds.maxY : anchor.bounds.minY
        menu.popUp(positioning: nil, at: NSPoint(x: anchor.bounds.minX, y: bottom), in: anchor)
    }

    private final class CommandItem: NSMenuItem {
        let perform: () -> Void

        init(title: String, perform: @escaping () -> Void) {
            self.perform = perform
            super.init(title: title, action: #selector(choose), keyEquivalent: "")
            target = self
        }

        @available(*, unavailable)
        required init(coder _: NSCoder) { fatalError() }

        @objc private func choose() { perform() }
    }
}

/// One neutral trigger for file commands in list rows, change summaries and the preview toolbar.
struct AskFileMoreButton: View {
    let items: AskFileOpenMenuItems
    var size: TFControlSize = .small
    @State private var anchor = AskHoverAnchor.Holder()

    var body: some View {
        TFButton(title: L("ask.sidePanel.open.menu"), systemImage: "ellipsis", kind: .plain,
                 size: size, iconOnly: true) {
            if let view = anchor.view { items.popUp(below: view) }
        }
        .background(AskHoverAnchor(holder: anchor))
    }
}

/// "Reference in message": the file joins the composer as an attachment for the next message.
struct AskFileReferenceButton: View {
    var action: () -> Void
    var size: CGFloat = 24

    var body: some View {
        Button(action: action) {
            Image(systemName: "text.badge.plus").font(.system(size: 12))
                .foregroundStyle(StudioTheme.textSecondary)
                .frame(width: size, height: size)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L("ask.sidePanel.reference"))
        .accessibilityLabel(L("ask.sidePanel.reference"))
    }
}

extension View {
    /// Rows combine their children for VoiceOver, so their hover-only reference button is
    /// offered as a named action instead.
    @ViewBuilder func accessibilityReferenceAction(_ action: (() -> Void)?) -> some View {
        if let action { accessibilityAction(named: L("ask.sidePanel.reference"), action) } else { self }
    }
}
