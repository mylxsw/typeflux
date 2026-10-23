import AppKit
import SwiftUI
import Testing
@testable import Typeflux

/// GUL-464: what a new conversation fixes before its first message sits on the new
/// page (the chat/work switch, the hourglass and the bar under the composer); the
/// composer keeps only what can change mid-conversation.
@Suite("Ask new conversation page", .serialized, .exclusiveUIState)
@MainActor
struct AskNewConversationBarTests {
    // MARK: - Pure rules

    @Test func storageFollowsTemporarySignInAndChoice() {
        #expect(AskNewConversationBar.storage(temporary: true, signedIn: true, local: true) == .temporary)
        #expect(AskNewConversationBar.storage(temporary: true, signedIn: false, local: false) == .temporary)
        #expect(AskNewConversationBar.storage(temporary: false, signedIn: false, local: false) == .localOnly)
        #expect(AskNewConversationBar.storage(temporary: false, signedIn: true, local: true) == .choice(.local))
        #expect(AskNewConversationBar.storage(temporary: false, signedIn: true, local: false) == .choice(.cloud))
    }

    @Test func memoryIsOfferedOnlyWhenThereIsMemoryToKeep() {
        #expect(AskNewConversationBar.offersMemory(temporary: false, memory: AskMemory(global: "short")))
        #expect(!AskNewConversationBar.offersMemory(temporary: true, memory: AskMemory(global: "short")))
        #expect(!AskNewConversationBar.offersMemory(temporary: false, memory: AskMemory()))
        #expect(!AskNewConversationBar.offersMemory(temporary: false, memory: nil))
    }

    @Test func headlineAndComposerAreGroupedAboveTheMiddle() throws {
        let layout = AskWorkspaceLayout(size: CGSize(width: 1100, height: 800), sidebarCollapsed: false,
                                        showsUsage: false)
        let placement = try #require(layout.newPagePlacement(heading: 150, composer: 160))
        let available = 800 - AskMetrics.titleBarRowHeight
        let group = 150 + AskWorkspaceLayout.newPageGap + 160
        #expect(placement.headingTop == ((available - group) * AskWorkspaceLayout.newPageBias).rounded())
        let composerTop = AskMetrics.titleBarRowHeight + placement.headingTop + 150 + AskWorkspaceLayout.newPageGap
        #expect(placement.composerLift == 800 - 160 - composerTop)
        #expect(placement.composerLift > 0)
    }

    @Test func shortOrUnmeasuredPagesKeepTheComposerAtTheBottom() {
        let tall = AskWorkspaceLayout(size: CGSize(width: 1100, height: 800), sidebarCollapsed: false, showsUsage: false)
        #expect(tall.newPagePlacement(heading: 0, composer: 160) == nil)
        #expect(tall.newPagePlacement(heading: 150, composer: 0) == nil)
        #expect(tall.newPagePlacement(heading: 500, composer: 300) == nil, "The group does not fit")
        let short = AskWorkspaceLayout(size: CGSize(width: 1100, height: 480), sidebarCollapsed: false, showsUsage: false)
        #expect(short.newPagePlacement(heading: 100, composer: 120) == nil)
    }

    @Test func activeHeaderIconTakesItsOwnTint() {
        #expect(AskHeaderIconButton.ink(active: true, hovering: false, activeTint: .orange) == .orange)
        #expect(AskHeaderIconButton.ink(active: true, hovering: false) == AskTheme.accent)
        #expect(AskHeaderIconButton.ink(active: false, hovering: true, activeTint: .orange) == StudioTheme.textPrimary)
    }

    // MARK: - Rendering

    private func host<V: View>(_ view: V, size: NSSize = NSSize(width: 760, height: 160)) -> NSWindow {
        _ = NSApplication.shared
        NSApp.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        window.orderFront(nil)
        return window
    }

    private func settle(_ window: NSWindow) async throws {
        for _ in 0 ..< 15 {
            window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func find(_ identifier: String, in window: NSWindow) -> NSObject? {
        var seen = Set<ObjectIdentifier>()
        func walk(_ node: Any) -> NSObject? {
            guard let object = node as? NSObject, seen.insert(ObjectIdentifier(object)).inserted else { return nil }
            if object.responds(to: NSSelectorFromString("accessibilityIdentifier")),
               object.value(forKey: "accessibilityIdentifier") as? String == identifier { return object }
            guard object.responds(to: NSSelectorFromString("accessibilityChildren")) else { return nil }
            for child in object.value(forKey: "accessibilityChildren") as? [Any] ?? [] {
                if let found = walk(child) { return found }
            }
            return nil
        }
        return walk(window)
    }

    private func press(_ identifier: String, in window: NSWindow) throws {
        let element = try #require(find(identifier, in: window), "Missing \(identifier)")
        _ = element.perform(NSSelectorFromString("accessibilityPerformPress"))
    }

    @Test func chatBarOffersMemoryAndStorageChoice() async throws {
        let fixture = try AskTestFixture()
        defer { fixture.model.resetSession(); AskGlassMenuPresenter.shared.hide() }
        fixture.model.draft.memory = AskMemory(global: "short")
        let window = host(AskNewConversationBar(model: fixture.model))
        defer { window.close() }
        try await settle(window)
        #expect(find("ask.newConversation.folders", in: window) == nil, "A chat works in no folder")
        try press("ask.newConversation.memory", in: window)
        try await fixture.wait { fixture.model.memorySwitchedOff(launcher: false) }

        try press("ask.newConversation.storage", in: window)
        try await fixture.wait { AskGlassMenuPresenter.shared.panel?.isVisible == true }
        let panel = try #require(AskGlassMenuPresenter.shared.panel)
        try await fixture.wait { self.find("ask.newConversation.storage.local", in: panel) != nil }
        try press("ask.newConversation.storage.local", in: panel)
        try await fixture.wait { fixture.model.storesLocally(launcher: false) }
    }

    @Test func workBarNamesFoldersAndOpensTheirList() async throws {
        let fixture = try AskTestFixture()
        defer { fixture.model.resetSession(); AskGlassMenuPresenter.shared.hide() }
        fixture.model.setConversationKind(.work, launcher: false)
        let window = host(AskNewConversationBar(model: fixture.model))
        defer { window.close() }
        try await settle(window)
        try press("ask.newConversation.folders", in: window)
        try await fixture.wait { AskGlassMenuPresenter.shared.panel?.isVisible == true }
        let panel = try #require(AskGlassMenuPresenter.shared.panel)
        try await fixture.wait { self.find("ask.env.addFolder", in: panel) != nil }
        #expect(find("ask.env.mode.yolo", in: panel) == nil, "Permission stays in the composer")
    }

    @Test func temporaryBarSaysNotSavedAndCanTurnItOff() async throws {
        let fixture = try AskTestFixture()
        defer { fixture.model.resetSession() }
        fixture.model.draft.memory = AskMemory(global: "short")
        fixture.model.setTemporary(true, launcher: false)
        let window = host(AskNewConversationBar(model: fixture.model))
        defer { window.close() }
        try await settle(window)
        #expect(find("ask.newConversation.memory", in: window) == nil, "A temporary chat uses no memory")
        try press("ask.newConversation.storage", in: window)
        try await fixture.wait { !fixture.model.isTemporaryComposer(launcher: false) }
    }

    @Test func signedOutStorageAsksToSignIn() async throws {
        let fixture = try AskTestFixture(authenticated: false)
        defer { fixture.model.resetSession() }
        var signIns = 0
        fixture.model.onSignIn = { signIns += 1 }
        let window = host(AskNewConversationBar(model: fixture.model))
        defer { window.close() }
        try await settle(window)
        try press("ask.newConversation.storage", in: window)
        #expect(signIns == 1)
    }

    @Test func workspaceNewPageHasTheHourglassAndBarButNotOnceStarted() async throws {
        let fixture = try AskTestFixture()
        defer { fixture.model.resetSession() }
        let window = host(AskConversationView(model: fixture.model), size: NSSize(width: 1100, height: 760))
        defer { window.close() }
        try await settle(window)
        #expect(find("ask.newConversation.bar", in: window) != nil)
        try press("ask.workspace.temporaryToggle", in: window)
        try await fixture.wait { fixture.model.isTemporaryComposer(launcher: false) }
        try await settle(window)
        try press("ask.workspace.temporaryToggle", in: window)
        try await fixture.wait { !fixture.model.isTemporaryComposer(launcher: false) }

        fixture.model.draft.text = "Hello"
        fixture.model.submitDraft()
        try await fixture.wait { fixture.model.selectedId != nil }
        try await settle(window)
        #expect(find("ask.newConversation.bar", in: window) == nil)
        #expect(find("ask.workspace.temporaryToggle", in: window) == nil)

        try press("ask.workspace.new", in: window)
        try await fixture.wait { fixture.model.selectedId == nil }
        #expect(!fixture.model.isTemporaryComposer(launcher: false), "The compose button starts an ordinary one")
    }
}
