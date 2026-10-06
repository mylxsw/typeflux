import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Typeflux

/// Renders the gallery, an example's detail page, an update's differences, the
/// Keywords step with entries and files, and settings' empty state, as
/// `docs/design/workflow-gallery-output-actions.html` shows them (screens ①②③).
/// With TYPEFLUX_ASK_SNAPSHOTS set the images are written there in Chinese as
/// `implemented-*.png`; otherwise the views are only laid out.
@Suite("Workflow gallery rendering", .serialized)
@MainActor
struct WorkflowGalleryVisualTests {
    private let size = NSSize(width: 1450, height: 900)
    private let visual = WorkflowOutputActionsVisualTests()

    /// An editor with the exchange-rate example added from the gallery, and two others.
    private func editor(_ fixture: AskWorkflowFixture) throws -> AskWorkflowEditorModel {
        let exchange = try #require(AskWorkflowGallery.bundled.item("fx"))
        try fixture.store.add(exchange, builtIn: [])
        try fixture.write("local.python", manifest: AskWorkflowFixture.inline(
            "local.python", keyword: "wf", script: "print 1", extra: ["name": "Python · 输出文本"]
        ))
        try fixture.write("local.ip", manifest: AskWorkflowFixture.inline(
            "local.ip", keyword: "ip", script: "print 1", extra: ["name": "本机 IP"]
        ))
        fixture.store.reload()
        fixture.store.trust("local.python")
        fixture.store.trust("local.ip")
        fixture.store.setEnabled("local.ip", false)
        let defaults = try #require(UserDefaults(suiteName: "gul231-visual-\(UUID().uuidString)"))
        let assistant = AskWorkflowAssistant(dependencies: .init(
            api: AskWorkflowScriptedAPI([]), session: { ("owner", "token") }, deviceId: "device",
            modelLibrary: AskModelLibrary(defaults: defaults, automaticallyLoadsCatalog: false), defaults: defaults
        ))
        let model = AskWorkflowEditorModel(store: fixture.store, settings: fixture.settings, assistant: assistant,
                                           tester: AskWorkflowTester(home: fixture.home.path))
        model.staging = AskWorkflowStaging(root: fixture.home.appendingPathComponent("drafts"))
        model.watchInterval = 0
        model.open("local.fx")
        model.testQuery = "100 usd jpy"
        return model
    }

    /// The gallery as a sheet over the editor.
    private func overEditor(_ model: AskWorkflowEditorModel, _ store: AskWorkflowStore,
                            _ sheet: AskWorkflowGallerySheet) -> some View {
        ZStack {
            AskWorkflowEditorView(model: model, store: store, panel: .test)
            Color.black.opacity(0.35)
            sheet.clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .shadow(color: .black.opacity(0.4), radius: 30, y: 10)
        }
    }

    @Test func `keywords step with entries and files`() async throws {
        try await visual.chinese {
            let fixture = try AskWorkflowFixture()
            let model = try editor(fixture)
            model.step = .keywords
            #expect(model.entryCandidates == ["rates.py", "table.py"])
            #expect(model.entryScripts == ["main.py", "table.py"])
            #expect(model.fileRows.map(\.path) == ["main.py", "table.py", "README.md", "rates.py"])
            #expect(model.fileRows[3].references.map(\.from) == ["main.py", "table.py"])
            let view = { AskWorkflowEditorView(model: model, store: fixture.store, panel: .test) }
            try await visual.render(view(), size: size, name: "implemented-ed-entry.png")
            try await visual.render(view(), size: size, name: "implemented-ed-entry-light.png", light: true)
            // Choosing entries: the default entry clears the keyword's own.
            model.setKeywordScript("rates.py", at: 0)
            #expect(model.draft?.manifest?.keywords[0].script == "rates.py")
            model.setKeywordScript("main.py", at: 0)
            #expect(model.draft?.manifest?.keywords[0].script == nil)
            model.setKeywordScript(nil, at: 1)
            #expect(model.draft?.manifest?.keywords[1].script == nil && model.entryScripts == ["main.py"])
            model.setKeywordScript("x.py", at: 9)
            model.setKeywordScript("gone.py", at: 1)
            #expect(model.problems(for: .keywords).map(\.field) == ["keywords[1].script"])
            try await visual.render(view(), size: size, name: "implemented-ed-entry-problem.png")
            model.openFile("rates.py")
            #expect(model.step == .script && model.selectedFile == "rates.py")
            model.openFile("missing.py")
            #expect(model.selectedFile == "rates.py")
            // The script step's tabs: entries first, marked.
            model.setKeywordScript("table.py", at: 1)
            model.openFile("table.py")
            try await visual.render(view(), size: size, name: "implemented-ed-entry-tabs.png")
        }
    }

    @Test func `gallery, detail and update`() async throws {
        try await visual.chinese {
            let fixture = try AskWorkflowFixture()
            let model = try editor(fixture)
            model.step = .output
            func sheet(_ selected: String? = nil, updating: String? = nil,
                       missing: Set<AskWorkflowRuntime> = []) -> AskWorkflowGallerySheet {
                AskWorkflowGallerySheet(store: fixture.store, builtIn: [], selected: selected, updating: updating,
                                        missing: missing, open: { _ in }, done: {})
            }
            try await visual.render(
                overEditor(model, fixture.store, sheet()),
                size: size,
                name: "implemented-g-list.png"
            )
            try await visual.render(overEditor(model, fixture.store, sheet()), size: size,
                                    name: "implemented-g-list-light.png", light: true)
            try await visual.render(overEditor(model, fixture.store, sheet("fx")), size: size,
                                    name: "implemented-g-detail.png")
            try await visual.render(overEditor(model, fixture.store, sheet("fx")), size: size,
                                    name: "implemented-g-detail-light.png", light: true)
            try await visual.render(overEditor(model, fixture.store, sheet("codec", missing: [.node])), size: size,
                                    name: "implemented-g-detail-node.png")
            try await visual.render(overEditor(model, fixture.store, sheet(missing: [.node])), size: size,
                                    name: "implemented-g-list-node.png")

            // An older added version: the card offers the update, which opens the differences.
            let folder = try #require(fixture.store.workflow("local.fx")?.folder)
            var draft = AskWorkflowDraft.load(folder: folder)
            draft.set(["gallery": "fx", "version": "0.9.0"], at: ["origin"])
            try draft.setText(#require(draft.text(of: "main.py")).replacingOccurrences(of: "usd", with: "eur"),
                              of: "main.py")
            _ = try fixture.store.save("local.fx", folder: folder, writes: draft.pendingWrites,
                                       expectedHash: #require(fixture.store.workflow("local.fx")?.hash))
            let exchange = try #require(AskWorkflowGallery.bundled.item("fx"))
            #expect(fixture.store.hasUpdate(exchange))
            #expect(fixture.store.galleryUpdate(exchange)?.userModified == ["main.py", "workflow.json"])
            try await visual.render(overEditor(model, fixture.store, sheet()), size: size,
                                    name: "implemented-g-list-update.png")
            try await visual.render(overEditor(model, fixture.store, sheet("fx", updating: "fx")), size: size,
                                    name: "implemented-g-update.png")
            let kinds: [AskWorkflowAction.Kind] = [.copy, .notify]
            #expect(AskWorkflowGallerySheet.actions(exchange) == kinds.map(\.title))
        }
    }

    @Test func `settings empty state and gallery button`() async throws {
        try await visual.chinese {
            let fixture = try AskWorkflowFixture()
            let settingsSize = NSSize(width: 820, height: 330)
            let page = {
                ScrollView {
                    AskWorkflowSettingsView(store: fixture.store, settings: fixture.settings)
                        .background(ModelVisualStyle.surface, in: RoundedRectangle(cornerRadius: 12))
                        .padding(20)
                }
            }
            try await visual.render(page(), size: settingsSize, name: "implemented-settings-empty.png")
            try await visual.render(
                page(),
                size: settingsSize,
                name: "implemented-settings-empty-light.png",
                light: true
            )
            try fixture.store.add(#require(AskWorkflowGallery.bundled.item("wc")), builtIn: [])
            try await visual.render(page(), size: settingsSize, name: "implemented-settings-list.png")
            let starter = AskWorkflowGalleryStarter(store: fixture.store, gallery: .bundled, builtIn: [],
                                                    browse: {}, open: { _ in })
            #expect(AskWorkflowGalleryStarter.count == 3)
            try await visual.render(starter, size: settingsSize, name: "implemented-settings-starter-added.png")
        }
    }
}
