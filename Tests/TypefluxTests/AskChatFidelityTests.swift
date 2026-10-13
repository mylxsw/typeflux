import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@Suite("Ask chat fidelity", .serialized, .exclusiveUIState)
@MainActor
struct AskChatFidelityTests {
    private typealias UI = SettingsBehaviorTestSupport

    @Test(arguments: InterfaceStyle.allCases)
    func accountRowKeepsActionsWithoutPromotion(style: InterfaceStyle) async throws {
        try await UI.withFixture { settings in
            var logins = 0
            var openedSettings = 0
            let footer = SidebarAccountFooter(auth: AuthState.shared, compact: false, defaults: settings.defaults,
                showsPromotion: false, onSignIn: { logins += 1 }, onOpenAccount: {},
                onOpenSettings: { openedSettings += 1 })
                .environment(\.interfaceStyle, style)
            try await UI.withWindow(footer, width: 248, height: 60) { _, host in
                try await UI.wait { UI.contains(L("ask.cloudPromo.signIn"), in: host) }
                #expect(!UI.contains("Typeflux Cloud", in: host))
                #expect(!UI.contains(L("ask.cloudPromo.dismiss"), in: host))
                try UI.button(L("ask.cloudPromo.signIn"), in: host).press()
                try UI.button(L("sidebar.settingsAccessibility"), in: host).press()
                #expect(logins == 1 && openedSettings == 1)
                #expect(settings.defaults.double(forKey: AskCloudPromo.dismissedKey) == 0)
            }
        }
    }

    @Test(arguments: InterfaceStyle.allCases)
    func paletteKeyboardExecutesActionsAndMatchingConversations(style: InterfaceStyle) async throws {
        var actions: [AskPaletteAction] = []
        var opened: [String] = []
        var closed = 0
        let palette = AskSearchPaletteView(conversations: [
            .init(id: "swift", title: "Swift actors", updatedAt: .now)
        ], available: [.newConversation, .toggleSidebar], onAction: { actions.append($0) },
            onOpen: { opened.append($0) }, onClose: { closed += 1 })
            .environment(\.interfaceStyle, style)
        try await UI.withWindow(palette, width: 440, height: 320) { window, host in
            try await UI.wait { UI.contains("Swift actors", in: host) }
            let field = try #require(UI.nativeViews(in: host).compactMap { $0 as? NSTextField }.first {
                $0.placeholderString == L("ask.search.placeholder")
            })
            #expect(window.makeFirstResponder(field))
            try TypefluxNavigationTestSupport.sendKey(125, to: window)
            try TypefluxNavigationTestSupport.sendKey(36, to: window)
            #expect(actions == [.toggleSidebar])
            #expect(window.makeFirstResponder(field))
            let editor = try #require(field.currentEditor() as? NSTextView)
            editor.insertText("swift", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
            try await UI.wait { !UI.contains(L("ask.new"), in: host) }
            try TypefluxNavigationTestSupport.sendKey(36, to: window)
            #expect(opened == ["swift"])
            #expect(UI.contains("↑↓ " + L("clipboard.hint.navigate"), in: host))
            #expect(UI.contains("↵ " + L("ask.search.execute"), in: host))
            #expect(window.makeFirstResponder(field))
            let searchEditor = try #require(field.currentEditor() as? NSTextView)
            searchEditor.insertText("no matching results",
                                    replacementRange: NSRange(location: 0, length: searchEditor.string.utf16.count))
            try await UI.wait { UI.contains(L("ask.history.searchEmpty"), in: host) }
            try TypefluxNavigationTestSupport.sendKey(36, to: window)
            #expect(actions == [.toggleSidebar] && opened == ["swift"])
            try UI.button(L("clipboard.hint.close"), in: host).press()
            #expect(closed == 1)
        }
    }

    @Test func emptyPaletteKeepsItsCloseActionAndKeyboardHints() async throws {
        var closed = 0
        let palette = AskSearchPaletteView(conversations: [], available: [], onAction: { _ in },
                                          onOpen: { _ in }, onClose: { closed += 1 })
        try await UI.withWindow(palette, width: 440, height: 320) { _, host in
            try await UI.wait { UI.contains(L("ask.history.empty"), in: host) }
            try UI.button(L("clipboard.hint.close"), in: host).press()
            #expect(closed == 1)
        }
    }

    @Test func modelReasonsCoverMissingLockedAndImageIncompatibleSelections() throws {
        let suite = "chat-model-reasons-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let library = AskModelLibrary(defaults: defaults, automaticallyLoadsCatalog: false)
        try library.addModels([
            .init(id: "text", name: "Text", reference: "cloud:text", vision: false, scenarios: ["ask"]),
            .init(id: "vision", name: "Vision", reference: "cloud:vision", vision: true, scenarios: ["ask"])
        ], providerID: "typefluxCloud")
        #expect(library.selectionExplanation(for: "missing:model", hasImage: false, loggedIn: true)
            == L("ask.models.unavailable"))
        #expect(library.selectionExplanation(for: "cloud:text", hasImage: true, loggedIn: true)
            == L("models.noVision"))
        #expect(library.selectionExplanation(for: "cloud:vision", hasImage: true, loggedIn: true) == nil)
        #expect(library.selectionExplanation(for: "cloud:vision", hasImage: false, loggedIn: false) != nil)
    }

    @Test(arguments: InterfaceStyle.allCases)
    func composerShowsModelAndScreenshotExplanations(style: InterfaceStyle) async throws {
        let fixture = try AskTestFixture()
        defer { fixture.model.resetSession() }
        fixture.model.draft.modelRef = "missing:model"
        let composer = AskComposer(model: fixture.model, availableWidth: 400, availableHeight: 220, launcher: false)
            .environment(\.interfaceStyle, style)
        try await UI.withWindow(composer, width: 400, height: 220) { _, host in
            try await UI.wait { UI.contains(L("ask.models.unavailable"), in: host) }
            fixture.model.draft.modelRef = nil
            fixture.model.draft.includeScreenshot = true
            fixture.model.draft.screenshot = nil
            fixture.model.captureWarning = L("ask.capture.permission")
            try await UI.wait { UI.contains(L("ask.capture.permission"), in: host) }
            #expect(!UI.nativeViews(in: host).compactMap { $0 as? AskComposerTextView.Editor }.isEmpty)
        }
    }
}
