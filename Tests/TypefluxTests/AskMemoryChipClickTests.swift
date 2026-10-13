import AppKit
import SwiftUI
import Testing
@testable import Typeflux

/// Assert accessible memory controls, then drive the same model action used by the composer and launcher.
extension AskComposerInteractionTests {
    @Test func memoryChipTogglesInTheChatWindow() async throws {
        let fixture = try AskTestFixture()
        defer { fixture.model.resetSession() }
        fixture.model.newConversation()
        fixture.model.draft.memory = AskMemory(global: "Prefers short answers.", app: nil)
        let (window, hosting) = try await hostChipView(AskConversationView(model: fixture.model), size: NSSize(width: 1000, height: 640))
        defer { window.close() }
        try assertMemoryChip(in: hosting, label: memoryLabel(fixture.model))
        fixture.model.toggleMemory(launcher: false)
        try await Task.sleep(for: .milliseconds(150))
        #expect(fixture.model.draft.memoryOff == true)
        try assertMemoryChip(in: hosting, label: memoryLabel(fixture.model))
        fixture.model.toggleMemory(launcher: false)
        try await Task.sleep(for: .milliseconds(150))
        #expect(fixture.model.draft.memoryOff == nil)
    }

    @Test func pinnedMemoryTogglesThroughItsModelAction() async throws {
        let fixture = try AskTestFixture()
        defer { fixture.model.resetSession() }
        var value = AskConversation(id: "pinned", title: "Pinned", revision: 1, updatedAt: Date(), messages: [
            .init(id: "q", role: "user", text: "Hi", createdAt: Date())
        ])
        value.memory = AskMemory(global: "Prefers short answers.", app: nil)
        await fixture.api.seed(value)
        await fixture.model.select("pinned")
        let (window, hosting) = try await hostChipView(AskConversationView(model: fixture.model), size: NSSize(width: 1000, height: 640))
        defer { window.close() }
        #expect(!fixture.model.memorySwitchedOff(launcher: false))
        try assertMemoryChip(in: hosting, label: memoryLabel(fixture.model))
        fixture.model.toggleMemory(launcher: false)
        try await Task.sleep(for: .milliseconds(150))
        #expect(fixture.model.draft.memoryOff == true)
        #expect(fixture.model.memorySwitchedOff(launcher: false))
        try assertMemoryChip(in: hosting, label: memoryLabel(fixture.model))
        fixture.model.toggleMemory(launcher: false)
        try await Task.sleep(for: .milliseconds(150))
        #expect(fixture.model.draft.memoryOff == false)
        #expect(!fixture.model.memorySwitchedOff(launcher: false))
    }

    @Test func readOnlyChipExposesItsExplanation() async throws {
        let item = AskContextChips.items(screenshot: .unavailable(reason: "This model does not support images"),
                                        source: nil, sourceBundleID: nil, selection: nil, memory: nil,
                                        memoryPinned: false)[0]
        let (window, hosting) = try await hostChipView(AskIconChip(item: item).padding(24),
                                                     size: NSSize(width: 120, height: 100))
        defer { window.close() }
        let chip = try #require(SettingsBehaviorTestSupport.elements(in: hosting).first { $0.label == item.title })
        #expect(chip.role == NSAccessibility.Role.button.rawValue)
        let hint = chip.value("accessibilityHelp") as? String
            ?? chip.object.accessibilityAttributeValue(.help) as? String ?? ""
        #expect(hint.contains(item.detail ?? ""))
    }

    @Test func memoryChipTogglesInTheLauncher() async throws {
        let fixture = try AskTestFixture()
        defer { fixture.model.resetSession() }
        await fixture.model.prepareLauncher()
        fixture.model.launcherDraft.memory = AskMemory(global: "Prefers short answers.", app: nil)
        fixture.model.launcherDraft.source = nil
        fixture.model.launcherDraft.selection = nil
        let (window, hosting) = try await hostChipView(AskLauncherView(model: fixture.model, onDismiss: {}),
                                               size: NSSize(width: AskMetrics.launcherWidth, height: 120))
        defer { window.close() }
        try assertMemoryChip(in: hosting, label: memoryLabel(fixture.model))
        fixture.model.toggleMemory(launcher: true)
        try await Task.sleep(for: .milliseconds(150))
        #expect(fixture.model.launcherDraft.memoryOff == true)
    }

    private func memoryLabel(_ model: AskConversationModel) -> String {
        model.draft.memory?.chipTitle ?? model.selected?.memory?.chipTitle
            ?? model.launcherDraft.memory?.chipTitle ?? L("ask.memory")
    }

    private func assertMemoryChip(in hosting: NSView, label: String) throws {
        let window = try #require(hosting.window)
        try AskWorkspaceTestAccessibility.assertButton("ask.context.memory.toggle", label: label, in: window)
    }

    private func hostChipView<V: View>(_ view: V, size: NSSize) async throws -> (NSWindow, NSView) {
        TypefluxTestApplicationEnvironment.prepare()
        let window = ChipClickWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless,
                               backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: view)
        window.contentView = hosting
        window.orderFront(nil)
        try await Task.sleep(for: .milliseconds(300))
        hosting.layoutSubtreeIfNeeded()
        return (window, hosting)
    }
}

@MainActor
private final class ChipClickWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}
