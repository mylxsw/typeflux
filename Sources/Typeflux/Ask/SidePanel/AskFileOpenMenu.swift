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

/// The shared menu items for one file. With `showsShortcuts`, ⌘O and ⌘⇧R are listed beside
/// their items; a file row's hover menu leaves them out, so a list of rows never claims them.
struct AskFileOpenMenuItems: View {
    let file: URL
    var actions = AskFileExternalActions()
    var showsShortcuts = true
    var onError: (String) -> Void = { _ in }

    var body: some View {
        let defaultApp = actions.defaultApplication(for: file)
        Button(defaultApp.map { L("ask.sidePanel.open.withApp", $0.name) } ?? L("ask.sidePanel.open.default")) {
            actions.openWithDefaultApplication(file)
        }
        .keyboardShortcut(showsShortcuts ? KeyboardShortcut("o", modifiers: .command) : nil)
        if AskFileExternalActions.isHTML(file) {
            Button(L("ask.sidePanel.open.browser")) { actions.openInBrowser(file) }
        }
        Menu(L("ask.sidePanel.open.with")) {
            let applications = actions.applications(for: file)
            if applications.isEmpty {
                Text(L("ask.sidePanel.open.noApps"))
            }
            ForEach(applications) { application in
                Button(application.name) { actions.open(file, with: application.url) }
            }
        }
        Divider()
        Button(L("ask.sidePanel.revealInFinder")) { actions.revealInFinder(file) }
            .keyboardShortcut(showsShortcuts ? KeyboardShortcut("r", modifiers: [.command, .shift]) : nil)
        Button(L("ask.sidePanel.copyFile")) { actions.copyFile(file) }
        Button(L("ask.sidePanel.copyPath")) { actions.copyPath(file) }
        Divider()
        Button(L("ask.sidePanel.saveAs")) {
            do { try actions.saveAs(file) } catch { onError(error.localizedDescription) }
        }
    }
}
