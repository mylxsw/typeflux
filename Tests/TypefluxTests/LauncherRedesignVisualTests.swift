import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Typeflux

/// Renders the launcher keyword list and the workflow editor in the states the
/// design shows (`docs/design/launcher-keywords-workflow-editor.html`). With
/// TYPEFLUX_ASK_SNAPSHOTS set the images are written there in Chinese; otherwise the
/// views are only laid out.
@Suite("Launcher keywords and workflow editor rendering", .serialized)
@MainActor
// swiftlint:disable:next type_body_length
struct LauncherRedesignVisualTests {
    private static let script = """
    #!/usr/bin/env python3
    # The typed text is the first argument; the selection and the source app arrive as JSON on stdin.
    import json
    import sys

    request = json.loads(sys.stdin.readline() or "{}")
    query = sys.argv[1] if len(sys.argv) > 1 else ""
    text = query or request.get("selection") or ""

    words = len(text.split())
    print(f"{len(text)} characters, {words} words")
    print(f"avg {len(text) / words:.1f} per word")

    """

    private let manifest: [String: Any] = [
        "schema": 1, "id": "local.python", "name": "Python · 输出文本", "description": "统计文字的字数和词数",
        "keywords": [["keyword": "wf"], ["keyword": "wc", "title": "只数字数", "options": ["mode": "chars"]]],
        "input": ["argument": "optional", "selection": "ifEmpty"], "run": ["mode": "onSubmit", "timeoutSeconds": 30],
        "command": ["runtime": "python3", "script": "main.py", "args": ["{query}"]], "output": "text",
        "env": ["LANG": "en_US.UTF-8"]
    ]

    private func render(_ view: some View, size: NSSize, name: String, light: Bool = false) async throws {
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
        try await Task.sleep(for: .milliseconds(400))
        hosting.layoutSubtreeIfNeeded()
        #expect(hosting.fittingSize.height > 0)
        guard let directory = ProcessInfo.processInfo.environment["TYPEFLUX_ASK_SNAPSHOTS"] else { return }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
    }

    private func waitFor(_ condition: () -> Bool) async {
        for _ in 0 ..< 1500 where !condition() {
            try? await Task.sleep(for: .milliseconds(4))
        }
    }

    private func chinese(_ body: () async throws -> Void) async rethrows {
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

    private func workflows(_ fixture: AskWorkflowFixture) throws {
        try fixture.write("local.python", manifest: manifest, files: ["main.py": Self.script, "README.md": "# wf\n"],
                          executable: ["main.py"])
        try fixture.write("local.fx", manifest: AskWorkflowFixture.inline(
            "local.fx", keyword: "fx", script: "print 1", extra: ["name": "汇率换算"]
        ))
        try fixture.write("local.ip", manifest: AskWorkflowFixture.inline(
            "local.ip", keyword: "ip", script: "print 1", extra: ["name": "本机 IP"]
        ))
        fixture.store.reload()
        for id in ["local.python", "local.fx", "local.ip"] {
            fixture.store.trust(id)
        }
        fixture.store.setEnabled("local.ip", false)
    }

    private func editor(_ fixture: AskWorkflowFixture,
                        api: any AskAPI = AskWorkflowScriptedAPI([])) throws -> AskWorkflowEditorModel {
        try workflows(fixture)
        let defaults = try #require(UserDefaults(suiteName: "gul229-visual-\(UUID().uuidString)"))
        let assistant = AskWorkflowAssistant(dependencies: .init(
            api: api, session: { ("owner", "token") }, deviceId: "device",
            modelLibrary: AskModelLibrary(defaults: defaults, automaticallyLoadsCatalog: false), defaults: defaults
        ))
        let model = AskWorkflowEditorModel(store: fixture.store, settings: fixture.settings, assistant: assistant,
                                           tester: AskWorkflowTester(home: fixture.home.path))
        model.staging = AskWorkflowStaging(root: fixture.home.appendingPathComponent("drafts"))
        model.watchInterval = 0
        model.open("local.python")
        model.testQuery = "hello world"
        return model
    }

    private let editorSize = NSSize(width: 1280, height: 780)

    @Test func `keyword list`() async throws {
        try await chinese {
            let fixture = try AskWorkflowFixture()
            try workflows(fixture)
            var keywords = AskPluginRegistry.defaultKeywords
            keywords[8].enabled = false
            fixture.settings.saveAskLauncherKeywords(keywords)
            fixture.settings.askTranslationSecondLanguage = "en"
            for light in [false, true] {
                let view = ScrollView {
                    LauncherSettingsView(settings: fixture.settings, pane: .keywords, workflows: fixture.store)
                        .padding(28)
                }
                try await render(view, size: NSSize(width: 900, height: 1100),
                                 name: light ? "gul229-kw-list-light.png" : "gul229-kw-list.png", light: light)
            }
            let filtered = AskLauncherPluginSettingsView(settings: fixture.settings, workflows: fixture.store,
                                                         initialFilter: .web, initialQuery: "")
            try await render(filtered.padding(28), size: NSSize(width: 900, height: 560), name: "gul229-kw-filter.png")
            let empty = AskLauncherPluginSettingsView(settings: fixture.settings, workflows: fixture.store,
                                                      initialFilter: nil, initialQuery: "zzz")
            try await render(empty.padding(28), size: NSSize(width: 900, height: 400), name: "gul229-kw-empty.png")
        }
    }

    @Test func `keyword sheets`() async throws {
        try await chinese {
            let defaults = AskPluginRegistry.defaultKeywords
            let workflows = [AskWorkflowKeywordEntry(keyword: "wf", workflowID: "local.python",
                                                     workflowName: "Python · 输出文本", enabled: true)]
            let sheets: [(String, AskKeywordDraft)] = [
                ("prompt", AskKeywordDraft(editing: defaults[3])),
                ("translate", AskKeywordDraft(editing: defaults[0])),
                ("web", AskKeywordDraft(editing: defaults[6]))
            ]
            for (name, draft) in sheets {
                let sheet = AskKeywordEditorSheet(draft: draft, keywords: defaults, workflows: workflows,
                                                  onSave: { _ in }, onDelete: {}, onCancel: {})
                try await render(sheet, size: NSSize(width: 560, height: name == "prompt" ? 520 : 400),
                                 name: "gul229-kw-edit-\(name).png")
            }
            var clash = AskKeywordDraft(adding: .web)
            clash.keyword = "wf"
            clash.url = "https://example.com/search"
            let sheet = AskKeywordEditorSheet(draft: clash, keywords: defaults, workflows: workflows,
                                              onSave: { _ in }, onCancel: {})
            try await render(sheet, size: NSSize(width: 560, height: 420), name: "gul229-kw-add-problems.png")
            let menu = VStack(alignment: .leading, spacing: 2) {
                ForEach(AskKeywordKind.allCases, id: \.self) { kind in
                    AskKeywordMenuItem(kind: kind, title: kind.title) {}
                }
            }
            .padding(6)
            try await render(menu, size: NSSize(width: 300, height: 200), name: "gul229-kw-add-menu.png")
        }
    }

    @Test func `editor steps`() async throws {
        try await chinese {
            let fixture = try AskWorkflowFixture()
            let model = try editor(fixture)
            model.step = .keywords
            try await render(AskWorkflowEditorView(model: model, store: fixture.store), size: editorSize,
                             name: "gul229-ed-keywords.png")
            model.step = .input
            model.testQuery = "100 usd"
            try await render(AskWorkflowEditorView(model: model, store: fixture.store), size: editorSize,
                             name: "gul229-ed-input.png")
            try await render(AskWorkflowEditorView(model: model, store: fixture.store), size: editorSize,
                             name: "gul229-ed-input-light.png", light: true)
            model.testQuery = "hello world"
            model.step = .script
            model.selectedFile = "main.py"
            try await render(AskWorkflowEditorView(model: model, store: fixture.store, showsRunSettings: true),
                             size: editorSize, name: "gul229-ed-script.png")
            model.step = .output
            try await render(AskWorkflowEditorView(model: model, store: fixture.store), size: editorSize,
                             name: "gul229-ed-output.png")
            model.configMode = .json
            model.step = .keywords
            try await render(AskWorkflowEditorView(model: model, store: fixture.store), size: editorSize,
                             name: "gul229-ed-json.png")
        }
    }

    @Test func `failing test and assistant proposal`() async throws {
        try await chinese {
            var fixed = Self.script.replacingOccurrences(
                of: "print(f\"avg {len(text) / words:.1f} per word\")",
                with: "if words:\n    print(f\"avg {len(text) / words:.1f} per word\")"
            )
            fixed += ""
            let api = AskWorkflowScriptedAPI([
                .tool("workflow_propose", ["summary": "输入为空时 words 是 0，第 12 行会除零。空文本时只输出计数。",
                                           "manifest": manifest, "files": [["path": "main.py", "content": fixed]]]),
                .reply("改好了：空输入时跳过平均值。")
            ])
            let fixture = try AskWorkflowFixture()
            let model = try editor(fixture, api: api)
            model.step = .script
            model.selectedFile = "main.py"
            model.testQuery = ""
            model.runTest()
            await waitFor { !model.isTesting && !model.results.isEmpty }
            #expect(model.results.last?.succeeded == false)
            try await render(AskWorkflowEditorView(model: model, store: fixture.store, panel: .test), size: editorSize,
                             name: "gul229-ed-test.png")
            model.assistant.send("修复测试输入为空时的除零错误")
            await waitFor { !model.assistant.isBusy }
            try await render(AskWorkflowEditorView(model: model, store: fixture.store, panel: .assistant),
                             size: editorSize, name: "gul229-ed-ai.png")
            model.testQuery = "hello world"
            model.runTest()
            await waitFor { !model.isTesting && model.results.count > 1 }
            try await render(AskWorkflowEditorView(model: model, store: fixture.store, panel: .test), size: editorSize,
                             name: "gul229-ed-test-ok.png")
        }
    }

    /// The whole window as AppKit draws it, title bar and traffic lights included.
    private func capture(_ window: NSWindow, name: String) async throws {
        try await Task.sleep(for: .milliseconds(1200))
        let frame = try #require(window.contentView?.superview)
        frame.layoutSubtreeIfNeeded()
        guard let directory = ProcessInfo.processInfo.environment["TYPEFLUX_ASK_SNAPSHOTS"] else { return }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let bitmap = try #require(frame.bitmapImageRepForCachingDisplay(in: frame.bounds))
        frame.cacheDisplay(in: frame.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
    }

    @Test func `real windows`() async throws {
        try await chinese {
            _ = NSApplication.shared
            let fixture = try AskWorkflowFixture()
            try workflows(fixture)
            let defaults = try #require(UserDefaults(suiteName: "gul229-window-\(UUID().uuidString)"))
            let controller = AskWorkflowEditorWindowController(store: fixture.store, settings: fixture.settings)
            controller.assistantDependencies = {
                .init(api: AskWorkflowScriptedAPI([]), session: { ("owner", "token") }, deviceId: "device",
                      modelLibrary: AskModelLibrary(defaults: defaults, automaticallyLoadsCatalog: false),
                      defaults: defaults)
            }
            controller.show(workflowID: "local.python")
            let window = try #require(controller.window)
            let model = try #require(controller.model)
            defer { window.orderOut(nil) }
            #expect(window.styleMask.contains(.fullSizeContentView) && window.titlebarAppearsTransparent)
            #expect(window.titleVisibility == .hidden)
            window.appearance = NSAppearance(named: .darkAqua)
            window.setContentSize(editorSize)
            model.testQuery = "100 usd"
            for step in [AskWorkflowDraft.Step.keywords, .input, .script, .output] {
                model.step = step
                if step == .script {
                    model.selectedFile = "main.py"
                }
                try await capture(window, name: "gul229-window-ed-\(step.rawValue).png")
            }

            fixture.settings.appLanguage = AppLocalization.shared.language
            let viewModel = StudioViewModel(
                settingsStore: fixture.settings,
                historyStore: SQLiteHistoryStore(baseDir: fixture.home.appendingPathComponent("history")),
                initialSection: .launcher
            )
            // The settings window at its default size, sidebar and pane list included.
            try await render(StudioView(viewModel: viewModel, launcherPane: .keywords),
                             size: NSSize(width: StudioTheme.Layout.settingsWindowWidth,
                                          height: StudioTheme.Layout.settingsWindowHeight),
                             name: "gul229-studio-kw-list.png")
        }
    }
}
