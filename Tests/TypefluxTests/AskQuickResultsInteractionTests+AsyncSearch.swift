import AppKit
import Testing
@testable import Typeflux

extension AskQuickResultsInteractionTests {
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
        #expect(launcher.fixture.model.quickSearch.results == nil)
        apps.appSearch = { _ in [AskQuickSearchSessionTests.app] }
        NotificationCenter.default.post(name: AskAppIndex.didChange, object: apps)
        try await AskQuickSearchSessionTests.wait { launcher.fixture.model.quickSearch.results?.apps.count == 1 }
        #expect(launcher.editor.string == "note")
        launcher.fixture.model.modelLibrary.settings.askQuickAppSearchEnabled = false
        try await AskQuickSearchSessionTests.wait { launcher.fixture.model.quickSearch.results == nil }
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
