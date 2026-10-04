import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@Suite("Ask recovery rendering", .serialized)
@MainActor
struct AskRecoveryRenderTests {
    @Test func `recovery cards and inspector render with localized actions`() async throws {
        _ = NSApplication.shared
        let fixture = try AskTestFixture(), value = AskRecoveryFixture.conversation()
        let audit = AskRecoveryFixture.audit(value)
        _ = try await fixture.cache.claimExecution(audit, owner: "owner")
        await fixture.api.seed(value); await fixture.model.select(value.id)
        defer { fixture.model.resetSession() }
        for dark in [false, true] {
            let card = AskRecoveryCard(
                presentation: .init(
                    run: value.run,
                    entries: fixture.model.selectedRecoveryEntries,
                    deviceId: "device",
                    local: true
                ),
                inspect: { fixture.model.inspectingRecovery = true }
            )
            try await render(card.padding(24), name: "unknown-\(dark ? "dark" : "light")", dark: dark)
            card.inspect()
            #expect(fixture.model.inspectingRecovery)
        }
        try await render(AskRecoveryInspector(model: fixture.model), name: "inspect-unknown", dark: false)
        await fixture.model.endRecoveryRun()
        #expect(fixture.model.selected?.run?.status == "cancelled")
        try await render(AskRecoveryInspector(model: fixture.model), name: "inspect-ended", dark: false)
        fixture.model.prepareRecoveryRequest()
        #expect(fixture.model.commandFeedback != nil)
        var saved = fixture.model.selectedRecoveryEntries[0]
        saved.receipt = AskRecoveryFixture.receipt(value)
        fixture.model.recoveryEntries[value.id] = [saved]
        try await render(AskRecoveryInspector(model: fixture.model), name: "inspect-saved", dark: false)
        var finished = value.run; finished?.status = "completed"
        let presentation = AskRecoveryPresentation(run: finished, entries: [saved], deviceId: "device", local: false)
        #expect(presentation.titleKey == "ask.recovery.saved" && presentation.bodyKey == "ask.recovery.savedBody")
        try await render(
            AskRecoveryCard(presentation: presentation, canRetransmit: true, canContinue: true).padding(24),
            name: "saved",
            dark: false
        )
        #expect(AskRecoveryPresentation(run: value.run, entries: [], deviceId: "other", local: false)
            .bodyKey == "ask.recovery.binding")
        #expect(AskRecoveryPresentation(run: value.run, entries: [], deviceId: "device", local: false)
            .bodyKey == "ask.recovery.activeBody")
        #expect(AskRecoveryPresentation(run: finished, entries: [], deviceId: "device", local: false)
            .bodyKey == "ask.recovery.historyBody")
        #expect(AskRecoveryPresentation(run: nil, entries: [], deviceId: "device", local: false)
            .titleKey == "ask.recovery.history")
        fixture.model.recoveryEntries[value.id] = []
        try await render(AskRecoveryInspector(model: fixture.model), name: "inspect-remote", dark: false)
    }

    private func render(_ view: some View, name: String, dark: Bool) async throws {
        let hosting = NSHostingView(rootView: view.frame(width: 650, height: 480)
            .background(dark ? Color(nsColor: .windowBackgroundColor) : Color.white)
            .environment(\.colorScheme, dark ? .dark : .light))
        hosting.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        hosting.frame = CGRect(x: 0, y: 0, width: 650, height: 480)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = hosting
        window.appearance = hosting.appearance
        window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(150))
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        #expect(png.count > 5000)
        if let directory = ProcessInfo.processInfo.environment["TYPEFLUX_RECOVERY_SCREENSHOTS"] {
            let root = URL(fileURLWithPath: directory)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try png.write(to: root.appendingPathComponent(name + ".png"))
        }
    }
}
