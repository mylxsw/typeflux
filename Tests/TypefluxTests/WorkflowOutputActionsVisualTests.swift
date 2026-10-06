import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Typeflux

/// Renders the Output step, its menus, the test panel's actions and the launcher's
/// bottom bar as `docs/design/workflow-gallery-output-actions.html` shows them
/// (screens ④⑤⑥⑧⑨). With TYPEFLUX_ASK_SNAPSHOTS set the images are written there
/// in Chinese as `implemented-*.png`; otherwise the views are only laid out.
@Suite("Workflow output and actions rendering", .serialized)
@MainActor
struct WorkflowOutputActionsVisualTests {
    static let script = """
    #!/usr/bin/env python3
    # Prints the conversion, then the rate.
    import sys

    query = sys.argv[1] if len(sys.argv) > 1 else "100 usd jpy"
    amount = float(query.split()[0]) if query.split() else 100
    print(f"{amount:g} USD = {amount * 149.123:,.2f} JPY")
    print("1 USD = 149.123 JPY")

    """

    let manifest: [String: Any] = [
        "schema": 1, "id": "local.fx", "name": "汇率换算", "description": "实时汇率", "version": "1.0.0",
        "keywords": [["keyword": "fx"], ["keyword": "rate", "title": "汇率表", "options": ["to": "usd,eur,jpy"]]],
        "input": ["argument": "optional", "selection": "ifEmpty"], "run": ["mode": "onSubmit", "timeoutSeconds": 10],
        "command": ["runtime": "python3", "script": "main.py", "args": ["{query}"]],
        "output": [
            "display": "text",
            "onSuccess": [["action": "copy", "value": "{output.line1}"],
                          ["action": "notify", "title": "汇率换算", "body": "{output}"]]
        ]
    ]

    private let size = NSSize(width: 1450, height: 900)

    func render(_ view: some View, size: NSSize, name: String, light: Bool = false) async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
        let hosting = NSHostingView(rootView: view.frame(width: size.width, height: size.height)
            .background(StudioTheme.windowBackground))
        hosting.frame = NSRect(origin: .zero, size: size)
        window.contentView = hosting
        window.orderFront(nil)
        defer { window.orderOut(nil); window.close() }
        try await Task.sleep(for: .milliseconds(500))
        hosting.layoutSubtreeIfNeeded()
        #expect(hosting.fittingSize.height > 0)
        guard let directory = ProcessInfo.processInfo.environment["TYPEFLUX_ASK_SNAPSHOTS"] else { return }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
    }

    func chinese(_ body: () async throws -> Void) async rethrows {
        let previous = AppLocalization.shared.language
        let snapshots = ProcessInfo.processInfo.environment["TYPEFLUX_ASK_SNAPSHOTS"] != nil
        if snapshots {
            AppLocalization.shared.setLanguage(.simplifiedChinese)
        }
        defer {
            if snapshots {
                AppLocalization.shared.setLanguage(previous)
            }
        }
        try await body()
    }

    func wait(_ condition: () -> Bool) async {
        for _ in 0 ..< 1500 where !condition() {
            try? await Task.sleep(for: .milliseconds(4))
        }
    }

    private func editor(_ fixture: AskWorkflowFixture) throws -> AskWorkflowEditorModel {
        try fixture.write("local.fx", manifest: manifest, files: ["main.py": Self.script], executable: ["main.py"])
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
        let defaults = try #require(UserDefaults(suiteName: "gul230-visual-\(UUID().uuidString)"))
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

    @Test func `output step, menus and test panel`() async throws {
        try await chinese {
            let fixture = try AskWorkflowFixture()
            let model = try editor(fixture)
            #expect(model.draft?.manifest?.output.onSuccess.count == 2)
            model.runTest()
            await wait { !model.isTesting && !model.results.isEmpty }
            #expect(model.results.last?.succeeded == true)
            #expect(model.results.last?.actionOutcomes.map(\.status) == [.skipped(nil), .skipped(nil)])
            let view = { AskWorkflowEditorView(model: model, store: fixture.store, panel: .test) }
            try await render(view(), size: size, name: "implemented-ed-output.png")
            try await render(view(), size: size, name: "implemented-ed-output-light.png", light: true)
            model.outputMenu = .add(.onSuccess)
            try await render(view(), size: size, name: "implemented-ed-add.png")
            try await render(view(), size: size, name: "implemented-ed-add-light.png", light: true)
            model.outputMenu = .placeholder(.onSuccess, index: 0, field: .value)
            try await render(view(), size: size, name: "implemented-ed-token.png")
            try await render(view(), size: size, name: "implemented-ed-token-light.png", light: true)
            model.outputMenu = nil
            try await render(AskWorkflowEditorView(model: model, store: fixture.store, panel: .test,
                                                   testTab: .actions),
                             size: size, name: "implemented-ed-test.png")
            try await render(AskWorkflowEditorView(model: model, store: fixture.store, panel: .test,
                                                   testTab: .actions),
                             size: size, name: "implemented-ed-test-light.png", light: true)
            // Failure actions, and a problem on a row.
            model.addAction(.open, to: .onFailure)
            model.setActionField(.target, to: "javascript:alert(1)", at: 0, in: .onFailure)
            model.setDisplay(.none)
            try await render(view(), size: size, name: "implemented-ed-output-none.png")
        }
    }
}
