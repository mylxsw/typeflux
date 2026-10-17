import AppKit
import Foundation
import Testing
@testable import Typeflux

/// This Mac's configuration (`sys`) in the real launcher, driven by key presses.
extension AskQuickResultsInteractionTests {
    private func typeSystemInfo(_ text: String, into launcher: Launcher) async throws {
        for char in text {
            launcher.editor.insertText(String(char), replacementRange: NSRange(location: NSNotFound, length: 0))
            try await Task.sleep(for: .milliseconds(30))
        }
    }

    @Test func `sys shows the configuration and its keys work`() async throws {
        try await withPasteboard { pasteboard in
            let store = SystemInfoStore(reader: FakeSystemInfoReader(), now: { SystemInfoFixtures.now })
            store.refresh()
            await store.settle()
            let launcher = try await Launcher(text: "", prepare: { $0.systemInfoStore = store })
            defer { launcher.close() }
            let model = launcher.fixture.model
            try await typeSystemInfo("sys", into: launcher)
            try await launcher.press(Self.returnKey)
            #expect(model.showsSystemInfo && model.systemInfo.section == .overview)
            #expect(!AskComposer(model: model, launcher: true).launcherPrimaryAction.enabled, "nothing to copy yet")
            #expect(!AskComposer(model: model, launcher: true).launcherCanOpenFeatureWindow)
            #expect(launcher.heights.contains { $0 >= SystemInfoLauncherView.height })

            // ⌘4 opens storage, ⇥ the next section; arrows choose a row and Return copies it.
            try await launcher.press(21, .command)
            #expect(model.systemInfo.section == .storage)
            try await launcher.press(Self.tab)
            #expect(model.systemInfo.section == .display)
            try await launcher.press(Self.down)
            #expect(model.systemInfo.selection == "display.0.resolution")
            try await launcher.press(Self.returnKey)
            #expect(pasteboard.string(forType: .string) == "3024 × 1964")
            try await launcher.press(8, [.command, .shift])
            #expect(pasteboard.string(forType: .string)?.hasPrefix("## MacBook Pro") == true)
            #expect(pasteboard.string(forType: .string)?.contains("C02XK4M1Q6L4") == false)

            // Typing searches; Return copies the first match. The filter is no result to move into a window.
            try await typeSystemInfo("router", into: launcher)
            #expect(AskComposer(model: model, launcher: true).launcherPrimaryAction.enabled)
            #expect(!AskComposer(model: model, launcher: true).launcherCanOpenFeatureWindow)
            try await launcher.press(Self.returnKey)
            #expect(pasteboard.string(forType: .string) == "192.168.1.1")

            // Esc steps back: the chosen row, the search, the section, then out of the keyword.
            try await launcher.press(Self.escape)
            #expect(model.systemInfo.selection == nil && model.launcherDraft.text == "router")
            try await launcher.press(Self.escape)
            #expect(model.launcherDraft.text.isEmpty && model.systemInfo.section == .display)
            try await launcher.press(Self.escape)
            #expect(model.systemInfo.section == .overview && model.showsSystemInfo)
            try await launcher.press(Self.escape)
            #expect(!model.showsSystemInfo)
            #expect(launcher.dismissed == 0)
        }
    }
}
