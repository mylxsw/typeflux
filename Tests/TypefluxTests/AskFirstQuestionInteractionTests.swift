import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@Suite("Ask first question controls", .serialized)
@MainActor
struct AskFirstQuestionInteractionTests {
    @Test(arguments: [true, false])
    func modelAndSignInButtonsDispatchTheirRealRoutes(launcher: Bool) async throws {
        let fixture = try AskTestFixture(localOnly: true)
        defer { fixture.model.resetSession() }
        var sections: [StudioSection] = []
        var signsIn = 0
        fixture.model.onOpenSettings = { sections.append($0) }
        fixture.model.onSignIn = { signsIn += 1 }
        if launcher { fixture.model.launcherDraft = AskDraft(text: "Question", includeScreenshot: false); fixture.model.submitLauncher() }
        else { fixture.model.draft = AskDraft(text: "Question", includeScreenshot: false); fixture.model.submitDraft() }
        let host = FirstQuestionControlHost(AskComposer(model: fixture.model, launcher: launcher))
        defer { host.close() }
        try await host.settle()
        #expect(!host.labels.contains(L("ask.retry")))
        try host.click("ask.submission.models")
        try host.click("ask.submission.signIn")
        #expect(sections == [.models] && signsIn == 1)
        #expect(fixture.model.selectedId == nil)
        #expect((launcher ? fixture.model.launcherDraft : fixture.model.draft).text == "Question")
    }

    @Test func usageErrorHasAClickableRetryAndEmptyDraftHasNoRequestOrScopePicker() async throws {
        let fixture = try AskTestFixture()
        defer { fixture.model.resetSession() }
        let empty = FirstQuestionControlHost(AskUsagePanel(model: fixture.model, runId: .constant(nil), close: {}))
        try await empty.settle()
        #expect(empty.labels.contains(L("ask.usage.empty")))
        #expect(!empty.labels.contains(L("ask.usage.conversation")))
        #expect(await fixture.api.usageRequests == 0)
        empty.close()
        let value = AskConversation(id: "c", title: "Used", revision: 1, updatedAt: Date(), messages: [],
                                     run: .init(id: "run", deviceId: "device", status: "completed", steps: 1,
                                                updatedAt: Date(), tools: [], pending: []))
        await fixture.api.seed(value)
        await fixture.model.select(value.id)
        await fixture.api.setFailUsage(true)
        let error = FirstQuestionControlHost(AskUsagePanel(model: fixture.model, runId: .constant(nil), close: {}))
        defer { error.close() }
        try await error.settle()
        #expect(error.identifiers.contains("ask.usage.retry"))
        let requests = await fixture.api.usageRequests
        await fixture.api.setFailUsage(false)
        try error.click("ask.usage.retry")
        try await error.settle()
        #expect(await fixture.api.usageRequests == requests + 1)
        #expect(!error.identifiers.contains("ask.usage.retry"))
    }

    @Test(arguments: [true, false])
    func deletingOrSwitchingConversationClosesUsage(delete: Bool) async throws {
        let fixture = try AskTestFixture()
        defer { fixture.model.resetSession() }
        await fixture.api.seed(.init(id: "c", title: "Empty", revision: 1, updatedAt: Date(), messages: []))
        await fixture.model.select("c")
        let auth = AuthState(loadStoredToken: { nil }, loadStoredRefreshToken: { nil }, loadStoredUserProfile: { nil })
        let host = FirstQuestionControlHost(AskConversationView(model: fixture.model, showsUsage: true, auth: auth),
                                            size: NSSize(width: 1180, height: 760))
        defer { host.close() }
        try await host.settle()
        #expect(host.labels.contains(L("ask.usage.empty")))
        if delete { await fixture.model.delete("c") } else { fixture.model.newConversation() }
        try await host.settle()
        #expect(fixture.model.selectedId == nil)
        #expect(!host.labels.contains(L("ask.usage.empty")))
        #expect(!host.identifiers.contains("ask.workspace.drawer.close"))
    }
}

/// Native events are delivered only inside this test process; no system input or permissions.
@MainActor
private final class FirstQuestionControlHost {
    let window: NSWindow
    private let accessibility: AskWorkspaceTestAccessibility
    private let wasEnhancedAccessibility: Bool
    private let suite = "ask-first-controls-" + UUID().uuidString
    private let defaults: UserDefaults

    init<V: View>(_ view: V, size: NSSize = NSSize(width: 640, height: 520)) {
        _ = NSApplication.shared
        wasEnhancedAccessibility = NSApp.accessibilityAttributeValue(.init(rawValue: "AXEnhancedUserInterface")) as? Bool ?? false
        accessibility = AskWorkspaceTestAccessibility()
        defaults = UserDefaults(suiteName: suite)!
        window = AskTestVoiceWindow(contentRect: NSRect(origin: NSPoint(x: 100, y: 100), size: size),
                                    styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view.defaultAppStorage(defaults))
        window.orderFront(nil)
    }

    func settle() async throws {
        try await Task.sleep(for: .milliseconds(300))
        window.contentView?.layoutSubtreeIfNeeded()
    }

    var identifiers: Set<String> { values("accessibilityIdentifier") }
    var labels: Set<String> { values("accessibilityLabel") }

    private func values(_ key: String) -> Set<String> {
        var seen = Set<ObjectIdentifier>(), found = Set<String>()
        func visit(_ object: NSObject) {
            guard seen.insert(ObjectIdentifier(object)).inserted else { return }
            if object.responds(to: NSSelectorFromString(key)), let value = object.value(forKey: key) as? String {
                found.insert(value)
            }
            if object.responds(to: NSSelectorFromString("accessibilityChildren")) {
                (object.value(forKey: "accessibilityChildren") as? [NSObject] ?? []).forEach(visit)
            }
        }
        visit(window)
        if let view = window.contentView { visit(view) }
        return found
    }

    func click(_ identifier: String) throws {
        let point = try AskWorkspaceTestAccessibility.center(identifier: identifier, in: window)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                                        timestamp: ProcessInfo.processInfo.systemUptime,
                                                        windowNumber: window.windowNumber, context: nil,
                                                        eventNumber: 0, clickCount: 1, pressure: 1))
            NSApp.sendEvent(event)
        }
    }

    func close() {
        window.orderOut(nil); window.close()
        defaults.removePersistentDomain(forName: suite)
        if !wasEnhancedAccessibility { accessibility.restore() }
    }
}
