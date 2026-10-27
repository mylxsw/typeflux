import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@Suite(.exclusiveUIState)
@MainActor
struct AskTurnProcessTests {
    private func message(_ id: String, role: String = "assistant", text: String = "Checking") -> AskMessage {
        .init(id: id, role: role, text: text, createdAt: .distantPast, runId: "run")
    }

    private func transcript(answer: Bool = true) -> [AskTranscriptItem] {
        let call = AskToolCall(
            id: "shell",
            function: .init(name: "run_command", arguments: #"{"command":"make test"}"#)
        )
        var step = message("step")
        step.toolCalls = [call]
        var messages = [message("user", role: "user"), step]
        if answer { messages.append(message("answer", text: "Fixed and verified.")) }
        return AskActivity.items(
            messages,
            results: [],
            fileChanges: ["step": [.init(path: "outputs/app.js", kind: .modified)]]
        )
    }

    @Test func `completed turn keeps its answer and files outside one process disclosure`() throws {
        let sections = AskTranscriptSection.make(transcript())
        #expect(sections.count == 4)
        #expect(sections.filter(\.isProcess).count == 1)
        let process = try #require(sections.first(where: { $0.isProcess }))
        #expect(process.hasConclusion)
        #expect(process.toolCount == 1)
        #expect(process.items.map(\.id) == ["step/progress", "step"])
        #expect(process.runIDs == ["run"])
        #expect(process.contains("step"))
        #expect(!process.contains("answer"))
        #expect(!process.contains(nil))
        #expect(sections.last?.isProcess == false)
        #expect(sections.last?.items.first?.id == "outcome-user")
    }

    @Test func `unfinished turns remain open and each question gets its own process`() {
        let unfinished = AskTranscriptSection.make(transcript(answer: false))
        #expect(unfinished.first(where: { $0.isProcess })?.hasConclusion == false)
        var second = transcript()
        second = second.map { item in
            var value = item
            if case var .message(message) = value.kind, message.role == "user" {
                message.id = "next-user"; value.kind = .message(message)
            }
            return value
        }
        let sections = AskTranscriptSection.make(transcript() + second)
        #expect(sections.filter(\.isProcess).count == 2)
        #expect(AskTranscriptSection.make([]).isEmpty)
        let plain = AskTranscriptSection.make([.init(kind: .message(message("plain")))])
        #expect(plain.count == 1 && !plain[0].isProcess)
    }

    @Test func `final reasoning and earlier narration fold without changing the answer or persisted messages`() {
        let narration = message("note", text: "Found the cause.")
        var final = message("answer", text: "The result.")
        final.reasoning = "Verify the fix."
        let sections = AskTranscriptSection.make([.init(kind: .message(narration)), .init(kind: .message(final))])
        #expect(sections.count == 2)
        #expect(sections[0].items.count == 2)
        #expect(sections[0].items.last?.viewID != sections[1].items.first?.viewID)
        guard case let .message(answer) = sections[1].items[0].kind else { Issue.record("Missing answer"); return }
        #expect(answer.text == final.text && answer.id == final.id && answer.reasoning == nil)
        #expect(final.reasoning == "Verify the fix.")
        let thought = AskTranscriptSection.make([.init(kind: .message(message("thought", text: "")))])
        #expect(thought[0].isProcess && !thought[0].hasConclusion)
    }

    @Test func `running process opens then completion folds and user can reopen it`() async throws {
        _ = NSApplication.shared
        NSApp.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
        defer { NSApp.accessibilitySetValue(false, forAttribute: .init(rawValue: "AXEnhancedUserInterface")) }
        let section = try #require(AskTranscriptSection.make(transcript()).first(where: { $0.isProcess }))
        let state = ProcessState()
        let host = NSHostingView(rootView: ProcessScene(state: state, section: section))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 650, height: 400), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        func settle() async throws {
            try await Task.sleep(for: .milliseconds(100))
            host.layoutSubtreeIfNeeded()
        }
        func objects() -> [NSObject] {
            var seen = Set<ObjectIdentifier>()
            func walk(_ object: NSObject) -> [NSObject] {
                guard seen.insert(ObjectIdentifier(object)).inserted else { return [] }
                let children = object.responds(to: NSSelectorFromString("accessibilityChildren"))
                    ? object.value(forKey: "accessibilityChildren") as? [NSObject] ?? [] : []
                return [object] + children.flatMap(walk)
            }
            return walk(host)
        }
        func hasDetail() -> Bool {
            objects().contains { object in
                ["accessibilityLabel", "accessibilityValue", "accessibilityTitle"].contains { key in
                    object.responds(to: NSSelectorFromString(key))
                        && (object.value(forKey: key) as? String)?.contains("Process detail") == true
                }
            }
        }
        try await settle()
        #expect(hasDetail())
        state.active = false
        try await settle()
        #expect(!hasDetail())
        let toggle = try #require(objects().first { object in
            object.responds(to: NSSelectorFromString("accessibilityIdentifier"))
                && object.value(forKey: "accessibilityIdentifier") as? String == "ask.turn.process"
        })
        #expect(toggle.responds(to: NSSelectorFromString("accessibilityPerformPress")))
        toggle.perform(NSSelectorFromString("accessibilityPerformPress"))
        try await settle()
        #expect(hasDetail())
    }

    @Test func streamingTextAndToolPreamblesShareOneStableProcessIdentity() throws {
        let text = message("live")
        let before = AskTranscriptSection.make([.init(kind: .message(text))], activeRunID: "run", activeMessageID: text.id)
        var step = text
        step.toolCalls = [.init(id: "call", function: .init(name: "files", arguments: "{}"))]
        let after = AskTranscriptSection.make(AskActivity.items([step], results: []), activeRunID: "run", activeMessageID: text.id)
        #expect(before.first?.id == after.first?.id)
        #expect(before.first?.isProcess == true)
        #expect(before.first?.hasConclusion == false)
        #expect(before.first?.items.first?.viewID == after.first?.items.first?.viewID)
    }

    @Test func conversationKeepsItsConclusionVisibleAndCanLocateFoldedSteps() async throws {
        let fixture = try AskTestFixture()
        defer { fixture.model.resetSession() }
        let call = AskToolCall(id: "command", function: .init(name: "run_command", arguments: #"{"command":"git diff --check"}"#))
        let conversation = AskConversation(id: "process-chat", title: "Process", revision: 1, updatedAt: .distantPast,
            messages: [
                message("question", role: "user", text: "Fix the issue"),
                .init(id: "step", role: "assistant", text: "Inspecting the current files.", toolCalls: [call],
                      createdAt: .distantPast, runId: "run"),
                .init(id: "receipt", role: "tool", text: "Exit code: 0", toolCallId: call.id, createdAt: .distantPast),
                message("answer", text: "Fixed and verified.")
            ])
        await fixture.api.seed(conversation)
        await fixture.model.select(conversation.id)
        let host = NSHostingView(rootView: AskConversationView(model: fixture.model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 750), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        try await Task.sleep(for: .milliseconds(350))
        host.layoutSubtreeIfNeeded()
        fixture.model.locateReference("step")
        #expect(fixture.model.highlightedMessageId == "step")
        try await Task.sleep(for: .milliseconds(200))
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        #expect(data.count > 10000)
        try data.write(to: URL(fileURLWithPath: "/tmp/typeflux-turn-process-conversation.png"))
    }

    @Test func `completed and running layouts render with compact file rows in both themes`() async throws {
        var section = try #require(AskTranscriptSection.make(transcript()).first(where: { $0.isProcess }))
        if case var .activity(group) = section.items[1].kind {
            var second = group.messages[0].toolCalls![0]
            second.id = "second-command"
            group.messages[0].toolCalls?.append(second)
            section.items[1].kind = .activity(group)
        }
        let directory = URL(fileURLWithPath: "/tmp/typeflux-turn-process-snapshots")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            for active in [false, true] {
                let scene = VStack(alignment: .leading, spacing: 12) {
                    AskTurnProcessView(section: section, active: active) { _ in
                        VStack(alignment: .leading, spacing: 6) {
                            Text("我会检查当前文件，再验证修改。")
                            AskActivityBlock(group: .init(id: "batch", messages: [
                                .init(id: "batch", role: "assistant", text: "", toolCalls: [
                                    .init(
                                        id: "one",
                                        function: .init(
                                            name: "run_command",
                                            arguments: #"{"command":"git diff --check"}"#
                                        )
                                    ),
                                    .init(
                                        id: "two",
                                        function: .init(
                                            name: "run_command",
                                            arguments: #"{"command":"make test SUITE=AskTurnProcessTests"}"#
                                        )
                                    )
                                ], createdAt: .distantPast)
                            ]), results: [], plan: nil, status: .done, startsExpanded: true)
                        }
                    }
                    Text("已修复并验证。展开处理过程可以查看每条命令。")
                    AskFileChangesView(list: .init(changes: [
                        .init(path: "outputs/app.js", kind: .modified), .init(path: "outputs/index.html", kind: .added)
                    ]), actions: .init())
                }
                .padding(24).frame(width: 640, height: 350, alignment: .topLeading).background(AskTheme.surface)
                try await AskConversationVisualTests().render(scene, size: NSSize(width: 640, height: 350),
                                                              appearance: appearance,
                                                              file: directory
                                                                  .appendingPathComponent("\(name)-\(active).png"),
                                                              minimumPNGBytes: 3000)
            }
        }
    }
}

@MainActor private final class ProcessState: ObservableObject {
    @Published var active = true
}

private struct ProcessScene: View {
    @ObservedObject var state: ProcessState
    let section: AskTranscriptSection
    var body: some View {
        VStack {
            AskTurnProcessView(section: section, active: state.active) { _ in Text("Process detail") }
            Text("Final answer")
        }
    }
}
