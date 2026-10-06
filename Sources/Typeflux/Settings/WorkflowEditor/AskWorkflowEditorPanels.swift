import SwiftUI

/// Test runs: the input, then what the launcher would show, stdout, stderr and
/// what the script received, and the recent runs.
struct AskWorkflowTestPanel: View {
    @ObservedObject var model: AskWorkflowEditorModel
    @ObservedObject var log: AskWorkflowLog = .shared
    var fix: () -> Void
    @State private var tab: Tab = .preview

    enum Tab: String, CaseIterable { case preview, stdout, stderr, received }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                let keywords = model.draft?.manifest?.keywords.map(\.keyword) ?? []
                HStack {
                    Text(L("ask.workflow.editor.test.input")).font(.system(size: 11))
                        .foregroundStyle(StudioTheme.textTertiary)
                    Spacer()
                    if keywords.count > 1 {
                        Picker(
                            "",
                            selection: Binding(
                                get: { model.testKeyword ?? keywords[0] },
                                set: { model.testKeyword = $0 }
                            )
                        ) {
                            ForEach(keywords, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden().fixedSize().controlSize(.small)
                    }
                }
                TextField(L("ask.workflow.editor.test.placeholder"), text: $model.testQuery)
                    .textFieldStyle(.roundedBorder).onSubmit { model.runTest() }
                    .accessibilityIdentifier("ask.workflow.editor.test.query")
                Toggle(L("ask.workflow.editor.test.withSelection"), isOn: $model.testUsesSelection)
                    .toggleStyle(.checkbox).font(.system(size: 12))
                if model.testUsesSelection {
                    TextEditor(text: $model.testSelection).font(.system(size: 12)).frame(height: 54)
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(StudioTheme.border))
                }
                HStack {
                    if model.isTesting {
                        ProgressView().controlSize(.small)
                        Button(L("ask.workflow.editor.test.stop")) { model.stopTest() }
                    } else {
                        Button { model.runTest() } label: { Label(
                            L("ask.workflow.editor.test.run"),
                            systemImage: "play.fill"
                        ) }
                        .buttonStyle(.borderedProminent).disabled(model.generation != nil)
                    }
                    Spacer()
                }
            }
            .padding(12)
            Divider()
            if let result = model.results.last {
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { Text(L("ask.workflow.editor.test.tab." + $0.rawValue)).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().padding(.horizontal, 12).padding(.top, 10)
                HStack(spacing: 6) {
                    Image(systemName: result.succeeded ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(result.succeeded ? StudioTheme.success : StudioTheme.danger)
                    Text(result.summary).font(.system(size: 11.5)).foregroundStyle(StudioTheme.textSecondary)
                    Spacer()
                    if !result.succeeded {
                        Button { fix() } label: { Label(L("ask.workflow.assistant.fix"), systemImage: "sparkles") }
                            .controlSize(.small)
                            .accessibilityIdentifier("ask.workflow.editor.fix")
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                ScrollView { detail(result).padding(.horizontal, 12).padding(.bottom, 12) }
            } else {
                Text(L("ask.workflow.editor.test.empty")).font(.system(size: 12))
                    .foregroundStyle(StudioTheme.textTertiary)
                    .padding(12)
                Spacer()
            }
            Divider()
            history
        }
    }

    @ViewBuilder private func detail(_ result: AskWorkflowTestResult) -> some View {
        switch tab {
        case .preview: AskWorkflowResultPreview(result: result, manifest: model.draft?.manifest)
        case .stdout: mono(result.stdout.isEmpty ? L("ask.workflow.editor.test.nothing") : result.stdout)
        case .stderr: mono(result.stderr.isEmpty ? L("ask.workflow.editor.test.nothing") : result.stderr)
        case .received:
            mono("argv  " + AskWorkflowAuthorTools.json(result.arguments) + "\n\nstdin " + result.stdin + "\n\n"
                + result.environment.keys.sorted().map { "\($0)=\(result.environment[$0] ?? "")" }
                .joined(separator: "\n"))
        }
    }

    private func mono(_ text: String) -> some View {
        Text(text).font(.system(size: 11.5, design: .monospaced)).textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading).padding(10)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(L("ask.workflow.editor.test.recent")).font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(StudioTheme.textTertiary)
            let entries = Array((log.entries[model.workflowID ?? ""] ?? []).prefix(5))
            if entries.isEmpty {
                Text("—").font(.system(size: 11.5)).foregroundStyle(StudioTheme.textTertiary)
            }
            ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                HStack(spacing: 6) {
                    Image(systemName: entry.exitCode == 0 && !entry.timedOut ? "checkmark" : "xmark")
                        .foregroundStyle(entry.exitCode == 0 && !entry.timedOut ? StudioTheme.success : StudioTheme
                            .danger)
                    Text(L(
                        entry
                            .source == .test ? "ask.workflow.editor.test.sourceTest" :
                            "ask.workflow.editor.test.sourceLauncher",
                        entry.keyword
                    )).lineLimit(1)
                    Spacer()
                    Text(String(format: "%.2f s", entry.duration)).foregroundStyle(StudioTheme.textTertiary)
                    Text(entry.date, style: .time).foregroundStyle(StudioTheme.textTertiary)
                }
                .font(.system(size: 11.5))
            }
        }
        .padding(12)
    }
}

/// A result as the launcher would show it: a text card, "the launcher closes", or the error.
struct AskWorkflowResultPreview: View {
    var result: AskWorkflowTestResult
    var manifest: AskWorkflowManifest?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(manifest?.name ?? "").font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(L("ask.workflow.editor.test.card")).font(.system(size: 11))
                    .foregroundStyle(StudioTheme.textTertiary)
            }
            if let failure = result.failure {
                Text(failure).foregroundStyle(StudioTheme.danger).font(.system(size: 12.5))
            } else if result.timedOut {
                Text(L("ask.workflow.timedOut", Int(manifest?.timeout ?? 0))).foregroundStyle(StudioTheme.danger)
            } else if result.exitCode != 0 {
                Text(AskWorkflowPlugin.errorMessage(in: result.stdout) ?? L(
                    "ask.workflow.failed",
                    Int(result.exitCode)
                ))
                .foregroundStyle(StudioTheme.danger).font(.system(size: 12.5))
                Text(AskWorkflowPlugin.tail(result.stderr).trimmingCharacters(in: .newlines))
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(StudioTheme.textSecondary)
            } else if manifest?.output == AskWorkflowManifest.Output.none
                || result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Label(L("ask.workflow.editor.test.dismisses"), systemImage: "checkmark.circle")
                    .foregroundStyle(StudioTheme.success)
            } else {
                Text(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)).font(.system(size: 13.5))
                    .textSelection(.enabled)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(StudioTheme.controlSurface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .strokeBorder(result.succeeded ? AskTheme.accent.opacity(0.5) : StudioTheme.danger.opacity(0.5)))
    }
}

/// The assistant: the conversation, proposal cards, the question before running
/// code with new risks, and the composer.
struct AskWorkflowAssistantPanel: View {
    @ObservedObject var model: AskWorkflowEditorModel
    @ObservedObject var assistant: AskWorkflowAssistant
    @State private var text = ""

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { reader in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if assistant.items.isEmpty {
                            Text(L("ask.workflow.assistant.empty")).font(.system(size: 12))
                                .foregroundStyle(StudioTheme.textTertiary)
                        }
                        ForEach(assistant.items) { item in itemView(item) }
                        if let run = model.pendingRun {
                            approval(run)
                        }
                        if assistant.isBusy {
                            HStack(alignment: .top, spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text(assistant.preview.isEmpty ? L("ask.workflow.assistant.working") : assistant
                                    .preview)
                                    .font(.system(size: 12)).foregroundStyle(StudioTheme.textSecondary).lineLimit(6)
                            }
                        }
                        if let error = assistant.error {
                            Text(error).font(.system(size: 12)).foregroundStyle(StudioTheme.danger)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(12)
                }
                .onChange(of: assistant.items.count) { _ in withAnimation { reader.scrollTo("bottom") } }
                .onChange(of: model.pendingRun) { _ in withAnimation { reader.scrollTo("bottom") } }
            }
            Divider()
            composer
        }
    }

    @ViewBuilder private func itemView(_ item: AskWorkflowAssistant.Item) -> some View {
        switch item {
        case let .user(_, text):
            HStack {
                Spacer(minLength: 30)
                Text(text).font(.system(size: 12.5)).textSelection(.enabled).padding(.horizontal, 10).padding(
                    .vertical,
                    7
                )
                .background(StudioTheme.accentSoft, in: RoundedRectangle(cornerRadius: 12))
            }
        case let .reply(_, text):
            Text((try? AttributedString(
                markdown: text,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            )) ?? AttributedString(text))
                .font(.system(size: 12.5)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        case let .tool(_, summary, failed):
            Label(summary, systemImage: failed ? "xmark.circle" : "checkmark.circle")
                .font(.system(size: 11.5)).foregroundStyle(failed ? StudioTheme.warning : StudioTheme.textSecondary)
        case let .proposal(id):
            if let proposal = model.proposal(id) {
                proposalCard(proposal)
            }
        case let .notice(_, text):
            Text(text).font(.system(size: 11.5)).foregroundStyle(StudioTheme.textTertiary)
        }
    }

    private func proposalCard(_ proposal: AskWorkflowProposal) -> some View {
        let changes = model.draft.map { proposal.changes(against: $0) } ?? []
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles").foregroundStyle(.purple)
                Text(L("ask.workflow.assistant.proposal")).font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(stateText(proposal)).font(.system(size: 11)).foregroundStyle(StudioTheme.textTertiary)
            }
            .padding(10)
            Divider()
            if !proposal.summary.isEmpty {
                Text(proposal.summary).font(.system(size: 12)).padding(10)
                Divider()
            }
            if proposal.state == .pending {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(changes, id: \.path) { change in
                        HStack(spacing: 6) {
                            Text(change.path).font(.system(size: 11.5, design: .monospaced))
                            Text("+\(change.added)").foregroundStyle(StudioTheme.success)
                            if change.removed > 0 {
                                Text("−\(change.removed)").foregroundStyle(StudioTheme.danger)
                            }
                        }
                        .font(.system(size: 11.5))
                    }
                }
                .padding(10)
                Divider()
            }
            if !proposal.risks.isEmpty {
                FlowChips(risks: proposal.risks.sorted(), new: proposal.newRisks).padding(10)
                Divider()
            }
            if proposal.state == .pending {
                HStack {
                    Spacer()
                    Button(L("ask.workflow.assistant.discard")) { model.discard(proposal.id) }
                    Button(L("ask.workflow.assistant.preview")) { model.previewingProposal = proposal.id }
                    Button(L("ask.workflow.assistant.apply")) { model.apply(proposal.id) }
                        .buttonStyle(.borderedProminent).tint(.purple)
                        .accessibilityIdentifier("ask.workflow.assistant.apply")
                }
                .controlSize(.small).padding(10)
            }
        }
        .background(StudioTheme.controlSurface, in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11)
            .strokeBorder(Color.purple.opacity(proposal.state == .pending ? 0.5 : 0.15)))
    }

    private func stateText(_ proposal: AskWorkflowProposal) -> String {
        switch proposal.state {
        case .applied: return L("ask.workflow.assistant.applied")
        case .discarded: return L("ask.workflow.assistant.discarded")
        case .pending:
            guard !proposal.tests.isEmpty else { return L("ask.workflow.assistant.untested") }
            return L(
                "ask.workflow.assistant.testedSummary",
                proposal.tests.filter(\.succeeded).count,
                proposal.tests.count
            )
        }
    }

    private func approval(_ run: AskWorkflowEditorModel.PendingRun) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(L("ask.workflow.assistant.approval.title"), systemImage: "exclamationmark.triangle")
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(StudioTheme.warning)
            if !run.risks.isEmpty {
                FlowChips(risks: run.risks, new: Set(run.risks))
            }
            Text(L("ask.workflow.assistant.approval.body")).font(.system(size: 11.5))
                .foregroundStyle(StudioTheme.textSecondary)
            HStack {
                Spacer()
                Button(L("ask.workflow.assistant.preview")) { model.previewingProposal = run.proposalID }
                Button(L("ask.workflow.assistant.approval.decline")) { model.resolvePendingRun(false) }
                Button(L("ask.workflow.assistant.approval.allow")) { model.resolvePendingRun(true) }
                    .buttonStyle(.borderedProminent).tint(.purple)
                    .accessibilityIdentifier("ask.workflow.assistant.allow")
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(StudioTheme.warning.opacity(0.08), in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(StudioTheme.warning.opacity(0.5)))
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextEditor(text: $text).font(.system(size: 12.5)).frame(height: 54)
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text(L("ask.workflow.assistant.placeholder")).font(.system(size: 12.5))
                            .foregroundStyle(StudioTheme.textTertiary).padding(.leading, 5).padding(.top, 1)
                            .allowsHitTesting(false)
                    }
                }
                .accessibilityIdentifier("ask.workflow.assistant.input")
            HStack(spacing: 8) {
                Toggle(L("ask.workflow.assistant.autoTest"), isOn: $model.autoTest).toggleStyle(.checkbox)
                    .font(.system(size: 11))
                    .help(L("ask.workflow.assistant.autoTest.help"))
                Spacer()
                Text(assistant.isLocal ? L("ask.workflow.assistant.local") : L("ask.workflow.assistant.cloud"))
                    .font(.system(size: 11)).foregroundStyle(StudioTheme.textTertiary)
                if assistant.isBusy {
                    Button { assistant.stop() } label: { Image(systemName: "stop.fill") }
                        .help(L("ask.workflow.assistant.stop"))
                } else {
                    Button {
                        assistant.send(text)
                        text = ""
                    } label: { Image(systemName: "arrow.up") }
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .help(L("ask.workflow.assistant.send"))
                }
            }
            Text(L("ask.workflow.assistant.privacy")).font(.system(size: 10.5))
                .foregroundStyle(StudioTheme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
    }
}

/// Risk tags, new ones highlighted.
struct FlowChips: View {
    var risks: [AskWorkflowRisk]
    var new: Set<AskWorkflowRisk>

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(risks, id: \.self) { risk in
                let isNew = new.contains(risk)
                Label(
                    risk.title,
                    systemImage: risk.kind == .network ? "network" : risk.isHigh ? "exclamationmark.shield" : "doc"
                )
                .font(.system(size: 11))
                .foregroundStyle(isNew ? Color.orange : StudioTheme.textSecondary)
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(
                    (isNew ? Color.orange : Color.gray).opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 6)
                )
            }
        }
    }
}
