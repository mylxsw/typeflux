import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Typeflux

/// Renders item lists and Markdown: the Output step with "Item list" chosen
/// (screen ⑦ of `docs/design/workflow-gallery-output-actions.html`), the launcher
/// with a list and with a Markdown card, and the two list examples in the gallery.
/// With TYPEFLUX_ASK_SNAPSHOTS set the images are written there in Chinese as
/// `implemented-*.png`; otherwise the views are only laid out.
@Suite("Workflow items and Markdown rendering", .serialized)
@MainActor
struct WorkflowItemsVisualTests {
    private let size = NSSize(width: 1450, height: 900)
    private let visual = WorkflowOutputActionsVisualTests()

    /// The exchange-rate workflow of the design, printing its conversions as a list.
    static let script = #"""
    #!/bin/zsh
    # Prints the conversions as rows; Return copies the chosen amount.
    print -r -- '{"items": ['
    print -r -- '{"uid": "jpy", "title": "14,912.30 JPY", "subtitle": "1 USD = 149.123 JPY", "arg": "14,912.30 JPY", "icon": "sf:yensign", "action": "copy"},'
    print -r -- '{"uid": "eur", "title": "92.18 EUR", "subtitle": "1 USD = 0.9218 EUR", "arg": "92.18 EUR", "icon": "sf:eurosign", "action": "copy"},'
    print -r -- '{"uid": "cny", "title": "718.40 CNY", "subtitle": "1 USD = 7.184 CNY", "arg": "718.40 CNY", "icon": "sf:yensign", "action": "copy"}'
    print -r -- ']}'

    """#

    static let markdown = #"""
    #!/bin/zsh
    print -r -- '### 100 USD'
    print -r -- ''
    print -r -- '| 货币 | 金额 | 汇率 |'
    print -r -- '|---|---:|---:|'
    print -r -- '| JPY | 14,912.30 | 149.123 |'
    print -r -- '| EUR | 92.18 | 0.9218 |'
    print -r -- '| CNY | 718.40 | 7.184 |'
    print -r -- ''
    print -r -- '汇率来自 **open.er-api.com**，`fx` 每小时更新一次。'

    """#

    private func manifest(display: String) -> [String: Any] {
        var manifest = visual.manifest
        manifest["command"] = ["runtime": "zsh", "script": "main.sh", "args": ["{query}"]]
        // A list's actions read the first row; a card's read its text.
        let list = display == "items"
        manifest["output"] = ["display": display,
                              "onSuccess": [["action": "copy", "value": list ? "{json.items.0.arg}" : "{output}"],
                                            ["action": "notify", "title": "汇率换算",
                                             "body": list ? "{json.items.0.title}" : "{output.lastLine}"]]]
        return manifest
    }

    private func editor(_ fixture: AskWorkflowFixture, display: String,
                        script: String) throws -> AskWorkflowEditorModel {
        try fixture.write("local.fx", manifest: manifest(display: display), files: ["main.sh": script],
                          executable: ["main.sh"])
        try fixture.write("local.python", manifest: AskWorkflowFixture.inline(
            "local.python", keyword: "wf", script: "print 1", extra: ["name": "Python · 输出文本"]
        ))
        try fixture.write("local.ip", manifest: AskWorkflowFixture.inline(
            "local.ip", keyword: "ip", script: "print 1", extra: ["name": "本机 IP"]
        ))
        fixture.store.reload()
        for id in ["local.fx", "local.python", "local.ip"] {
            fixture.store.trust(id)
        }
        fixture.store.setEnabled("local.ip", false)
        let defaults = try #require(UserDefaults(suiteName: "gul232-visual-\(UUID().uuidString)"))
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
        model.step = .output
        return model
    }

    @Test func `output step with a list and with Markdown`() async throws {
        try await visual.chinese {
            let fixture = try AskWorkflowFixture()
            let model = try editor(fixture, display: "items", script: Self.script)
            #expect(model.problems(for: .output).isEmpty)
            #expect(AskWorkflowOutputForm.displayChoices.filter(\.comingSoon).map(\.value) == [.image])
            #expect(try AskWorkflowEditorModel.outputSummary(#require(model.draft?.manifest?.output))
                == L("ask.workflow.editor.outputShort.items") + " · " + L("ask.workflow.editor.actionsCount", 2))
            model.runTest()
            await visual.wait { !model.isTesting && !model.results.isEmpty }
            #expect(model.results.last?.succeeded == true)
            #expect(model.successPreview.map(\.detail).first == "14,912.30 JPY")
            let view = { AskWorkflowEditorView(model: model, store: fixture.store, panel: .test) }
            try await visual.render(view(), size: size, name: "implemented-ed-items.png")
            try await visual.render(view(), size: size, name: "implemented-ed-items-light.png", light: true)
            // Changing the display redraws the preview from the same run.
            model.setDisplay(.markdown)
            #expect(model.draft?.manifest?.output.display == .markdown)
            #expect(try AskWorkflowEditorModel.outputSummary(#require(model.draft?.manifest?.output))
                .hasPrefix(L("ask.workflow.editor.outputShort.markdown")))
        }
    }

    @Test func `output step with Markdown`() async throws {
        try await visual.chinese {
            let fixture = try AskWorkflowFixture()
            let model = try editor(fixture, display: "markdown", script: Self.markdown)
            let sample = AskWorkflowLauncherPreview(name: "", keyword: "", query: "", result: nil,
                                                    output: .init(display: .markdown), timeout: 10)
            #expect(sample.decoded == .markdown(L("ask.workflow.editor.preview.sampleMarkdown")))
            let list = AskWorkflowLauncherPreview(name: "", keyword: "", query: "", result: nil,
                                                  output: .init(display: .items), timeout: 10)
            guard case let .items(rows) = list.decoded else { Issue.record("the list sample is a list"); return }
            #expect(rows.items.count == 3)
            model.runTest()
            await visual.wait { !model.isTesting && !model.results.isEmpty }
            #expect(model.results.last?.succeeded == true)
            let view = { AskWorkflowEditorView(model: model, store: fixture.store, panel: .test) }
            try await visual.render(view(), size: size, name: "implemented-ed-markdown.png")
            try await visual.render(view(), size: size, name: "implemented-ed-markdown-light.png", light: true)
        }
    }

    private func launcher(_ display: String, script: String, light: Bool, name: String,
                          height: CGFloat) async throws {
        let workflows = try AskWorkflowFixture()
        var manifest = manifest(display: display)
        manifest["output"] = display
        try workflows.write("local.fx", manifest: manifest, files: ["main.sh": script], executable: ["main.sh"])
        workflows.store.reload()
        workflows.store.trust("local.fx")
        let fixture = try AskTestFixture()
        defer { fixture.model.resetSession() }
        let model = fixture.model
        model.workflows = workflows.store
        _ = await AskWorkflowPath.searchPath()
        await model.refreshLauncherWorkflows()
        _ = model.plugins.detect(in: "fx 100 usd")
        model.launcherDraft.text = "100 usd"
        model.plugins.update(text: "100 usd", selection: nil, language: .simplifiedChinese, runWhenPlanned: true)
        await visual.wait { model.plugins.output != nil }
        #expect(model.plugins.output != nil)
        let view = AskLauncherView(model: model, onDismiss: {}).environment(\.askGlassMaterialOverride, .opaque)
        try await visual.render(view, size: NSSize(width: AskMetrics.launcherWidth, height: height), name: name,
                                light: light)
    }

    @Test func `the launcher shows a list and a Markdown card`() async throws {
        try await visual.chinese {
            for light in [false, true] {
                try await launcher("items", script: Self.script, light: light,
                                   name: light ? "implemented-launcher-items-light.png" :
                                       "implemented-launcher-items.png",
                                   height: 360)
            }
            try await launcher("markdown", script: Self.markdown, light: false,
                               name: "implemented-launcher-markdown.png", height: 540)
        }
    }

    @Test func `the list examples in the gallery`() async throws {
        try await visual.chinese {
            let fixture = try AskWorkflowFixture()
            let model = try editor(fixture, display: "items", script: Self.script)
            @MainActor func sheet(_ selected: String?) -> some View {
                ZStack {
                    AskWorkflowEditorView(model: model, store: fixture.store, panel: .test)
                    Color.black.opacity(0.35)
                    AskWorkflowGallerySheet(store: fixture.store, builtIn: [], selected: selected, updating: nil,
                                            missing: [], open: { _ in }, done: {})
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
            let ip = try #require(AskWorkflowGallery.bundled.item("ip"))
            #expect(AskWorkflowGallerySheet.actions(ip) == [L("ask.workflow.gallery.list")])
            #expect(AskWorkflowGallerySheet.previewDisplay(ip) == .items)
            let uuid = try #require(AskWorkflowGallery.bundled.item("uuid"))
            #expect(AskWorkflowGallerySheet.previewDisplay(uuid) == .text, "what it copies shows as text")
            try await visual.render(sheet("ip"), size: size, name: "implemented-g-detail-ip.png")
            try await visual.render(sheet("code"), size: size, name: "implemented-g-detail-code.png")
            try await visual.render(sheet(nil), size: size, name: "implemented-g-list-o3.png")
        }
    }
}
