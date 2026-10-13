import AppKit
import SwiftUI
import Testing
@testable import Typeflux

/// Opt-in four-way renders of the production panels. Capture native glass on the acceptance Mac separately.
@Suite("Ask Spotlight snapshots", .exclusiveUIState)
@MainActor
struct AskSpotlightSnapshotTests {
    @Test func launcherAndPaletteMatrix() async throws {
        guard let path = ProcessInfo.processInfo.environment["TYPEFLUX_SPOTLIGHT_SNAPSHOTS"] else { return }
        let directory = URL(fileURLWithPath: path)
        let previousLanguage = AppLocalization.shared.language
        AppLocalization.shared.setLanguage(.english)
        defer { AppLocalization.shared.setLanguage(previousLanguage) }
        let fixture = try AskTestFixture()
        defer {
            fixture.model.resetSession()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        await fixture.api.seed(.init(id: "swift", title: "Swift concurrency", revision: 1,
                                    updatedAt: now, messages: []))
        await fixture.model.refreshHistory()
        fixture.model.launcherDraft = AskDraft(includeScreenshot: false)
        try await launcherMatrix(fixture, name: "launcher-home", directory: directory)
        fixture.model.launcherWindowMode = .simple
        try await launcherMatrix(fixture, name: "launcher-collapsed", directory: directory, height: 100)
        fixture.model.launcherWindowMode = .complete
        fixture.model.launcherDraft.text = "12 * 24"
        try await launcherMatrix(fixture, name: "launcher-calculator", directory: directory)

        try await palettesMatrix(fixture.model.conversations, directory: directory)
        try await pluginAndVoiceMatrix(fixture, directory: directory)
    }

    private func palettesMatrix(_ conversations: [AskConversationSummary], directory: URL) async throws {
        let palette = AskSearchPaletteView(conversations: conversations,
                                           available: AskPaletteAction.allCases,
                                           onAction: { _ in }, onOpen: { _ in }, onClose: {})
        try await TypefluxUISnapshot.renderMatrix(palette, size: NSSize(width: 760, height: 540),
                                                  directory: directory, name: "command-k")
        let empty = AskSearchPaletteView(conversations: [], available: [],
                                         onAction: { _ in }, onOpen: { _ in }, onClose: {})
        try await TypefluxUISnapshot.renderMatrix(empty, size: NSSize(width: 440, height: 280),
                                                  directory: directory, name: "command-k-empty-small")
        var commands = AskCommandPaletteState()
        commands.update(rows: AskCommandMatcher.filter(AskCommandCatalog.commands(.init()), query: ""))
        try await TypefluxUISnapshot.renderMatrix(
            AskCommandPaletteView(state: commands, onPick: { _ in }, onHighlight: { _ in }).padding(16),
            size: NSSize(width: 560, height: 420), directory: directory, name: "slash-commands"
        )
        for options in [TypefluxAccessibilityOptions(reduceTransparency: true),
                        TypefluxAccessibilityOptions(increasedContrast: true)] {
            let suffix = options.reduceTransparency ? "reduce-transparency" : "increase-contrast"
            try await TypefluxUISnapshot.renderMatrix(
                palette.environment(\.typefluxAccessibilityOptions, options),
                size: NSSize(width: 760, height: 540), directory: directory, name: "command-k-" + suffix,
                increasedContrast: options.increasedContrast
            )
        }
    }

    private func pluginAndVoiceMatrix(_ fixture: AskTestFixture, directory: URL) async throws {
        let items = VStack(spacing: 2) {
            AskPluginItemRow(item: .init(id: "one", title: "Release notes", subtitle: "Documents"),
                             symbol: "doc", selected: true, emphasized: true, height: 44, onPick: {})
            AskPluginItemRow(item: .init(id: "two", title: "Project folder", subtitle: "Workspace"),
                             symbol: "folder", selected: false, emphasized: true, height: 44, onPick: {})
        }.padding(8)
        try await TypefluxUISnapshot.renderMatrix(
            TypefluxGlassContainer(radius: .spotlightResults) { items }.padding(16),
            size: NSSize(width: 560, height: 140), directory: directory, name: "plugin-results"
        )
        let live = fixture.model.voiceInput.live
        live.receive(level: 0.7)
        live.receive(text: "Summarize the document", isFinal: false)
        try await TypefluxUISnapshot.renderMatrix(
            TypefluxGlassContainer(radius: .spotlightResults) {
                AskVoicePanel(live: live, listening: true, height: 160, token: nil)
            }.padding(16), size: NSSize(width: 560, height: 200), directory: directory, name: "voice-results"
        )
    }

    private func launcherMatrix(_ fixture: AskTestFixture, name: String, directory: URL,
                                height: CGFloat = 440) async throws {
        try await TypefluxUISnapshot.renderMatrix(AskLauncherView(model: fixture.model, onDismiss: {}),
                                                  size: NSSize(width: AskMetrics.launcherWidth, height: height),
                                                  directory: directory, name: name)
    }
}
