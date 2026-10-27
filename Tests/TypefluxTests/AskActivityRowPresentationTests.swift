import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@Suite("Quiet activity rows", .exclusiveUIState)
@MainActor struct AskActivityRowPresentationTests {
    private func call(_ name: String, _ arguments: String, id: String = "call") -> AskToolCall {
        .init(id: id, function: .init(name: name, arguments: arguments))
    }

    @Test func reasoningPreviewUsesContentWithoutLabelsOrLineBreaks() {
        #expect(AskReasoningText.preview("  先检查文件。\n\n再验证修改。\t继续。 ") == "先检查文件。 再验证修改。 继续。")
        #expect(AskReasoningText.preview("") == "")
        #expect(AskReasoningText.preview(" \n\t") == "")
        #expect(AskReasoningText.preview(String(repeating: "长", count: 10000)).count == 600)
        #expect(AskReasoningText.preview("**Inspect** the `file`.") == "**Inspect** the `file`.")
    }

    @Test func commandsShowTheirActualCommandAndFilesShowTheirPathOnce() {
        let command = call("run_command", #"{"command":"pwd; rg --files","timeout":30}"#)
        #expect(AskActivityRowPresentation.command(command) == "pwd; rg --files")
        #expect(AskActivityRowPresentation.title(command).hasSuffix("pwd; rg --files"))
        let read = call("files", #"{"action":"read","path":"work/site/style.css"}"#)
        let title = AskActivityRowPresentation.title(read)
        #expect(title.components(separatedBy: "style.css").count == 2)
        #expect(title.hasSuffix("work/site/style.css"))
        #expect(AskActivityRowPresentation.command(read) == nil)
        #expect(AskActivityRowPresentation.command(call("run_command", "invalid")) == nil)
        #expect(AskActivityRowPresentation.command(call("command_job", #"{"action":"status"}"#)) == nil)
        #expect(AskActivityRowPresentation.command(call("command_job", #"{"action":"start","command":"make test"}"#)) == "make test")
        #expect(AskActivityRowPresentation.title(call("files", #"{"action":"search","query":"TODO","path":"work/"}"#)).contains("TODO work/"))
        #expect(!AskActivityRowPresentation.title(call("browser", "{}")).isEmpty)
        let long = String(repeating: "x", count: 10000)
        #expect(AskActivityRowPresentation.title(call("run_command", "{\"command\":\"\(long)\"}")).count < 400)
    }

    @Test func narrationSplitsToolGroupsWithoutLosingReasoningOrStableOutputOwnership() throws {
        let now = Date()
        let first = AskMessage(id: "a", role: "assistant", text: "I will inspect the files.",
                               toolCalls: [call("files", #"{"action":"read","path":"work/a"}"#)], createdAt: now,
                               reasoning: "Private process detail", runId: "run")
        let next = AskMessage(id: "b", role: "assistant", text: "Found the issue.",
                              toolCalls: [call("run_command", #"{"command":"make test"}"#, id: "test")], createdAt: now)
        let changes = ["a": [AskWorkspaceFileChange(path: "work/a", kind: .modified)]]
        let rows = AskActivity.items([first, next], results: [], fileChanges: changes)
        #expect(rows.map(\.id) == ["a/progress", "a", "b/progress", "b", "outcome-run"])
        #expect(rows[0].isProgress)
        guard case let .message(note) = rows[0].kind, case let .activity(group) = rows[1].kind else {
            Issue.record("Expected narration followed by a tool group"); return
        }
        #expect(note.id == first.id, "References must use the persisted message ID, not the visual row ID")
        #expect(note.text == first.text && note.reasoning == nil && note.toolCalls == nil)
        #expect(group.messages[0].text.isEmpty)
        #expect(group.messages[0].reasoning == first.reasoning)
        #expect(group.calls == first.toolCalls)
        #expect(AskActivityRowPresentation.groupTitle(group) == AskActivity.Category.files.title)
        #expect(!AskActivityRowPresentation.groupTitle(.init(id: "empty", messages: [])).isEmpty)
        let repeated = AskActivityGroup(id: "mixed", messages: [first, first, next])
        #expect(AskActivityRowPresentation.groupTitle(repeated) == AskActivity.Category.files.title + " · " + AskActivity.Category.code.title)
    }

    @Test func renderCompactAndExpandedTracesInBothThemes() async throws {
        let previous = AppLocalization.shared.language
        AppLocalization.shared.setLanguage(.simplifiedChinese)
        defer { AppLocalization.shared.setLanguage(previous) }
        let read = call("files", #"{"action":"read","path":"Sources/AskActivityViews.swift"}"#, id: "read")
        let command = call("run_command", #"{"command":"rg -n 'spacing' Sources/AskActivityViews.swift"}"#)
        let now = Date()
        let group = AskActivityGroup(id: "trace", messages: [
            AskMessage(id: "a", role: "assistant", text: "", toolCalls: [read, command], createdAt: now)
        ])
        let result = AskMessage(id: "r", role: "tool", text: "Exit code: 0\n182: VStack(alignment: .leading, spacing: 8)\n241: HStack(spacing: 6)",
                                toolCallId: command.id, createdAt: now)
        let directory = URL(fileURLWithPath: "/tmp/typeflux-activity-row-snapshots")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            for expanded in [false, true] {
                let scene = VStack(alignment: .leading, spacing: 24) {
                    Text("我会检查聊天内容的间距，把说明和工具调用分开显示。")
                        .font(.system(size: 14)).foregroundStyle(StudioTheme.textPrimary)
                    AskReasoningView(text: "先检查页面结构与脚本引用，确认现有实现。\n然后修复选择器并验证导航、筛选和表单。", milliseconds: 3000,
                                     active: false, startsExpanded: expanded)
                    AskReasoningView(text: String(repeating: "正在检查文件引用和页面结构。", count: 30), milliseconds: 0,
                                     active: true, startsExpanded: expanded)
                    AskActivityBlock(group: group, results: [result], plan: nil, status: .done)
                    if expanded {
                        VStack(alignment: .leading, spacing: 8) {
                            AskToolStepRow(call: read, result: AskMessage(id: "read-result", role: "tool", text: "File contents",
                                                                        toolCallId: read.id, createdAt: now))
                            AskToolStepRow(call: command, result: result, startsExpanded: true)
                        }
                    }
                    Text("已找到问题，接下来验证窄窗口与长命令的显示效果。")
                        .font(.system(size: 14)).foregroundStyle(StudioTheme.textPrimary)
                    Spacer(minLength: 0)
                }
                .padding(24).frame(maxWidth: .infinity, alignment: .leading).background(AskTheme.surface)
                try await AskConversationVisualTests().render(scene, size: NSSize(width: 640, height: 620),
                    appearance: appearance, file: directory.appendingPathComponent("\(name)-\(expanded ? "expanded" : "compact").png"), minimumPNGBytes: 4000)
            }
        }
    }
}
