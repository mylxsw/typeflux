import AppKit
import Testing
@testable import Typeflux

extension AskQuickResultsInteractionTests {
    @Test func disablingNumberConversionsRefreshesTheOpenLauncherAndKeepsContentSearch() async throws {
        let host = FileHost(AskTestFileIndex([("/Users/test/Documents/2024.pdf", .file, 0)]))
        let launcher = try await Launcher(text: "2024", apps: AskTestAppIndex([AskTestAppIndex.app("2024")])) { host.install(in: $0) }
        defer { launcher.close() }
        let session = launcher.fixture.model.quickSearch
        let settings = launcher.fixture.model.modelLibrary.settings
        let view = LauncherSettingsView(settings: settings)
        #expect(session.results?.calculation?.isNumericInput == true)
        view.setQuickNumberConversions(false)
        try await AskQuickSearchSessionTests.wait { !session.isSearching && session.results?.calculation == nil }
        #expect(session.results?.apps.count == 1 && session.results?.files.count == 1)
        #expect(session.results?.formats.isEmpty == true)
        #expect(settings.askQuickCalculatorEnabled && launcher.fixture.model.quickNumberConversionsEnabled == false)
        view.setQuickCalculator(false)
        view.setQuickNumberConversions(true)
        try await AskQuickSearchSessionTests.wait { !session.isSearching && session.results?.calculation?.isNumericInput == true }
        #expect(session.results?.apps.count == 1 && session.results?.files.count == 1)
        #expect(!launcher.fixture.model.quickCalculatorEnabled)
    }

    @Test func aNumericQueryCanOpenItsApplicationAndCopyAConversion() async throws {
        try await withPasteboard { pasteboard in
            let apps = AskTestAppIndex([AskTestAppIndex.app("2024")])
            let launcher = try await Launcher(text: "2024", apps: apps)
            defer { launcher.close() }
            let results = try #require(launcher.fixture.model.quickSearch.results)
            #expect(results.calculation?.isNumericInput == true && results.highlightedRow == .calculation)
            let conversion = try #require(results.rows.firstIndex(of: .format(0)))
            for _ in 0..<conversion { try await launcher.press(Self.down) }
            try await launcher.press(Self.returnKey)
            #expect(pasteboard.string(forType: .string) == results.formats.first?.value)
            #expect(launcher.dismissed == 1 && launcher.opened.isEmpty)
            #expect(await launcher.fixture.api.sends.isEmpty)

            let second = try await Launcher(text: "2024", apps: apps)
            defer { second.close() }
            let appRow = try #require(second.fixture.model.quickSearch.results?.rows.firstIndex(of: .app(0)))
            for _ in 0..<appRow { try await second.press(Self.down) }
            try await second.press(Self.returnKey)
            #expect(second.opened == [URL(fileURLWithPath: "/Applications/2024.app")])
            #expect(second.dismissed == 1)
            #expect(await second.fixture.api.sends.isEmpty)
        }
    }

    @Test func aNumericQueryCanOpenItsFileWithoutCopyingTheNumber() async throws {
        try await withPasteboard { pasteboard in
            let host = FileHost(AskTestFileIndex([("/Users/test/Documents/2024.pdf", .file, 0)]))
            let launcher = try await Launcher(text: "2024") { host.install(in: $0) }
            defer { launcher.close() }
            let result = try #require(launcher.fixture.model.quickSearch.results)
            #expect(result.calculation?.isNumericInput == true)
            #expect(result.highlightedRow == .calculation)
            let fileRow = try #require(result.rows.firstIndex(of: .file(0)))
            for _ in 0..<fileRow { try await launcher.press(Self.down) }
            try await launcher.press(Self.returnKey)
            #expect(host.urls == [URL(fileURLWithPath: "/Users/test/Documents/2024.pdf")])
            #expect(host.index.opened == ["/Users/test/Documents/2024.pdf"])
            #expect(pasteboard.string(forType: .string) == nil)
            #expect(launcher.dismissed == 1)
        }
    }

    @Test func applicationsRemainExecutableWhileFilesAreStillSearching() async throws {
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let files = AskControlledSearchIndex()
        files.fileSearch = { _ in _ = gate.wait(timeout: .now() + 5); return [AskQuickSearchSessionTests.file] }
        let launcher = try await Launcher(text: "note", apps: AskTestAppIndex([AskTestAppIndex.app("Notes")]),
                                           waitForSearch: false) { $0.fileIndex = files }
        defer { launcher.close() }
        try await AskQuickSearchSessionTests.wait { launcher.fixture.model.quickSearch.results?.apps.count == 1 }
        #expect(launcher.fixture.model.quickSearch.isSearching)
        let results = try #require(launcher.fixture.model.quickSearch.results)
        let appRow = try #require(results.rows.firstIndex(of: .app(0)))
        for _ in 0..<appRow { try await launcher.press(Self.down) }
        try await launcher.press(Self.returnKey)
        #expect(launcher.opened == [URL(fileURLWithPath: "/Applications/Notes.app")])
        #expect(launcher.dismissed == 1)
        #expect(await launcher.fixture.api.sends.isEmpty)
    }

    @Test func indexPublicationRefreshesTheVisibleQueryWithoutTyping() async throws {
        let apps = AskControlledSearchIndex()
        let launcher = try await Launcher(text: "note") { model in
            model.appIndex = apps
            model.modelLibrary.settings.askQuickFileSearchEnabled = false
        }
        defer { launcher.close() }
        #expect(launcher.fixture.model.quickSearch.results?.apps.isEmpty == true)
        #expect(launcher.fixture.model.quickSearch.results?.features.isEmpty == false)
        apps.appSearch = { _ in [AskQuickSearchSessionTests.app] }
        NotificationCenter.default.post(name: AskAppIndex.didChange, object: apps)
        try await AskQuickSearchSessionTests.wait { launcher.fixture.model.quickSearch.results?.apps.count == 1 }
        #expect(launcher.editor.string == "note")
        launcher.fixture.model.modelLibrary.settings.askQuickAppSearchEnabled = false
        try await AskQuickSearchSessionTests.wait { launcher.fixture.model.quickSearch.results?.apps.isEmpty == true }
        #expect(launcher.fixture.model.quickSearch.results?.features.isEmpty == false)
    }

    @Test func fileIndexPublicationRefreshesNormalAndKeywordModes() async throws {
        let files = AskControlledSearchIndex()
        let launcher = try await Launcher(text: "note") { $0.fileIndex = files }
        defer { launcher.close() }
        files.fileSearch = { _ in [AskQuickSearchSessionTests.file] }
        NotificationCenter.default.post(name: AskFileIndex.didChange, object: files)
        try await AskQuickSearchSessionTests.wait { launcher.fixture.model.quickSearch.results?.files.count == 1 }
        launcher.fixture.model.launcherDraft.text = "f note"
        try await AskQuickSearchSessionTests.wait { launcher.fixture.model.plugins.output?.items.first?.id == "/notes.txt" }
        files.fileSearch = { _ in [] }
        NotificationCenter.default.post(name: AskFileIndex.didChange, object: files)
        try await AskQuickSearchSessionTests.wait {
            launcher.fixture.model.plugins.output?.items.first?.id.hasPrefix("notice.") == true
        }
        #expect(!files.searchedOnMain)
    }

    @Test func hidingSearchCancelsAndReopeningRestartsTheSameText() async throws {
        let apps = AskTestAppIndex([AskTestAppIndex.app("Notes")])
        let launcher = try await Launcher(text: "note", apps: apps)
        defer { launcher.close() }
        let session = launcher.fixture.model.quickSearch
        #expect(session.results?.apps.count == 1)
        session.setVisible(false)
        #expect(session.results == nil && !session.isSearching)
        NotificationCenter.default.post(name: AskAppIndex.didChange, object: apps)
        try await Task.sleep(for: .milliseconds(20))
        #expect(session.results == nil)
        session.setVisible(true)
        try await AskQuickSearchSessionTests.wait { session.results?.apps.count == 1 }
    }
}
