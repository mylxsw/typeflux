import AppKit
import SwiftUI
import Testing
@testable import Typeflux

/// The approval card speaks in plain words: one question, the model's reason,
/// a few facts, and a colour that matches what the step can actually do.
@Suite("Ask approval copy", .exclusiveUIState)
@MainActor
struct AskApprovalCopyTests {
    private func call(_ name: String, _ args: [String: Any] = [:], id: String = "c") -> AskToolCall {
        let data = try! JSONSerialization.data(withJSONObject: args, options: .sortedKeys)
        return AskToolCall(id: id, function: .init(name: name, arguments: String(decoding: data, as: UTF8.self)))
    }

    private func title(_ call: AskToolCall, mcpServer: String? = nil,
                       fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> String {
        AskApprovalCopy.title(call, decision: AskApprovalCopy.decision(call, fileExists: fileExists), mcpServer: mcpServer)
    }

    private func fits<V: View>(_ view: V, width: CGFloat = 640) -> CGFloat {
        let hosting = NSHostingView(rootView: view.frame(width: width))
        hosting.layoutSubtreeIfNeeded()
        return hosting.fittingSize.height
    }

    private let checkCommand = #"cd ~/Downloads && awk '/<script>/{f=1;next} /<\/script>/{f=0} f' snake.html > /tmp/snake-check.js && node --check /tmp/snake-check.js && echo "JS_SYNTAX_OK" && wc -l snake.html"#

    // MARK: Question

    @Test func questionsNameTheActionAndItsObject() {
        let write = call("files", ["action": "write", "path": "~/Downloads/snake.html", "content": "x"])
        #expect(title(write, fileExists: { _ in false }) == L("ask.approval.q.create", "snake.html"))
        #expect(title(write, fileExists: { _ in true }) == L("ask.approval.q.overwrite", "snake.html"))
        let edit = call("project_files", ["action": "edit", "path": "src/a.swift"])
        #expect(title(edit) == L("ask.approval.q.edit", "a.swift"))
        #expect(title(call("run_command", ["command": "ls"])) == L("ask.approval.q.command"))
        #expect(title(call("run_code", ["language": "python", "code": "1"]))
            == L("ask.approval.q.code", "python"))
        #expect(title(call("run_code", ["code": "1"])) == L("ask.approval.q.codeGeneric"))
        #expect(title(call("computer", ["action": "screenshot"])) == L("ask.approval.q.screen"))
        let click = call("computer", ["action": "click"])
        #expect(title(click) == L("ask.approval.q.generic", AskTheme.toolTitle(click)))
        let mcp = call("mcp_delete_issue", ["id": "1"])
        #expect(title(mcp, mcpServer: "Linear")
            == L("ask.approval.q.generic", AskTheme.toolTitle(mcp, mcpServer: "Linear")))
        // A write without a path falls back to the tool's own name.
        let pathless = call("files", ["action": "write"])
        #expect(title(pathless) == L("ask.approval.q.generic", AskTheme.toolTitle(pathless)))
    }

    @Test func questionsReadNaturallyInChinese() {
        let previous = AppLocalization.shared.language
        AppLocalization.shared.setLanguage(.simplifiedChinese)
        defer { AppLocalization.shared.setLanguage(previous) }
        let write = call("files", ["action": "write", "path": "/tmp/snake.html"])
        #expect(title(write, fileExists: { _ in false }) == "创建 snake.html")
        #expect(title(call("computer", ["action": "screenshot"])) == "允许查看你的屏幕？")
        #expect(AskStepLimitPrompt.title(steps: 24) == "已运行 24 步，要继续吗？")
    }

    // MARK: Reason

    @Test func reasonIsOneShortParagraph() {
        #expect(AskApprovalCopy.reason(nil) == nil)
        #expect(AskApprovalCopy.reason("  \n ") == nil)
        #expect(AskApprovalCopy.reason("Write the file.\n\n  Then check it. ") == "Write the file. Then check it.")
        let long = String(repeating: "a", count: AskApprovalCopy.reasonLimit + 20)
        let clipped = AskApprovalCopy.reason(long)
        #expect(clipped?.count == AskApprovalCopy.reasonLimit + 1)
        #expect(clipped?.hasSuffix("…") == true)
    }

    @Test func reasonComesFromTheMessageThatMadeTheCall() {
        let target = call("files", ["action": "write"], id: "w")
        let other = call("run_command", ["command": "ls"], id: "o")
        let messages = [
            AskMessage(id: "u", role: "user", text: "make a game", createdAt: Date()),
            AskMessage(id: "a1", role: "assistant", text: "List first.", toolCalls: [other], createdAt: Date()),
            AskMessage(id: "a2", role: "assistant", text: "Now write the game file.", toolCalls: [target], createdAt: Date()),
        ]
        #expect(AskConversationView.approvalReason(target, messages: messages) == "Now write the game file.")
        let silent = [AskMessage(id: "a", role: "assistant", text: "", toolCalls: [target], createdAt: Date())]
        #expect(AskConversationView.approvalReason(target, messages: silent) == nil)
        #expect(AskConversationView.approvalReason(target, messages: []) == nil)
    }

    // MARK: Facts

    @Test func writeFactsSayWhereHowMuchAndWhetherItOverwrites() {
        let write = call("files", ["action": "write", "path": "/Users/me/Downloads/snake.html", "content": "a\nb\nc\n"])
        let facts = AskApprovalCopy.facts(write, risk: .write)
        #expect(facts == [
            .init(symbol: "folder", text: "/Users/me/Downloads/snake.html", revealPath: "/Users/me/Downloads/snake.html"),
            .init(symbol: "text.alignleft", text: L("ask.approval.fact.lines", 3)),
        ])
        #expect(AskApprovalCopy.decision(write, fileExists: { _ in false })?.allowLabel == L("ask.approval.allow.create"))
        #expect(AskApprovalCopy.decision(write, boundPath: "/resolved/snake.html", fileExists: { $0 == "/resolved/snake.html" }) == .overwrite)
    }

    @Test func editFactsCountChangedLines() {
        let edit = call("files", ["action": "edit", "path": "/a/b.txt", "old_text": "one\ntwo", "new_text": "uno"])
        let facts = AskApprovalCopy.facts(edit, risk: .write)
        #expect(facts.map(\.text) == ["/a/b.txt", L("ask.approval.fact.change", 1, 2)])
    }

    @Test func commandAndScreenFactsReplaceTechnicalTargets() {
        let check = call("run_command", ["command": checkCommand])
        #expect(AskApprovalCopy.facts(check, risk: .destructive, targetSummary: checkCommand)
            == [.init(symbol: "person", text: L("ask.approval.fact.account"))])
        let remove = call("run_command", ["command": "rm -rf build"])
        #expect(AskApprovalCopy.facts(remove, risk: .destructive).last
            == .init(symbol: "exclamationmark.octagon", text: L("ask.approval.fact.irreversible"), warning: true))
        let shot = call("computer", ["action": "screenshot"])
        #expect(AskApprovalCopy.facts(shot, risk: .read, targetSummary: "display:5")
            == [.init(symbol: "camera.viewfinder", text: L("ask.approval.fact.screenshot"))])
        let click = call("computer", ["action": "click"])
        #expect(AskApprovalCopy.facts(click, risk: .write, targetSummary: "display:5").isEmpty)
        #expect(AskApprovalCopy.facts(click, risk: .write, targetSummary: "com.apple.Safari / example.com").map(\.text)
            == ["com.apple.Safari / example.com"])
        #expect(AskApprovalCopy.facts(call("run_code", ["code": "1"]), risk: .write, targetSummary: "Python / abc").isEmpty)
        #expect(AskApprovalCopy.facts(call("memory", ["action": "remember"]), risk: .write, targetSummary: "Memory / me")
            .map(\.text) == ["Memory / me"])
        let longTarget = String(repeating: "x", count: 81)
        #expect(AskApprovalCopy.facts(call("memory"), risk: .write, targetSummary: longTarget).isEmpty)
    }

    @Test func factsAreCappedAtThree() {
        let write = call("files", ["action": "write", "path": "/a/b", "content": "x"])
        // The path and line count leave room for an irreversible warning.
        let facts = AskApprovalCopy.facts(write, risk: .destructive)
        #expect(facts.count == AskApprovalCopy.maxFacts)
    }

    @Test func locationsAndLineCounts() {
        #expect(AskApprovalCopy.location("/snake.html") == .init(symbol: "folder", text: "/snake.html", revealPath: "/snake.html"))
        #expect(AskApprovalCopy.location("notes.md") == .init(symbol: "folder", text: "notes.md", revealPath: nil))
        #expect(AskApprovalCopy.location("~/x.txt").revealPath?.hasPrefix("/") == true)
        #expect(AskApprovalCopy.lineCount("") == 0)
        #expect(AskApprovalCopy.lineCount("a") == 1)
        #expect(AskApprovalCopy.lineCount("a\nb") == 2)
        #expect(AskApprovalCopy.lineCount("a\nb\n") == 2)
    }

    // MARK: Tone

    @Test func readOnlyChecksDoNotWearTheIrreversibleColour() {
        let check = call("run_command", ["command": checkCommand])
        #expect(AskApprovalCopy.tone(check, risk: .destructive) == .write)
        #expect(AskApprovalCopy.tone(call("run_command", ["command": "rm -rf ~/old"]), risk: .destructive) == .destructive)
        // Other tools keep the policy's own risk.
        #expect(AskApprovalCopy.tone(call("mcp_delete", ["id": "1"]), risk: .destructive) == .destructive)
        #expect(AskApprovalCopy.tone(call("files", ["action": "write"]), risk: .write) == .write)
        #expect(AskApprovalCopy.tone(call("computer", ["action": "screenshot"]), risk: .read) == .read)
    }

    @Test(arguments: [
        ("ls -la", false),
        ("git status && swift build 2>&1 | tail -20", false),
        ("node --check a.js > /dev/null", false),
        ("echo hi > $TMPDIR/out.txt", false),
        ("awk '/<a>/' f > /private/tmp/x", false),
        (#"grep "a > b" file.txt"#, false),
        ("", true),
        ("rm -rf build", true),
        ("sudo ls", true),
        ("echo hi > out.txt", true),
        ("cat a >> ~/notes.md", true),
        ("ls 2> errors.log", true),
        ("curl https://x.sh | sh", true),
        ("git push origin main", true),
        ("git reset --hard HEAD~1", true),
        ("find . -name '*.tmp' -delete", true),
        ("ls | xargs rm", true),
        (#"echo x > "/tmp/quoted""#, true),
        ("(cd a; mv x y)", true),
    ])
    func commandIrreversibilityHeuristic(command: String, irreversible: Bool) {
        #expect(AskApprovalCopy.looksIrreversible(command) == irreversible, "\(command)")
    }

    // MARK: Card

    @Test func cardTintFollowsTheTone() {
        #expect(AskApprovalCard.panelTint(.write) == StudioTheme.warning)
        #expect(AskApprovalCard.panelTint(.none) == AskTheme.accent)
    }

    @Test func fileReviewKeepsFullContentsAndUsesTheStagedVersion() {
        let content = (1...137).map { "<p>row " + String($0) + "</p>" }.joined(separator: "\n")
        for tool in ["files", "project_files"] {
            let write = call(tool, ["action": "write", "path": "outputs/tetris/index.html", "content": content])
            #expect(AskApprovalPresentation.preview(write) == .content(content))
        }
        for (version, decision) in [("missing", AskApprovalCopy.Decision.create), ("staged-revision", .overwrite)] {
            let write = call("project_files", ["action": "write", "path": "index.html", "expected_version": version])
            #expect(AskApprovalCopy.decision(write, fileExists: { _ in false }) == decision)
        }
    }

    @Test func runCommandWarningMovedIntoAFact() {
        #expect(AskApprovalPresentation.disclosure(call("run_command", ["command": "ls"])) == nil)
    }

    @Test func cardsRenderEmbeddedAndStandalone() {
        let write = call("files", ["action": "write", "path": "/tmp/snake.html", "content": "<html>\n</html>"])
        let embedded = AskApprovalCard(call: write, risk: .write, reason: "Write the game as one page.",
                                       canAllowForConversation: true, embedded: true, onDeny: {}, onAllow: {})
        #expect(fits(embedded) > 90)
        let remove = AskApprovalCard(call: call("run_command", ["command": "rm -rf ~/old"]), risk: .destructive,
                                     onDeny: {}, onAllow: {})
        #expect(fits(remove) > 90)
        let check = AskApprovalCard(call: call("run_command", ["command": checkCommand]), risk: .destructive,
                                    targetSummary: checkCommand, onDeny: {}, onAllow: {})
        #expect(fits(check) < fits(remove))
        #expect(fits(embedded, width: 300) >= fits(embedded))
        let chip = AskApprovalFactLabel(fact: .init(symbol: "folder", text: "a / b", revealPath: "/a/b"))
        #expect(fits(chip, width: 200) > 0)
        #expect(fits(AskApprovalFactLabel(fact: .init(symbol: "x", text: "warn", warning: true)), width: 200) > 0)
    }

    @Test func compactCardsExposePreviewsAndRouteTheDecisionButtons() async throws {
        typealias UI = SettingsBehaviorTestSupport
        _ = NSApplication.shared
        let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previousAX = NSApp.accessibilityAttributeValue(enhanced)
        NSApp.accessibilitySetValue(true, forAttribute: enhanced)
        defer { NSApp.accessibilitySetValue(previousAX ?? false, forAttribute: enhanced) }
        let previous = AppLocalization.shared.language
        AppLocalization.shared.setLanguage(.simplifiedChinese)
        defer { AppLocalization.shared.setLanguage(previous) }
        let command = "cd /Users/mylxsw/Downloads && ls -la *.dmg *.ips"
        let path = "~/.typeflux/workspaces/4afd9883d299e189/20261122-37cfa1d7-3314-49e9-8852-46497b40e97d"
        let invocation = call("run_command", ["command": command])
        let pasteboard = NSPasteboard.withUniqueName()
        let previousPasteboard = AskQuickResults.pasteboard
        AskQuickResults.pasteboard = pasteboard
        defer {
            AskQuickResults.pasteboard = previousPasteboard
            pasteboard.releaseGlobally()
        }
        let script = (1...39).map { "# line " + String($0) }.joined(separator: "\n")
        var denied = false, allowed = false
        let run = AskApprovalCard(call: invocation, risk: .destructive,
                                  workingDirectory: path, reason: "读取仓库远程地址",
                                  onDeny: { denied = true }, onAllow: {})
        let file = AskApprovalCard(call: call("files", ["action": "write", "path": "outputs/clone-typeflux.sh",
                                                       "content": script]), risk: .write,
                                   onDeny: {}, onAllow: { allowed = true })
        let cards = VStack(spacing: 16) { run; file }.padding(18).background(AskTheme.surface)
        try await UI.withWindow(cards.environment(\.colorScheme, .dark), width: 640,
                                height: 640) { window, host in
            window.appearance = NSAppearance(named: .darkAqua)
            host.displayIfNeeded()
            #expect(UI.contains(command, in: host))
            #expect(!UI.contains(path, in: host))
            try UI.button(L("ask.approval.command.details"), in: host).press()
            try await UI.wait { UI.contains(path, in: host) }
            #expect(UI.contains(L("ask.approval.command.localAccount"), in: host))
            try UI.button(L("ask.copy"), in: host).press()
            try await UI.wait { pasteboard.string(forType: .string) == invocation.function.arguments }
            try UI.button(L("ask.approval.command.details"), in: host).press()
            try await UI.wait { !UI.contains(path, in: host) }
            #expect(UI.contains(command, in: host))
            #expect(UI.contains(script, in: host))
            try UI.button(L("ask.deny"), in: host).press()
            try UI.button(L("ask.approval.allow.create"), in: host).press()
            try await UI.wait { denied && allowed }
        }
    }

    @Test func approvalButtonsFitTheNarrowCardWithScopeSelection() async throws {
        typealias UI = SettingsBehaviorTestSupport
        try await UI.withFixture { _ in
            var granted = false
            let file = call("files", ["action": "write", "path": "index.html", "content": "<html></html>"])
            let card = AskApprovalCard(call: file, risk: .write, canAllowForConversation: true,
                                       onDeny: {}, onAllowForConversation: { granted = true }, onAllow: {})
            try await UI.withWindow(card.padding(.horizontal, 16), width: 360, height: 230) { window, host in
                let deny = try UI.button(L("ask.deny"), in: host)
                let allow = try UI.button(L("ask.approval.allowExact"), in: host)
                let scope = try UI.button(L("ask.approval.scope"), in: host)
                for button in [deny, allow, scope] {
                    #expect(window.frame.contains(button.frame))
                    #expect(button.frame.height >= 30)
                }
                #expect(deny.frame.maxX < allow.frame.minX)
                #expect(allow.frame.maxX < scope.frame.minX)
                try allow.press()
                try await UI.wait { granted }
            }
        }
    }

    @Test func pendingFileDecisionSurvivesFoldingTheConversation() async throws {
        typealias UI = SettingsBehaviorTestSupport
        try await UI.withFixture { _ in
            let fixture = try AskTestFixture(approvalReuseEnabled: true)
            defer { fixture.model.resetSession() }
            let lines = (1...137).map { "<p>" + String($0) + "</p>" }.joined(separator: "\n")
            await fixture.api.setTool(call("browser", ["action": "read"], id: "first"))
            await fixture.api.queueFollowUpTools([
                call("browser", ["action": "read"], id: "second"),
                call("files", ["action": "write", "path": "outputs/tetris/index.html", "content": lines], id: "create"),
            ])
            fixture.model.draft.text = "Build a game"
            fixture.model.submitDraft()
            try await fixture.wait { fixture.model.pendingApprovals.values.first?.id == "create" }
            let permission = L("ask.approval.allow.create")
            let id = try #require(fixture.model.selectedId)
            let auth = AuthState(loadStoredToken: { nil }, loadStoredRefreshToken: { nil }, loadStoredUserProfile: { nil })
            try await UI.withWindow(AskConversationView(model: fixture.model, auth: auth), width: 1020, height: 770) { _, host in
                try await UI.wait { UI.contains(permission, in: host) }
                let toggle = try #require(UI.elements(in: host).first {
                    $0.value("accessibilityIdentifier") as? String == "ask.turn.process"
                })
                try toggle.press()
                try await UI.wait {
                    UI.elements(in: host).contains {
                        $0.value("accessibilityIdentifier") as? String == "ask.turn.process"
                            && $0.text == L("ask.activity.collapsed")
                    }
                }
                let buttons = UI.elements(in: host).filter { $0.role == NSAccessibility.Role.button.rawValue }
                #expect(buttons.filter { $0.label == permission }.count == 1)
                #expect(buttons.filter { $0.label == L("ask.deny") }.count == 1)
                #expect(fixture.model.pendingApprovals[id]?.id == "create")
                try UI.button(permission, in: host).press()
                try await fixture.wait { fixture.model.pendingApprovals[id] == nil && fixture.model.busyIds.isEmpty }
                #expect(fixture.tools.executions == 3)
            }
        }
    }

    @Test func imageApprovalShowsDecodedPromptAndReadableFactsWithoutDuplicatePreview() {
        let prompt = "A newspaper front page.\n标题：深夜书店\n" + String(repeating: "Texture and typography. ", count: 150)
        let image = call("image_generate", ["prompt": prompt, "aspect_ratio": "9:16", "resolution": "2K", "model": "image:gpt-image-2"])
        #expect(title(image) == L("ask.approval.q.imageGenerate"))
        #expect(title(call("image_edit")) == L("ask.approval.q.imageEdit"))
        #expect(AskApprovalPresentation.preview(image) == .none)
        #expect(AskApprovalCopy.imagePrompt(image) == prompt)
        #expect(AskApprovalCopy.facts(image, risk: .write, targetSummary: "image_generate").map(\.text) == [
            L("ask.approval.image.ratio", "9:16"), L("ask.approval.image.resolution", "2K"),
            L("ask.approval.image.model", "GPT Image 2")])
        #expect(AskApprovalCopy.imageModelName("image:custom-model") == "custom-model")
        #expect(AskApprovalCopy.facts(call("image_generate", ["layout": "portrait"]), risk: .write).first?.text == L("imagegen.layout.portrait"))
        #expect(AskApprovalCopy.facts(call("image_generate"), risk: .write, targetSummary: "image_generate").isEmpty)
        #expect(AskApprovalCopy.imagePrompt(call("image_generate")) == nil)
    }

    @Test func commandApprovalRendersAtTranscriptAndNarrowWidths() throws {
        let previous = AppLocalization.shared.language
        AppLocalization.shared.setLanguage(.simplifiedChinese)
        defer { AppLocalization.shared.setLanguage(previous) }
        let command = call("run_command", ["command": "cd /Users/mylxsw/Downloads && ls -la *.dmg *.ips"])
        let card = AskApprovalCard(call: command, risk: .destructive,
                                   workingDirectory: "~/.typeflux/workspaces/4afd9883d299e189/20261122-37cfa1d7-3314-49e9-8852-46497b40e97d",
                                   onDeny: {}, onAllow: {})
        var open = card
        open.initiallyShowsDetails = true
        for width: CGFloat in [360, 718] {
            #expect(fits(card, width: width) < 155)
            #expect(fits(open, width: width) > fits(card, width: width) + 80)
            #expect(fits(open, width: width) < 375)
            for dark in [true, false] {
                for expanded in [true, false] {
                    let name = "command-\(Int(width))-\(dark ? "dark" : "light")-\(expanded ? "expanded" : "collapsed")"
                    let view = (expanded ? open : card).padding(18).frame(width: width)
                        .background(AskTheme.surface).environment(\.colorScheme, dark ? .dark : .light)
                    let host = NSHostingView(rootView: view)
                    host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    host.frame.size = host.fittingSize
                    try SettingsBehaviorTestSupport.snapshot(host, name: name)
                }
            }
        }
    }

    @Test func imageApprovalDetailsStayBoundedWithActionsBelowAndRenderInBothThemes() throws {
        let previous = AppLocalization.shared.language
        AppLocalization.shared.setLanguage(.simplifiedChinese)
        defer { AppLocalization.shared.setLanguage(previous) }
        let prompt = String(repeating: "旧报纸头版，纸张纹理与中文标题。\n", count: 300)
        let image = call("image_generate", ["prompt": prompt, "aspect_ratio": "9:16", "resolution": "2K", "model": "image:gpt-image-2"])
        var denied = false, allowed = false
        let closed = AskApprovalCard(call: image, risk: .write, reason: "生成一张旧报纸风格的书店海报。",
                                     onDeny: { denied = true }, onAllow: { allowed = true })
        var opened = closed
        opened.initiallyShowsDetails = true
        for width: CGFloat in [360, 640] {
            #expect(fits(opened, width: width) > fits(closed, width: width) + 200)
            #expect(fits(opened, width: width) < 600)
        }
        closed.onDeny(); closed.onAllow()
        #expect(denied && allowed)
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/image-approval-validation")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for dark in [true, false] {
            for expanded in [true, false] {
                let card = expanded ? opened : closed
                let host = NSHostingView(rootView: card.padding(20).frame(width: 640)
                    .background(AskTheme.surface).environment(\.colorScheme, dark ? .dark : .light))
                host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                host.frame = NSRect(x: 0, y: 0, width: 640, height: host.fittingSize.height)
                host.layoutSubtreeIfNeeded()
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let data = try #require(bitmap.representation(using: .png, properties: [:]))
                try data.write(to: root.appendingPathComponent("\(dark ? "dark" : "light")-\(expanded ? "expanded" : "collapsed").png"))
            }
        }
    }

    // MARK: Activity and step limit

    @Test func waitingCardTitleShowsPlanProgress() {
        #expect(AskActivity.attentionTitle(plan: nil) == L("ask.activity.attention"))
        #expect(AskActivity.attentionTitle(plan: []) == L("ask.activity.attention"))
        let plan = [AskPlanItem(step: "Write", status: "completed"), AskPlanItem(step: "Check", status: "in_progress"),
                    AskPlanItem(step: "Open", status: "pending")]
        #expect(AskActivity.attentionTitle(plan: plan) == L("ask.activity.plan", 1, 3))
    }

    @Test func exitCodesReadAsOutcomes() {
        #expect(AskToolStepRow.exitSummary("Exit code: 0") == L("ask.tool.exitSucceeded"))
        #expect(AskToolStepRow.exitSummary("Exit code: 2") == L("ask.tool.exitFailed", 2))
        #expect(AskToolStepRow.exitSummary("Exit code: x") == nil)
        #expect(AskToolStepRow.exitSummary("Done") == nil)
        let command = call("run_command", ["command": "ls"])
        let result = AskMessage(id: "r", role: "tool", text: "Exit code: 0\nfiles", createdAt: Date())
        #expect(AskToolStepRow.detail(command, result: result) == L("ask.tool.exitSucceeded"))
    }

    @Test func stepLimitPromptAsksWhetherToContinue() {
        var run = AskRun(id: "r", deviceId: "d", status: "failed", error: L("ask.local.stepLimit"), steps: 24,
                         updatedAt: Date(), tools: [], pending: [])
        #expect(AskStepLimitPrompt.applies(run))
        run.status = "cancelled"
        #expect(!AskStepLimitPrompt.applies(run))
        run.status = "failed"; run.error = "Network"
        #expect(!AskStepLimitPrompt.applies(run))
        #expect(AskStepLimitPrompt.title(steps: 0) == L("ask.stepLimit.title", 1))
        #expect(AskStepLimitPrompt.subtitle(plan: nil) == L("ask.stepLimit.hint"))
        #expect(AskStepLimitPrompt.subtitle(plan: [AskPlanItem(step: "Write", status: "completed")]) == L("ask.stepLimit.planDone"))
        let plan = [AskPlanItem(step: "Write", status: "completed"), AskPlanItem(step: "Check", status: "in_progress"),
                    AskPlanItem(step: "Open", status: "pending")]
        #expect(AskStepLimitPrompt.subtitle(plan: plan) == L("ask.stepLimit.remaining", 2, "Check"))
        var ended = false, continued = false
        let prompt = AskStepLimitPrompt(steps: 24, plan: plan, onEnd: { ended = true }, onContinue: { continued = true })
        #expect(fits(prompt) > 40)
        prompt.onEnd(); prompt.onContinue()
        #expect(ended && continued)
    }
}
