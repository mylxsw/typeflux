import AppKit
import SwiftUI
import Testing
@testable import Typeflux

extension AskConversationVisualTests {
    @Test func libraryWorkspaceRendersFourCombinationsAtNarrowAndWideSizes() async throws {
        let configured = ProcessInfo.processInfo.environment["TYPEFLUX_ASK_SNAPSHOTS"]
        let directory = configured.map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { if configured == nil { try? FileManager.default.removeItem(at: directory) } }
        let suite = "ask-library-snapshots-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "ask.sidebarCollapsed")
        let library = AskModelLibrary(defaults: defaults, automaticallyLoadsCatalog: false)
        let fixture = try AskTestFixture(modelLibrary: library)
        defer { fixture.model.resetSession() }
        let date = Date()
        let conversation = AskConversation(id: "library", title: "Release plan", revision: 1, updatedAt: date,
                                           messages: [
            .init(id: "question", role: "user", text: "Prepare the release checklist.", createdAt: date),
            .init(id: "answer", role: "assistant", text: "## Checklist\n\n- Validate the build\n- Review the changes",
                  createdAt: date)
        ])
        await fixture.api.seed(conversation)
        for (id, title, days) in [("yesterday", "Review API changes", 1), ("earlier", "Meeting notes", 7)] {
            await fixture.api.seed(.init(id: id, title: title, revision: 1,
                                        updatedAt: date.addingTimeInterval(-Double(days) * 86400), messages: []))
        }
        await fixture.model.refreshHistory()
        for scene in ["empty", "private", "conversation", "attachments", "usage", "permission", "model-unavailable"] {
            if scene == "empty" || scene == "private" {
                fixture.model.newConversation(storesLocally: scene == "private")
            } else { await fixture.model.select(conversation.id) }
            fixture.model.draft.attachments = scene == "attachments" ? [
                .init(id: "checklist", kind: .file, name: "checklist.txt", byteSize: 28, text: "Review before release")
            ] : []
            fixture.model.captureWarning = scene == "permission" ? L("ask.capture.permission") : nil
            fixture.model.draft.includeScreenshot = scene == "permission"
            if scene == "model-unavailable" { fixture.model.draft.modelRef = "missing:model" }
            for size in [NSSize(width: 440, height: 560), NSSize(width: 1180, height: 760)] {
                for style in InterfaceStyle.allCases {
                    for dark in [false, true] {
                        let name = "ask-library-\(scene)-\(Int(size.width))-\(style.rawValue)-\(dark ? "dark" : "light")"
                        try await AskWorkspaceSnapshot.render(model: fixture.model, defaults: defaults, size: size,
                            style: style, dark: dark, showsUsage: scene == "usage",
                            file: configured == nil ? nil : directory.appendingPathComponent(name + ".png"))
                    }
                }
            }
        }
    }

    @Test func libraryPaletteAndModelPopoverRenderAllCombinations() async throws {
        let configured = ProcessInfo.processInfo.environment["TYPEFLUX_ASK_SNAPSHOTS"]
        let directory = configured.map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { if configured == nil { try? FileManager.default.removeItem(at: directory) } }
        let fixture = try AskTestFixture()
        defer { fixture.model.resetSession() }
        let palette = AskSearchPaletteView(conversations: [
            .init(id: "search", title: "Release plan", updatedAt: .distantPast)
        ], available: AskPaletteAction.allCases, onAction: { _ in }, onOpen: { _ in }, onClose: {})
        for size in [NSSize(width: 440, height: 560), NSSize(width: 1180, height: 760)] {
            try await TypefluxUISnapshot.renderMatrix(palette, size: size, directory: directory,
                                                       name: "ask-library-palette-\(Int(size.width))")
        }
        try fixture.model.modelLibrary.addModels([
            .init(id: "reasoner", name: "Reasoner", reference: "cloud:reasoner", scenarios: ["ask"],
                  reasoning: true, reasoningEfforts: ["low", "high"])
        ], providerID: "typefluxCloud")
        let nativeMenu = AskModelMenu(library: fixture.model.modelLibrary, reference: .constant("cloud:reasoner"),
                                     compact: true, usesNativePopover: true, cloudAvailable: true,
                                     effort: .constant(.high))
            .padding(TypefluxSpacing.large.value(for: .classic))
        try await TypefluxUISnapshot.renderMatrix(nativeMenu, size: NSSize(width: 360, height: 80),
                                                   directory: directory, name: "ask-library-model-control")
        let card = AskModelEffortCard(library: fixture.model.modelLibrary, reference: .constant("cloud:reasoner"),
                                     effort: .constant(.high), loggedIn: true, nativeControls: true)
        try await TypefluxUISnapshot.renderMatrix(card, size: NSSize(width: 360, height: 220),
                                                  directory: directory, name: "ask-library-reasoning")
        let models = AskModelEffortCard(library: fixture.model.modelLibrary, reference: .constant("cloud:reasoner"),
                                       effort: .constant(.high), loggedIn: true, page: .models, nativeControls: true)
        try await TypefluxUISnapshot.renderMatrix(models, size: NSSize(width: 360, height: 520),
                                                  directory: directory, name: "ask-library-models")
        for dark in [false, true] {
            for reduced in [false, true] {
                let suffix = reduced ? "reduce-transparency" : "high-contrast"
                try await AskWorkspaceSnapshot.render(model: fixture.model,
                    defaults: fixture.model.modelLibrary.settings.defaults, size: NSSize(width: 1180, height: 760),
                    style: .liquidGlass, dark: dark,
                    accessibility: .init(reduceTransparency: reduced, increasedContrast: !reduced),
                    file: configured == nil ? nil : directory.appendingPathComponent(
                        "ask-library-\(suffix)-\(dark ? "dark" : "light").png"))
            }
        }
    }
}
