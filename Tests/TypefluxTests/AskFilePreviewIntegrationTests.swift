import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@Suite("Launcher preview integration", .exclusiveUIState)
@MainActor
struct AskFilePreviewIntegrationTests {
    private struct PreviewInputSource: AskLauncherInputSourceSelecting { func selectEnglish() {} }

    @Test func `typing preserves the preview while results are pending and after the same file settles`() async throws {
        let oldStore = KeychainTokenStore.useInMemoryStoreForTesting
        KeychainTokenStore.useInMemoryStoreForTesting = true
        _ = AuthState.shared
        KeychainTokenStore.useInMemoryStoreForTesting = oldStore
        let name = "preview-typing-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = SettingsStore(defaults: defaults)
        let fixture = try AskTestFixture(modelLibrary: AskModelLibrary(
            defaults: defaults,
            automaticallyLoadsCatalog: false
        ))
        let loader = PreviewTestLoader()
        let controller = AskConversationWindowController(settings: settings, model: fixture.model,
                                                         launcherInputSource: PreviewInputSource(),
                                                         filePreviewLoader: loader)
        defer { controller.dismissLauncher(); fixture.model.resetSession() }
        controller.showLauncher()
        let window = try #require(controller.launcherWindow)
        let screen = try #require(window.screen).visibleFrame
        window.setFrameOrigin(CGPoint(x: screen.minX + 30, y: window.frame.minY))

        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let index = AskControlledSearchIndex()
        let first = previewHit("xcode.swift")
        var changed = first
        changed.score = 42; changed.match = 10; changed.highlights = [0 ..< 4]
        let updated = changed
        index.fileSearch = { [weak index] _ in
            guard index?.calls.last == "xcod" else { return [first] }
            _ = gate.wait(timeout: .now() + 5)
            return [updated]
        }
        fixture.model.fileIndex = index
        fixture.model.launcherDraft.text = "xco"
        try await AskQuickSearchSessionTests.wait { !fixture.model.quickSearch.isSearching
            && fixture.model.quickSearch.results?.files.first?.path == first.path }
        fixture.model.quickSearch.results?
            .highlight(fixture.model.quickSearch.results?.rows.firstIndex(of: .file(0)) ?? 0)
        try await AskQuickSearchSessionTests.wait { loader.requests.count == 1 }
        loader.completions[0](.init(kind: .text, text: "let value = 1"))
        let panel = try #require(controller.filePreview.panel)
        #expect(panel.isVisible)
        let contentID = controller.filePreview.state.contentID
        let cancellations = loader.cancelled, visibility = loader.visible

        fixture.model.launcherDraft.text = "xcod"
        try await AskQuickSearchSessionTests.wait { fixture.model.quickSearch.pendingResults != nil
            && index.calls.contains("xcod") }
        // Hold the worker long enough for SwiftUI to process the pending-results change.
        try await Task.sleep(for: .milliseconds(200))
        #expect(controller.filePreview.isVisible && panel.isVisible)
        #expect(loader.visible == visibility, "Pending results must not dismiss even briefly")
        #expect(loader.cancelled == cancellations)
        #expect(loader.requests.count == 1)
        #expect(controller.filePreview.state.contentID == contentID)

        gate.signal()
        try await AskQuickSearchSessionTests.wait { !fixture.model.quickSearch.isSearching
            && fixture.model.quickSearch.pendingResults == nil
            && controller.filePreview.state.hit == updated }
        try await Task.sleep(for: .milliseconds(300))
        #expect(controller.filePreview.panel === panel && panel.isVisible)
        #expect(controller.filePreview.isVisible)
        #expect(loader.visible == visibility && loader.cancelled == cancellations)
        #expect(loader.requests.count == 1)
        #expect(controller.filePreview.state.contentID == contentID)
        #expect(controller.filePreview.state.content?.text == "let value = 1")

        fixture.model.launcherDraft.text = ""
        try await AskQuickSearchSessionTests.wait { !controller.filePreview.isVisible }
        #expect(!panel.isVisible, "Clearing the query still dismisses immediately")
    }

    @Test func `highlight changes flow through composer and close with launcher`() async throws {
        let oldStore = KeychainTokenStore.useInMemoryStoreForTesting
        KeychainTokenStore.useInMemoryStoreForTesting = true
        _ = AuthState.shared
        KeychainTokenStore.useInMemoryStoreForTesting = oldStore
        let name = "preview-integration-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = SettingsStore(defaults: defaults)
        let fixture = try AskTestFixture(modelLibrary: AskModelLibrary(
            defaults: defaults,
            automaticallyLoadsCatalog: false
        ))
        let loader = PreviewTestLoader()
        let controller = AskConversationWindowController(settings: settings, model: fixture.model,
                                                         launcherInputSource: PreviewInputSource(),
                                                         filePreviewLoader: loader)
        defer { controller.dismissLauncher(); fixture.model.resetSession() }
        controller.showLauncher()
        let window = try #require(controller.launcherWindow)
        let screen = try #require(window.screen).visibleFrame
        window.setFrameOrigin(CGPoint(x: screen.minX + 30, y: window.frame.minY))
        fixture.model.fileIndex = AskTestFileIndex([
            ("/Users/test/preview-a.txt", .file, 0), ("/Users/test/preview-b.png", .file, 1),
            ("/Users/test/preview-folder", .folder, 2)
        ])
        fixture.model.launcherDraft.text = "preview"
        try await AskQuickSearchSessionTests
            .wait { !fixture.model.quickSearch.isSearching && fixture.model.quickSearch.results?.files.count == 3 }
        fixture.model.quickSearch.results?
            .highlight(fixture.model.quickSearch.results?.rows.firstIndex(of: .file(0)) ?? 0)
        try await AskQuickSearchSessionTests.wait { !loader.requests.isEmpty }
        loader.completions.last?(.init(kind: .text, text: "Hello"))
        #expect(controller.filePreview.isVisible)
        #expect(controller.filePreview.panel?.canBecomeKey == false)
        fixture.model.quickSearch.results?
            .highlight(fixture.model.quickSearch.results?.rows.firstIndex(of: .file(1)) ?? 0)
        try await AskQuickSearchSessionTests.wait { loader.requests.count >= 2 }
        #expect(controller.filePreview.state.hit?.name == "preview-b.png")
        loader.completions.last?(.init(kind: .image))
        fixture.model.quickSearch.results?
            .highlight(fixture.model.quickSearch.results?.rows.firstIndex(of: .file(2)) ?? 0)
        try await AskQuickSearchSessionTests.wait { !controller.filePreview.isVisible }
        #expect(!controller.filePreview.isVisible)
        fixture.model.quickSearch.results?
            .highlight(fixture.model.quickSearch.results?.rows.firstIndex(of: .file(0)) ?? 0)
        try await AskQuickSearchSessionTests.wait { loader.requests.count >= 3 }
        loader.completions.last?(.init(kind: .text))
        controller.dismissLauncher()
        #expect(!controller.filePreview.isVisible)
        #expect(controller.filePreview.panel?.isVisible == false)
        settings.askFilePreviewEnabled = false
        controller.showLauncher()
        fixture.model.launcherDraft.text = "preview-a"
        try await Task.sleep(for: .milliseconds(300))
        #expect(!controller.filePreview.isVisible)
    }
}
