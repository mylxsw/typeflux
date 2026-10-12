import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@Suite("Launcher preview integration", .exclusiveUIState)
@MainActor
struct AskFilePreviewIntegrationTests {
    private struct PreviewInputSource: AskLauncherInputSourceSelecting { func selectEnglish() {} }

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
