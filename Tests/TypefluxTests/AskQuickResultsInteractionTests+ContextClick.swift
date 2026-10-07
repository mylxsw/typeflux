import AppKit
import Testing
@testable import Typeflux

/// Native context clicks in the real launcher, sharing its keyboard action panel.
extension AskQuickResultsInteractionTests {
    private func contextLauncher(_ text: String, host: FileHost) async throws -> Launcher {
        try await Launcher(text: text) { host.install(in: $0) }
    }

    private func contextRows(in launcher: Launcher) throws -> [AskQuickResultSecondaryClick.Control] {
        let root = try #require(launcher.window.contentView)
        root.layoutSubtreeIfNeeded()
        func collect(_ view: NSView) -> [AskQuickResultSecondaryClick.Control] {
            if let control = view as? AskQuickResultSecondaryClick.Control { return [control] }
            return view.subviews.flatMap(collect)
        }
        return collect(root).sorted {
            let first = $0.convert($0.bounds, to: root), second = $1.convert($1.bounds, to: root)
            return root.isFlipped ? first.minY < second.minY : first.maxY > second.maxY
        }
    }

    private func clickFile(_ index: Int, in launcher: Launcher, right: Bool = true,
                           flags: NSEvent.ModifierFlags = []) async throws {
        let rows = try contextRows(in: launcher)
        #expect(rows.indices.contains(index))
        let row = try #require(rows.indices.contains(index) ? rows[index] : nil)
        // The left side stays outside the action panel, even when replacing an open menu.
        let point = row.convert(NSPoint(x: 20, y: row.bounds.midY), to: nil)
        for type in right ? [NSEvent.EventType.rightMouseDown, .rightMouseUp] : [.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: flags,
                                                       timestamp: ProcessInfo.processInfo.systemUptime,
                                                       windowNumber: launcher.window.windowNumber, context: nil,
                                                       eventNumber: 0, clickCount: 1, pressure: 1))
            // sendEvent exercises native hit testing without reentering the command-line
            // runner's async main loop. Only the current-event lookup needs injection.
            let previous = rows.map(\.currentEvent)
            defer { for (control, read) in zip(rows, previous) { control.currentEvent = read } }
            for control in rows { control.currentEvent = { event } }
            NSApp.sendEvent(event)
        }
        try await Task.sleep(for: .milliseconds(50))
    }

    @Test func rightClickOpensActionsForTheClickedFileWithoutOpeningIt() async throws {
        try await withPasteboard { _ in
            let host = FileHost()
            let launcher = try await contextLauncher("invoice", host: host)
            defer { launcher.close() }
            #expect(try contextRows(in: launcher).count == 2)
            try await clickFile(1, in: launcher)
            #expect(host.urls.isEmpty && launcher.dismissed == 0)
            #expect(launcher.window.firstResponder === launcher.editor, "context clicks keep keyboard focus")
            try await launcher.press(Self.down)
            try await launcher.press(Self.down)
            try await launcher.press(Self.returnKey)
            #expect(host.revealed == [URL(fileURLWithPath: "/Users/test/Downloads/invoice-2026-08.pdf")])
            #expect(host.urls.isEmpty && launcher.dismissed == 1)
        }
    }

    @Test func escapeReturnsToTheRightClickedFile() async throws {
        try await withPasteboard { _ in
            let host = FileHost()
            let launcher = try await contextLauncher("invoice", host: host)
            defer { launcher.close() }
            try await clickFile(1, in: launcher)
            try await launcher.press(Self.escape)
            #expect(launcher.dismissed == 0)
            try await launcher.press(Self.returnKey)
            #expect(host.urls == [URL(fileURLWithPath: "/Users/test/Downloads/invoice-2026-08.pdf")])
        }
    }

    @Test func rightClickingAFolderOffersFolderActions() async throws {
        try await withPasteboard { pasteboard in
            let host = FileHost(AskTestFileIndex([("/Users/test/Documents/Reports", .folder, 0)]))
            let launcher = try await contextLauncher("Reports", host: host)
            defer { launcher.close() }
            try await clickFile(0, in: launcher)
            #expect(host.urls.isEmpty && launcher.dismissed == 0)
            // Folder actions: Open, Reveal, Open in Terminal, Copy Path.
            for _ in 0 ..< 3 { try await launcher.press(Self.down) }
            try await launcher.press(Self.returnKey)
            #expect(pasteboard.string(forType: .string) == "/Users/test/Documents/Reports")
            #expect(host.openedWith.isEmpty && host.urls.isEmpty)
        }
    }

    @Test func controlClickCanReplaceAnOpenFileMenu() async throws {
        try await withPasteboard { pasteboard in
            let host = FileHost()
            let launcher = try await contextLauncher("invoice", host: host)
            defer { launcher.close() }
            try await clickFile(1, in: launcher)
            try await launcher.press(Self.up) // Highlight Trash in the first menu.
            try await clickFile(0, in: launcher, right: false, flags: .control)
            // The replacement starts at Open; Copy Path is four rows down.
            for _ in 0 ..< 4 { try await launcher.press(Self.down) }
            try await launcher.press(Self.returnKey)
            #expect(pasteboard.string(forType: .string) == "/Users/test/Documents/发票/invoice-2026-09.pdf")
            #expect(host.urls.isEmpty && host.trashed.isEmpty)
        }
    }

    @Test func leftClickStillOpensTheClickedFile() async throws {
        try await withPasteboard { _ in
            let host = FileHost()
            let launcher = try await contextLauncher("invoice", host: host)
            defer { launcher.close() }
            try await clickFile(1, in: launcher, right: false)
            #expect(host.urls == [URL(fileURLWithPath: "/Users/test/Downloads/invoice-2026-08.pdf")])
            #expect(launcher.dismissed == 1)
        }
    }

    @Test func rightClickingTrashStillRequiresConfirmation() async throws {
        try await withPasteboard { _ in
            let host = FileHost()
            let launcher = try await contextLauncher("invoice", host: host)
            defer { launcher.close() }
            try await clickFile(1, in: launcher)
            try await launcher.press(Self.up)
            try await launcher.press(Self.returnKey)
            #expect(host.trashed.isEmpty && launcher.dismissed == 0)
            try await launcher.press(Self.returnKey)
            #expect(host.trashed == [URL(fileURLWithPath: "/Users/test/Downloads/invoice-2026-08.pdf")])
            #expect(launcher.dismissed == 1)
        }
    }

    @Test func aContextClickFromAnOlderRenderFindsTheFileAfterResultsReorder() async throws {
        try await withPasteboard { _ in
            let host = FileHost()
            let launcher = try await contextLauncher("invoice", host: host)
            defer { launcher.close() }
            let oldClick = try #require(contextRows(in: launcher).last).onClick
            var refreshed = try #require(launcher.fixture.model.quickSearch.results)
            refreshed.files.reverse()
            launcher.fixture.model.quickSearch.results = refreshed
            try await Task.sleep(for: .milliseconds(50))
            oldClick()
            try await launcher.press(Self.down)
            try await launcher.press(Self.down)
            try await launcher.press(Self.returnKey)
            #expect(host.revealed == [URL(fileURLWithPath: "/Users/test/Downloads/invoice-2026-08.pdf")])
        }
    }

    @Test func aContextClickFromADismissedSearchDoesNotOpenAnOldMenu() async throws {
        try await withPasteboard { _ in
            let host = FileHost()
            let launcher = try await contextLauncher("invoice", host: host)
            defer { launcher.close() }
            let oldClick = try #require(contextRows(in: launcher).last).onClick
            launcher.fixture.model.launcherDraft.text = ""
            try await AskQuickSearchSessionTests.wait { launcher.fixture.model.quickSearch.results == nil }
            oldClick()
            try await launcher.press(Self.escape)
            #expect(launcher.dismissed == 1, "there is no old menu to consume Escape")
            #expect(host.urls.isEmpty && host.revealed.isEmpty && host.trashed.isEmpty)
        }
    }

    @Test func renderFileContextMenu() async throws {
        guard let directory = ProcessInfo.processInfo.environment["TYPEFLUX_ASK_SNAPSHOTS"] else { return }
        try await withPasteboard { _ in
            let files = (0 ..< 6).map { ("/Users/test/Documents/invoice-\($0).pdf", AskFileRecord.Kind.file, Double($0)) }
            let host = FileHost(AskTestFileIndex(files))
            let launcher = try await contextLauncher("invoice", host: host)
            defer { launcher.close() }
            launcher.window.setContentSize(NSSize(width: AskMetrics.launcherWidth, height: 520))
            try await clickFile(1, in: launcher)
            #expect(host.urls.isEmpty && launcher.dismissed == 0)
            let root = try #require(launcher.window.contentView)
            root.layoutSubtreeIfNeeded()
            let bitmap = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
            root.cacheDisplay(in: root.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            let folder = URL(fileURLWithPath: directory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try png.write(to: folder.appendingPathComponent("launcher-file-context-menu.png"))
        }
    }
}
