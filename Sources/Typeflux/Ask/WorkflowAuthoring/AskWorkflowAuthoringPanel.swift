import SwiftUI

struct AskWorkflowAuthoringCard: View {
    @ObservedObject var session: AskWorkflowAuthoringSession
    var open: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "wand.and.stars").font(.title2).foregroundStyle(AskTheme.accent)
            VStack(alignment: .leading, spacing: 5) {
                Text(session.draft.manifest?.name ?? L("ask.workflow.chat.title")).font(.headline)
                Text(session.draft.manifest?.description ?? L("ask.workflow.chat.draft"))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            Button(L("ask.workflow.chat.try"), action: open).buttonStyle(.bordered)
        }
        .padding(16)
        .background(AskTheme.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 16))
        .accessibilityIdentifier("ask.workflow.card")
    }
}

struct AskWorkflowAuthoringPanel: View {
    @ObservedObject var session: AskWorkflowAuthoringSession
    var focusCloseOnAppear = false
    var close: () -> Void
    var discard: (() -> Void)?
    @State private var confirmsRun = false
    @State private var confirmsDiscard = false
    @State private var approvedRevision: UUID?
    @State private var showsCode = false
    @State private var path = AskWorkflowManifest.fileName
    @State private var testTask: Task<Void, Never>?
    @FocusState private var closeFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label(L("ask.workflow.chat.title"), systemImage: "wand.and.stars").font(.headline)
                Spacer()
                Button(action: close) { Image(systemName: "xmark") }
                    .buttonStyle(.plain).accessibilityLabel(L("ask.artifact.close"))
                    .accessibilityIdentifier("ask.workflow.close").focused($closeFocused)
            }.padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    introduction
                    input
                    HStack {
                        if session.isRunning {
                            ProgressView().controlSize(.small)
                            Button(L("ask.workflow.chat.cancel")) { testTask?.cancel(); session.cancel() }
                        } else {
                            Button(L("ask.workflow.chat.run")) {
                                approvedRevision = session.revision; confirmsRun = true
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(!session.problems.isEmpty)
                            .accessibilityIdentifier("ask.workflow.run")
                        }
                        Spacer()
                        if session.canUndo { Button(L("ask.workflow.chat.undo")) { session.undo() } }
                    }
                    if let preview = session.preview {
                        AskWorkflowLauncherPreview(name: preview.manifest.name,
                            keyword: preview.result.input.keyword ?? preview.manifest.keywords.first?.keyword ?? "",
                            query: preview.result.input.query, result: preview.result, output: preview.manifest.output,
                            timeout: preview.manifest.timeout, showsInput: false, folder: preview.folder)
                        if !preview.result.actionSteps.isEmpty {
                            Text(L("ask.workflow.chat.actionsPreview")).font(.caption).foregroundStyle(.secondary)
                            ForEach(Array(preview.result.actionSteps.enumerated()), id: \.offset) { _, step in
                                Label(step.title + ": " + step.detail, systemImage: step.symbol)
                                    .font(.caption).textSelection(.enabled)
                            }
                        }
                        if !preview.result.stderr.isEmpty {
                            DisclosureGroup(L("ask.workflow.chat.details")) {
                                Text(preview.result.stderr).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            }
                        }
                    } else {
                        Label(L("ask.workflow.chat.empty"), systemImage: "play.rectangle")
                            .foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 90)
                    }
                    ForEach(Array(session.problems.enumerated()), id: \.offset) { _, problem in
                        Text(problem).font(.caption).foregroundStyle(.red)
                    }
                    if let message = session.message { Text(message).font(.caption).textSelection(.enabled) }
                }.padding(20)
            }
            Divider()
            VStack(spacing: 10) {
                Button {
                    do { try session.save() } catch { session.message = error.localizedDescription }
                } label: {
                    Text(L(session.isDirty ? "ask.workflow.chat.save" : "ask.workflow.chat.saved"))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(session.isRunning || !session.problems.isEmpty || !session.isDirty)
                .accessibilityIdentifier("ask.workflow.save")
                Button(L("ask.workflow.chat.advanced")) { showsCode = true }
                    .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                if discard != nil {
                    Button(L("ask.workflow.chat.discard")) { confirmsDiscard = true }
                        .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                }
            }.padding(20)
        }
        .background(AskTheme.glassFill, in: RoundedRectangle(cornerRadius: 18))
        .padding(8)
        .confirmationDialog(L("ask.workflow.chat.runNotice"), isPresented: $confirmsRun, titleVisibility: .visible) {
            Button(L("ask.workflow.chat.run")) {
                guard approvedRevision == session.revision else { return }
                let input = AskWorkflowTestInput(query: session.query,
                    selection: session.selection.isEmpty ? nil : session.selection, keyword: session.keyword)
                testTask = Task { _ = await session.testLatestProposal([input]) }
            }
        } message: {
            Text(([L("ask.workflow.chat.actionsPreview")] + session.risks.sorted().map(\.title)).joined(separator: "\n"))
        }
        .sheet(isPresented: $showsCode) { codeEditor }
        .confirmationDialog(L("ask.workflow.chat.discardNotice"), isPresented: $confirmsDiscard) {
            Button(L("ask.workflow.chat.discard"), role: .destructive) { discard?() }
        }
        .onDisappear { testTask?.cancel(); session.cancel() }
        .onAppear { closeFocused = focusCloseOnAppear }
        .accessibilityIdentifier("ask.workflow.preview")
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(session.draft.manifest?.name ?? L("ask.workflow.chat.draft")).font(.title2.bold())
            Text(session.draft.manifest?.description ?? L("ask.workflow.chat.draft")).foregroundStyle(.secondary)
            Text(L(session.isDirty ? "ask.workflow.chat.draft" : "ask.workflow.chat.saved"))
                .font(.caption).padding(.horizontal, 9).padding(.vertical, 4)
                .background(AskTheme.accent.opacity(0.1), in: Capsule())
        }
    }

    private var input: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let keywords = session.draft.manifest?.keywords, !keywords.isEmpty {
                Picker(L("ask.workflow.chat.keyword"), selection: $session.keyword) {
                    ForEach(keywords, id: \.keyword) { Text($0.title ?? $0.keyword).tag($0.keyword) }
                }
            }
            Text(L("ask.workflow.chat.input")).font(.subheadline.bold())
            TextEditor(text: $session.query).font(.body).frame(minHeight: 100)
                .padding(8).background(.background, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(AskTheme.border))
                .accessibilityLabel(L("ask.workflow.chat.input"))
            if session.draft.manifest?.input.selection != .never {
                DisclosureGroup(L("ask.workflow.chat.selection")) {
                    TextEditor(text: $session.selection).frame(minHeight: 70)
                        .accessibilityLabel(L("ask.workflow.chat.selection"))
                }
            }
        }
    }

    /// Uses the workflow editor's syntax-aware native code component against the
    /// same draft. Closing returns to Chat without saving or making a second copy.
    private var codeEditor: some View {
        VStack(spacing: 12) {
            HStack {
                Picker(L("ask.workflow.chat.advanced"), selection: $path) {
                    ForEach(session.draft.paths, id: \.self) { Text($0).tag($0) }
                }
                Button(L("ask.workflow.chat.back")) { showsCode = false }
            }
            AskWorkflowCodeView(text: Binding(get: { session.draft.text(of: path) ?? "" },
                set: { session.edit(text: $0, path: path) }), language: .detect(path: path))
                .id(path)
            Text(L("ask.workflow.chat.editNotice")).font(.caption).foregroundStyle(.secondary)
        }.padding(20).frame(minWidth: 660, minHeight: 460)
    }
}
