import AppKit
import CoreImage
import Foundation
import SwiftUI
import Testing
@testable import Typeflux

/// Renders O4 as `docs/design/workflow-gallery-output-actions.html` shows it: the
/// test panel with the script's actions (screen ⑧), "Run another keyword" in the add
/// menu and its row, the image display in the editor and the launcher, and the
/// launcher's question about a new host. With TYPEFLUX_ASK_SNAPSHOTS set the images
/// are written there in Chinese as `implemented-*.png`; otherwise only laid out.
@Suite("Workflow script actions, images and run keyword rendering", .serialized)
@MainActor
struct WorkflowScriptActionsVisualTests {
    private let visual = WorkflowOutputActionsVisualTests()
    private let size = NSSize(width: 1450, height: 900)

    /// The converter, printing its text and a link to add. The host is put together
    /// at run time, so the workflow does not name it and the launcher asks first.
    static let script = """
    #!/usr/bin/env python3
    # Prints the conversion, and a link to it on xe.com as an action of its own.
    import json
    import sys

    query = sys.argv[1] if len(sys.argv) > 1 else "100 usd jpy"
    amount = float(query.split()[0]) if query.split() else 100
    text = f"{amount:g} USD = {amount * 149.123:,.2f} JPY"
    site = "www.xe.com/currencyconverter/convert/?Amount=" + f"{amount:g}" + "&From=USD&To=JPY"
    print(json.dumps({"text": text, "actions": [{"action": "open", "target": "https://" + site}]}))

    """

    private var manifest: [String: Any] {
        var manifest = visual.manifest
        manifest["output"] = [
            "display": "text",
            "onSuccess": [["action": "copy", "value": "{output.line1}"],
                          ["action": "notify", "title": "汇率换算", "body": "{output}"]]
        ]
        return manifest
    }

    /// A QR code like the one a `qr` workflow would print, scaled up crisply.
    static func qrCode(_ text: String) throws -> Data {
        let filter = try #require(CIFilter(name: "CIQRCodeGenerator"))
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        let image = try #require(filter.outputImage).transformed(by: CGAffineTransform(scaleX: 6, y: 6))
        let rep = NSBitmapImageRep(ciImage: image)
        return try #require(rep.representation(using: .png, properties: [:]))
    }

    private func editor(_ fixture: AskWorkflowFixture, manifest: [String: Any], files: [String: String],
                        executable: [String] = [],
                        prepare: (URL) throws -> Void = { _ in }) throws -> AskWorkflowEditorModel {
        // Files are in place before the workflow is trusted, as its hash covers them.
        try prepare(fixture.write("local.fx", manifest: manifest, files: files, executable: executable))
        fixture.store.reload()
        fixture.store.trust("local.fx")
        let defaults = try #require(UserDefaults(suiteName: "gul233-visual-\(UUID().uuidString)"))
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

    private func test(_ model: AskWorkflowEditorModel) async {
        let count = model.results.count
        model.runTest()
        await visual.wait { !model.isTesting && model.results.count > count }
    }

    @Test func `panel with the script's actions, and run another keyword`() async throws {
        try await visual.chinese {
            let fixture = try AskWorkflowFixture()
            let model = try editor(fixture, manifest: manifest, files: ["main.py": Self.script],
                                   executable: ["main.py"])
            await test(model)
            let result = try #require(model.results.last)
            #expect(result.succeeded && result.actionSteps.map(\.fromScript) == [false, false, true])
            #expect(result.actionSteps.last?.notRun == L("ask.workflow.action.scriptNotAllowed"))
            let tab = { AskWorkflowEditorView(model: model, store: fixture.store, panel: .test, testTab: .actions) }
            try await visual.render(tab(), size: size, name: "implemented-ed-test-script.png")
            try await visual.render(tab(), size: size, name: "implemented-ed-test-script-light.png", light: true)
            model.setOutputFlag("scriptActions", true)
            await test(model)
            #expect(model.results.last?.actionSteps.last?.notRun == nil)
            #expect(model.results.last?.actionSteps.last?.confirmHost == "www.xe.com")
            try await visual.render(tab(), size: size, name: "implemented-ed-test-script-allowed.png")
            let view = { AskWorkflowEditorView(model: model, store: fixture.store, panel: .test) }
            model.outputMenu = .add(.onSuccess)
            try await visual.render(view(), size: size, name: "implemented-ed-add-o4.png")
            try await visual.render(view(), size: size, name: "implemented-ed-add-o4-light.png", light: true)
            model.outputMenu = nil
            model.addAction(.runKeyword, to: .onSuccess)
            model.setActionField(.keyword, to: "tr", at: 2, in: .onSuccess)
            #expect(model.problems(for: .output).isEmpty)
            #expect(model.successPreview.last?.detail == "tr 100 USD = 14,912.30 JPY")
            try await visual.render(view(), size: size, name: "implemented-ed-runkeyword.png")
            try await visual.render(view(), size: size, name: "implemented-ed-runkeyword-light.png", light: true)
            model.setActionField(.keyword, to: "fx", at: 2, in: .onSuccess)
            #expect(model.successPreview.last?.problem == L("ask.workflow.action.loop", "fx → fx"))
        }
    }

    @Test func `image display in the editor and the launcher`() async throws {
        try await visual.chinese {
            let fixture = try AskWorkflowFixture()
            var manifest = AskWorkflowFixture.inline("local.fx", keyword: "qr", script: "print -r -- qr.png",
                                                     output: "image")
            manifest["name"] = "二维码"
            let model = try editor(fixture, manifest: manifest, files: [:]) { folder in
                try Self.qrCode("https://typeflux.app").write(to: folder.appendingPathComponent("qr.png"))
            }
            let view = { AskWorkflowEditorView(model: model, store: fixture.store, panel: .test) }
            try await visual.render(view(), size: size, name: "implemented-ed-image-sample.png")
            await test(model)
            #expect(model.results.last?.succeeded == true)
            try await visual.render(view(), size: size, name: "implemented-ed-image.png")
            try await visual.render(view(), size: size, name: "implemented-ed-image-light.png", light: true)
            #expect(try AskWorkflowEditorModel.outputSummary(#require(model.draft?.manifest?.output))
                == L("ask.workflow.editor.outputShort.image"))

            let ask = try AskTestFixture()
            defer { ask.model.resetSession() }
            let launcher = ask.model
            launcher.workflows = fixture.store
            _ = await AskWorkflowPath.searchPath()
            await launcher.refreshLauncherWorkflows()
            _ = launcher.plugins.detect(in: "qr typeflux")
            launcher.launcherDraft.text = "typeflux"
            launcher.plugins.update(
                text: "typeflux",
                selection: nil,
                language: .simplifiedChinese,
                runWhenPlanned: true
            )
            await visual.wait { launcher.plugins.output != nil }
            let image = try #require(launcher.plugins.output?.image)
            #expect(image.width == image.height)
            for light in [false, true] {
                let card = AskLauncherView(model: launcher, onDismiss: {})
                    .environment(\.askGlassMaterialOverride, .opaque)
                try await visual.render(card, size: NSSize(width: AskMetrics.launcherWidth, height: 470),
                                        name: light ? "implemented-launcher-image-light.png"
                                            : "implemented-launcher-image.png", light: light)
            }
        }
    }

    @Test func `the launcher asks before opening a host the workflow does not name`() async throws {
        try await visual.chinese {
            let fixture = try AskWorkflowFixture()
            var manifest = manifest
            manifest["output"] = ["display": "text", "scriptActions": true,
                                  "onSuccess": [["action": "hud", "text": "{output.line1}"]]]
            try fixture.write("local.fx", manifest: manifest, files: ["main.py": Self.script], executable: ["main.py"])
            fixture.store.reload()
            fixture.store.trust("local.fx")
            let ask = try AskTestFixture()
            defer { ask.model.resetSession() }
            let model = ask.model
            model.workflows = fixture.store
            var opened: [URL] = []
            model.openURL = { opened.append($0) }
            _ = await AskWorkflowPath.searchPath()
            await model.refreshLauncherWorkflows()
            _ = model.plugins.detect(in: "fx 100 usd jpy")
            model.launcherDraft.text = "100 usd jpy"
            model.plugins.update(
                text: "100 usd jpy",
                selection: nil,
                language: .simplifiedChinese,
                runWhenPlanned: true
            )
            await visual.wait { model.plugins.output != nil }
            let followUp = try #require(model.plugins.output?.followUp)
            model.performWorkflowFollowUp(followUp) {}
            await visual.wait { model.workflowApproval != nil }
            #expect(model.workflowApproval?.host == "www.xe.com")
            for light in [false, true] {
                let view = AskLauncherView(model: model, onDismiss: {}).environment(\.askGlassMaterialOverride, .opaque)
                try await visual.render(view, size: NSSize(width: AskMetrics.launcherWidth, height: 330),
                                        name: light ? "implemented-launcher-approval-light.png"
                                            : "implemented-launcher-approval.png", light: light)
            }
            model.answerWorkflowApproval(false)
            await visual.wait { model.workflowActions?.outcomes.isEmpty == false }
            #expect(opened.isEmpty)
            #expect(model.workflowActions?.outcomes.last?.status
                == .skipped(L("ask.workflow.action.hostDeclined", "www.xe.com")))
        }
    }
}
