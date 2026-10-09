import AppKit
import SwiftUI
import Testing
@testable import Typeflux

/// Production surfaces rendered with synthetic accounts and isolated preferences.
@Suite("Ask first question snapshots", .serialized, .exclusiveUIState)
@MainActor
struct AskFirstQuestionVisualTests {
    @Test func renderFirstQuestionAndUsageStates() async throws {
        guard let directory = ProcessInfo.processInfo.environment["TYPEFLUX_FIRST_QUESTION_SNAPSHOTS"] else { return }
        let root = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = NSApplication.shared
        let language = AppLocalization.shared.language
        AppLocalization.shared.setLanguage(.simplifiedChinese)
        defer { AppLocalization.shared.setLanguage(language) }
        let signedOut = try AskTestFixture(localOnly: true)
        let signedIn = try AskTestFixture()
        defer { signedOut.model.resetSession(); signedIn.model.resetSession() }
        for (name, fixture) in [("signed-out", signedOut), ("signed-in", signedIn)] {
            try await render(VStack(spacing: 12) {
                AskLocalModeCard(status: .make(model: fixture.model, signedIn: fixture.model.isSignedIn),
                                 onOpenSearchSettings: {}, onSignIn: {})
                AskModelMenu(library: fixture.model.modelLibrary,
                             reference: .constant(fixture.model.modelReference(launcher: false)), compact: true,
                             cloudAvailable: fixture.model.cloudAvailable)
            }.frame(maxWidth: .infinity, maxHeight: .infinity).background(AskTheme.surface),
                             size: NSSize(width: 370, height: 460), file: root.appendingPathComponent("storage-\(name).png"))
        }
        signedOut.model.launcherDraft.text = "帮我总结这页内容"
        signedOut.model.submitLauncher()
        try await signedOut.wait { signedOut.model.busyIds.isEmpty }
        try await render(AskLauncherView(model: signedOut.model, onDismiss: {})
                            .environment(\.askGlassMaterialOverride, .opaque),
                         size: NSSize(width: 640, height: 320), file: root.appendingPathComponent("launcher-preflight.png"))
        try await render(AskUsagePanel(model: signedIn.model, runId: .constant(nil), close: {}),
                         size: NSSize(width: 330, height: 520), file: root.appendingPathComponent("usage-empty.png"))
        var conversation = AskConversation(id: "usage", title: "Synthetic conversation", revision: 1,
                                           updatedAt: Date(), messages: [],
                                           run: .init(id: "run", deviceId: "device", status: "completed", steps: 1,
                                                      updatedAt: Date(), tools: [], pending: []))
        await signedIn.api.seed(conversation)
        await signedIn.model.select(conversation.id)
        await signedIn.api.setFailUsage(true)
        try await render(AskUsagePanel(model: signedIn.model, runId: .constant(nil), close: {}),
                         size: NSSize(width: 330, height: 520), file: root.appendingPathComponent("usage-error.png"))
        await signedIn.api.setFailUsage(false)
        let totals = AskUsageTotals(inputTokens: 1200, outputTokens: 240, totalTokens: 1440, microcredits: 80000, calls: 1)
        conversation.usage = .init(version: 1, since: Date(), historicalGap: false, total: totals, runs: ["run": totals])
        conversation.revision += 1
        await signedIn.api.seed(conversation)
        await signedIn.model.select(conversation.id, reload: true)
        await signedIn.api.setUsageRecords([.init(id: "call", runId: "run", modelRef: "cloud:default", purpose: "answer",
                                                createdAt: Date(), tokens: .init(promptTokens: 1200, completionTokens: 240,
                                                                              totalTokens: 1440), source: "provider",
                                                microcredits: 80000, status: "confirmed", version: 1)])
        try await render(AskUsagePanel(model: signedIn.model, runId: .constant(nil), close: {}),
                         size: NSSize(width: 330, height: 640), file: root.appendingPathComponent("usage-data.png"))
    }

    private func render<V: View>(_ view: V, size: NSSize, file: URL) async throws {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        let hosting = NSHostingView(rootView: view.environment(\.askGlassMaterialOverride, .opaque)
            .frame(width: size.width, height: size.height, alignment: .top))
        hosting.sizingOptions = []
        hosting.frame = NSRect(origin: .zero, size: size)
        window.contentView = hosting
        window.orderFront(nil)
        defer { window.orderOut(nil); window.close() }
        try await Task.sleep(for: .milliseconds(400))
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: file)
        #expect(png.count > 2000)
    }
}
