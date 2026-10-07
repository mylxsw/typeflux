import AppKit
import Foundation
import Testing
@testable import Typeflux

/// Files in the real launcher, driven by key presses: Return opens, → shows the
/// actions, their shortcuts work on the highlighted file, ⌘↓ shows them all.
extension AskQuickResultsInteractionTests {
    /// What the launcher did with files instead of really doing it.
    @MainActor final class FileHost {
        let index: AskTestFileIndex
        var urls: [URL] = []
        var revealed: [URL] = []
        var trashed: [URL] = []
        var openedWith: [(URL, URL)] = []
        var exists = true

        init(_ index: AskTestFileIndex = AskTestFileIndex.sample) { self.index = index }

        func install(in model: AskConversationModel) {
            model.fileIndex = index
            model.openURL = { [unowned self] in urls.append($0) }
            model.revealFile = { [unowned self] in revealed.append($0) }
            model.trashFile = { [unowned self] in trashed.append($0); return true }
            model.openFileWith = { [unowned self] in openedWith.append(($0, $1)) }
            model.fileExists = { [unowned self] _ in exists }
        }
    }

    static let right: UInt16 = 124, keyR: UInt16 = 15, keyC: UInt16 = 8

    private func launcher(_ text: String, host: FileHost) async throws -> Launcher {
        let launcher = try await Launcher(text: text, apps: AskTestAppIndex(AskTestAppIndex.sample.entries)) { host.install(in: $0) }
        launcher.editor.setSelectedRange(NSRange(location: (launcher.editor.string as NSString).length, length: 0))
        return launcher
    }

    @Test func returnOpensTheBestFileAndRemembersIt() async throws {
        try await withPasteboard { _ in
            let host = FileHost()
            let launcher = try await launcher("hetong", host: host)
            defer { launcher.close() }
            try await launcher.press(Self.returnKey)
            #expect(host.urls == [URL(fileURLWithPath: "/Users/test/Documents/合同", isDirectory: true)])
            #expect(host.index.opened == ["/Users/test/Documents/合同"])
            #expect(launcher.dismissed == 1)
            #expect(launcher.fixture.model.launcherDraft.text.isEmpty)
        }
    }

    @Test func arrowsReachAFileBelowAskAI() async throws {
        try await withPasteboard { pasteboard in
            let host = FileHost()
            let launcher = try await launcher("invoice", host: host)
            defer { launcher.close() }
            try await launcher.press(Self.down)
            try await launcher.press(Self.keyR, .command)
            #expect(host.revealed == [URL(fileURLWithPath: "/Users/test/Documents/发票/invoice-2026-09.pdf")])
            #expect(launcher.dismissed == 1)

            let second = try await self.launcher("invoice", host: host)
            defer { second.close() }
            try await second.press(Self.down)
            try await second.press(Self.keyC, [.command, .shift])
            #expect(pasteboard.string(forType: .string) == "/Users/test/Documents/发票/invoice-2026-09.pdf")

            let third = try await self.launcher("invoice", host: host)
            defer { third.close() }
            try await third.press(Self.down)
            try await third.press(Self.keyC, [.command, .option])
            #expect(pasteboard.readObjects(forClasses: [NSURL.self])?.first as? URL
                == URL(fileURLWithPath: "/Users/test/Documents/发票/invoice-2026-09.pdf"))
        }
    }

    @Test func rightArrowOpensTheActions() async throws {
        try await withPasteboard { _ in
            let host = FileHost()
            let launcher = try await launcher("invoice", host: host)
            defer { launcher.close() }
            try await launcher.press(Self.down)
            try await launcher.press(Self.right)
            // Open, Open With…, Show in Finder.
            try await launcher.press(Self.down)
            try await launcher.press(Self.down)
            try await launcher.press(Self.returnKey)
            #expect(host.revealed.count == 1)
            #expect(host.urls.isEmpty, "Return ran the chosen action, not the row")
            #expect(launcher.dismissed == 1)
        }
    }

    @Test func movingToTheTrashAsksTwice() async throws {
        try await withPasteboard { _ in
            let host = FileHost()
            let launcher = try await launcher("invoice", host: host)
            defer { launcher.close() }
            try await launcher.press(Self.down)
            try await launcher.press(Self.right)
            try await launcher.press(Self.up)
            try await launcher.press(Self.returnKey)
            #expect(host.trashed.isEmpty, "the first Return only asks")
            #expect(launcher.dismissed == 0)
            try await launcher.press(Self.returnKey)
            #expect(host.trashed.count == 1)
            #expect(host.index.forgotten.count == 1)
            #expect(launcher.dismissed == 1)
        }
    }

    @Test func escapeClosesTheActionsFirst() async throws {
        try await withPasteboard { _ in
            let host = FileHost()
            let launcher = try await launcher("invoice", host: host)
            defer { launcher.close() }
            try await launcher.press(Self.down)
            try await launcher.press(Self.right)
            try await launcher.press(Self.escape)
            #expect(launcher.dismissed == 0)
            try await launcher.press(Self.returnKey)
            #expect(host.urls.count == 1, "back on the row, Return opens it")
        }
    }

    @Test func aFileThatIsGoneIsForgotten() async throws {
        try await withPasteboard { _ in
            let host = FileHost()
            host.exists = false
            let launcher = try await launcher("hetong", host: host)
            defer { launcher.close() }
            try await launcher.press(Self.returnKey)
            #expect(host.urls.isEmpty)
            #expect(host.index.forgotten == ["/Users/test/Documents/合同"])
            #expect(launcher.dismissed == 0)
        }
    }

    @Test func askingAboutAFileAttachesIt() async throws {
        try await withPasteboard { _ in
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ask-attach-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let file = folder.appendingPathComponent("brief.txt")
            try Data("hello".utf8).write(to: file)
            let host = FileHost(AskTestFileIndex([(file.path, .file, 0)]))
            let launcher = try await launcher("brief", host: host)
            defer { launcher.close() }
            try await launcher.press(Self.returnKey, [.command, .shift])
            for _ in 0 ..< 200 where (launcher.fixture.model.launcherDraft.attachments ?? []).isEmpty {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(launcher.fixture.model.launcherDraft.attachments?.count == 1)
            #expect(launcher.fixture.model.launcherDraft.text.isEmpty)
            #expect(launcher.dismissed == 0, "the question is still to be written")
        }
    }

    @Test func commandDownShowsAllFiles() async throws {
        try await withPasteboard { _ in
            let host = FileHost()
            let launcher = try await launcher("invoice", host: host)
            defer { launcher.close() }
            launcher.fixture.model.plugins.debounce = .milliseconds(10)
            try await launcher.press(125, .command)
            for _ in 0 ..< 200 where !launcher.fixture.model.plugins.isActive {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(launcher.fixture.model.plugins.keyword?.pluginID == AskFileSearchPlugin.id)
            #expect(launcher.fixture.model.launcherDraft.text == "invoice")
            for _ in 0 ..< 300 where launcher.fixture.model.plugins.output == nil {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(launcher.fixture.model.plugins.output?.items.count == 2)
            try await launcher.press(Self.returnKey)
            #expect(host.urls == [URL(fileURLWithPath: "/Users/test/Documents/发票/invoice-2026-09.pdf")])
            #expect(host.index.opened == ["/Users/test/Documents/发票/invoice-2026-09.pdf"])
        }
    }

    @Test func turnedOffFileSearchListsNoFiles() async throws {
        try await withPasteboard { _ in
            let host = FileHost()
            let launcher = try await Launcher(text: "invoice") { model in
                host.install(in: model)
                model.modelLibrary.settings.askQuickFileSearchEnabled = false
            }
            defer { launcher.close() }
            try await launcher.press(Self.returnKey)
            #expect(host.urls.isEmpty)
            #expect(try await launcher.sentCount() == 1, "the text went to the AI")
        }
    }

    @Test func refreshingStartsTheFileIndex() throws {
        let fixture = try AskTestFixture()
        defer { fixture.model.resetSession() }
        let files = AskTestFileIndex()
        fixture.model.fileIndex = files
        fixture.model.appIndex = AskTestAppIndex([])
        fixture.model.refreshQuickApps()
        #expect(files.starts == 1)
        #expect(fixture.model.quickFilesEnabled)
        #expect(fixture.model.launcherSearchSettings == AskLauncherSearchSettings())
    }
}
