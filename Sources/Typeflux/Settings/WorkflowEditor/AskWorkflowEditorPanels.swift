// swiftlint:disable file_length
import SwiftUI

/// Test runs: the input, then what the launcher would show, stdout, stderr and
/// what the script received, and the recent runs.
struct AskWorkflowTestPanel: View {
    @Environment(\.interfaceStyle) private var interfaceStyle

    @ObservedObject var model: AskWorkflowEditorModel
    @ObservedObject var log: AskWorkflowLog = .shared
    var fix: () -> Void
    @State private var tab: Tab = .preview

    enum Tab: String, CaseIterable { case preview, stdout, stderr, actions, received }

    init(model: AskWorkflowEditorModel, tab: Tab = .preview, fix: @escaping () -> Void) {
        self.model = model
        self.fix = fix
        _tab = State(initialValue: tab)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            input
            if let result = model.results.last {
                meta(result)
                AskWorkflowTabs(items: Tab.allCases.map { tab in
                    .init(tab: tab, title: title(tab, result), badge: badge(tab, result))
                }, selection: $tab)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.bottom, 10)
                ScrollView { detail(result).padding(.horizontal, 12).padding(.bottom, 12) }
            } else {
                Text(L("ask.workflow.editor.test.empty")).font(.system(.callout))
                    .foregroundStyle(TypefluxColor.tertiaryLabel.color).padding(.horizontal, 14).padding(.vertical, 6)
                Spacer()
            }
            Rectangle().fill(TypefluxColor.separator.color).frame(height: 1)
            history
        }
    }

    // MARK: - Input

    private var input: some View {
        VStack(alignment: .leading, spacing: 8) {
            let keywords = model.draft?.manifest?.keywords.map(\.keyword) ?? []
            HStack(spacing: 6) {
                if keywords.count > 1 {
                    Menu {
                        ForEach(keywords, id: \.self) { keyword in Button(keyword) { model.testKeyword = keyword } }
                    } label: {
                        AskWorkflowChip(text: (model.testKeyword ?? keywords[0]) + " ▾")
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help(L("ask.workflow.editor.test.inputBefore"))
                } else if let keyword = keywords.first {
                    AskWorkflowChip(text: keyword)
                }
                TextField(L("ask.workflow.editor.test.placeholder"), text: $model.testQuery)
                    .textFieldStyle(.plain).font(.system(.body, design: .monospaced))
                    .onSubmit { model.runTest() }
                    .accessibilityIdentifier("ask.workflow.editor.test.query")
                if model.isTesting {
                    Button(L("ask.workflow.editor.test.stop")) { model.stopTest() }
                        .buttonStyle(.bordered).controlSize(.small)
                } else {
                    Button { model.runTest() } label: {
                        Label(L("ask.workflow.editor.test.go"), systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                    .disabled(!model.problems.isEmpty)
                }
            }
            .padding(.leading, 8).padding(.trailing, 4).frame(height: 34)
            .background(
                TypefluxColor.controlBackground.color,
                in: RoundedRectangle(cornerRadius: TypefluxRadius.form.value(for: interfaceStyle), style: .continuous)
            )
            .overlay(RoundedRectangle(cornerRadius: TypefluxRadius.form.value(for: interfaceStyle), style: .continuous)
                .strokeBorder(TypefluxColor.separator.color))
            Toggle(L("ask.workflow.editor.test.previewActions"), isOn: $model.previewActionsOnly)
                .toggleStyle(.checkbox).font(.system(.callout)).foregroundStyle(TypefluxColor.secondaryLabel.color)
                .accessibilityIdentifier("ask.workflow.editor.test.previewActions")
            Toggle(L("ask.workflow.editor.test.withSelection"), isOn: $model.testUsesSelection)
                .toggleStyle(.checkbox).font(.system(.callout)).foregroundStyle(TypefluxColor.secondaryLabel.color)
            if model.testUsesSelection {
                TextEditor(text: $model.testSelection).font(.system(.callout)).frame(height: 54)
                    .scrollContentBackground(.hidden).padding(4)
                    .background(
                        TypefluxColor.controlBackground.color,
                        in: RoundedRectangle(cornerRadius: TypefluxRadius.navigationIcon.value(for: interfaceStyle))
                    )
                    .overlay(RoundedRectangle(cornerRadius: TypefluxRadius.navigationIcon.value(for: interfaceStyle))
                        .strokeBorder(TypefluxColor.separator.color))
            }
            if model.isTesting {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    TimelineView(.periodic(from: .now, by: 0.1)) { context in
                        Text(L("ask.workflow.editor.test.running",
                               context.date.timeIntervalSince(model.testStartedAt ?? context.date)))
                            .font(.system(.subheadline)).foregroundStyle(TypefluxColor.secondaryLabel.color)
                            .monospacedDigit()
                    }
                }
            }
        }
        .padding(.horizontal, 12).padding(.bottom, 12)
    }

    // MARK: - Result

    private func meta(_ result: AskWorkflowTestResult) -> some View {
        HStack(spacing: 6) {
            Image(systemName: result.succeeded ? "checkmark" : "xmark").font(.system(.footnote, weight: .bold))
            Text(result.summary)
            if result.succeeded, !result.stdout.isEmpty {
                Text("· " + L("ask.workflow.editor.test.lines",
                              result.stdout.trimmingCharacters(in: .newlines).split(separator: "\n").count))
            }
            Spacer()
            if !result.succeeded {
                Button { fix() } label: { Label(L("ask.workflow.assistant.fix"), systemImage: "sparkles") }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                    .accessibilityIdentifier("ask.workflow.editor.fix")
            } else {
                Text(AskWorkflowEditorModel.relative(result.date)).foregroundStyle(TypefluxColor.tertiaryLabel.color)
            }
        }
        .font(.system(.callout))
        .foregroundStyle(result.succeeded ? TypefluxColor.success.color : TypefluxColor.danger.color)
        .padding(.horizontal, 10).frame(minHeight: 34)
        .background((result.succeeded ? TypefluxColor.success.color : TypefluxColor.danger.color).opacity(0.09),
                    in: RoundedRectangle(
                        cornerRadius: TypefluxRadius.form.value(for: interfaceStyle),
                        style: .continuous
                    ))
        .padding(.horizontal, 12).padding(.bottom, 10)
    }

    @ViewBuilder private func detail(_ result: AskWorkflowTestResult) -> some View {
        let manifest = model.draft?.manifest
        switch tab {
        case .preview:
            VStack(alignment: .leading, spacing: 12) {
                preview(result, input: true)
                if !result.actionSteps.isEmpty {
                    AskWorkflowTestActions(result: result)
                }
            }
        case .actions:
            AskWorkflowTestActions(result: result)
        case .stdout:
            mono(result.stdout.isEmpty ? L("ask.workflow.editor.test.nothing") : result.stdout)
        case .stderr:
            VStack(alignment: .leading, spacing: 10) {
                stderrLog(result.stderr)
                if !result.succeeded, manifest != nil {
                    Text(L("ask.workflow.editor.test.launcherShows")).font(.system(.subheadline))
                        .foregroundStyle(TypefluxColor.tertiaryLabel.color)
                    preview(result, input: false)
                }
            }
        case .received:
            mono("argv  " + AskWorkflowAuthorTools.json(result.arguments) + "\n\nstdin " + result.stdin + "\n\n"
                + result.environment.keys.sorted().map { "\($0)=\(result.environment[$0] ?? "")" }
                .joined(separator: "\n"))
        }
    }

    private func preview(_ result: AskWorkflowTestResult, input: Bool) -> some View {
        let manifest = model.draft?.manifest
        return AskWorkflowLauncherPreview(
            name: manifest?.name ?? "", keyword: result.input.keyword ?? manifest?.keywords.first?.keyword ?? "",
            query: result.input.query, result: result, output: manifest?.output ?? .init(display: .text),
            timeout: manifest?.timeout ?? AskWorkflowManifest.defaultTimeout, showsInput: input, folder: model.folder
        )
    }

    /// stderr, with each line that points into the workflow a link to that line.
    private func stderrLog(_ stderr: String) -> some View {
        let files = Set(model.draft?.files.keys.map(\.self) ?? [])
        let folder = model.folder ?? model.draft?.folder ?? URL(fileURLWithPath: "/")
        return VStack(alignment: .leading, spacing: 0) {
            if stderr.isEmpty {
                Text(L("ask.workflow.editor.test.nothing"))
            }
            ForEach(Array(stderr.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                if let location = AskWorkflowStderrLocator.locate(line, folder: folder, files: files) {
                    Button {
                        model.step = .script
                        model.selectedFile = location.path
                        model.reveal = (location.path, location.line)
                    } label: {
                        Text(AskWorkflowPlugin.relative(line, to: folder)).underline()
                            .foregroundStyle(TypefluxColor.accent.color)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                } else {
                    Text(line.isEmpty ? " " : AskWorkflowPlugin.relative(line, to: folder))
                        .foregroundStyle(line.contains("Error") || line.contains("error")
                            ? TypefluxColor.danger.color : TypefluxColor.secondaryLabel.color)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .font(.system(.subheadline, design: .monospaced)).textSelection(.enabled)
        .padding(10)
        .background(
            Color(nsColor: .textBackgroundColor).opacity(0.55),
            in: RoundedRectangle(cornerRadius: TypefluxRadius.form.value(for: interfaceStyle))
        )
        .overlay(RoundedRectangle(cornerRadius: TypefluxRadius.form.value(for: interfaceStyle))
            .strokeBorder(TypefluxColor.separator.color))
    }

    private func mono(_ text: String) -> some View {
        Text(text).font(.system(.subheadline, design: .monospaced)).textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading).padding(10)
            .background(
                Color(nsColor: .textBackgroundColor).opacity(0.55),
                in: RoundedRectangle(cornerRadius: TypefluxRadius.form.value(for: interfaceStyle))
            )
            .overlay(RoundedRectangle(cornerRadius: TypefluxRadius.form.value(for: interfaceStyle))
                .strokeBorder(TypefluxColor.separator.color))
    }

    /// "Actions 2": how many actions this run has.
    private func title(_ tab: Tab, _ result: AskWorkflowTestResult) -> String {
        let title = L("ask.workflow.editor.test.tab." + tab.rawValue)
        return tab == .actions && !result.actionSteps.isEmpty ? title + " \(result.actionSteps.count)" : title
    }

    /// stderr's line count after a failure.
    private func badge(_ tab: Tab, _ result: AskWorkflowTestResult) -> String? {
        tab == .stderr && !result.succeeded && !result.stderr.isEmpty
            ? "\(result.stderr.split(separator: "\n").count)" : nil
    }

    // MARK: - History

    private var history: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L("ask.workflow.editor.test.recent")).font(.system(.subheadline, weight: .semibold))
                .foregroundStyle(TypefluxColor.tertiaryLabel.color)
            let items = model.history
            if items.isEmpty {
                Text("—").font(.system(.subheadline)).foregroundStyle(TypefluxColor.tertiaryLabel.color)
            }
            ForEach(items) { item in
                HStack(spacing: 8) {
                    Image(systemName: item.succeeded ? "checkmark" : "xmark")
                        .font(.system(.footnote, weight: .bold))
                        .foregroundStyle(item.succeeded ? TypefluxColor.success.color : TypefluxColor.danger.color)
                        .frame(width: 12)
                    Text(item.title).lineLimit(1)
                    Spacer()
                    Text(String(format: "%.2f s", item.duration)).foregroundStyle(TypefluxColor.tertiaryLabel.color)
                        .monospacedDigit()
                    Text(AskWorkflowEditorModel.relative(item.date)).foregroundStyle(TypefluxColor.tertiaryLabel.color)
                }
                .font(.system(.subheadline))
            }
        }
        .padding(12)
        .id(log.entries.count)
    }
}

/// A test run's actions: each with its filled-in value and where it ended
/// (previewed, done, skipped, failed), and `{json.…}` placeholders that found nothing.
struct AskWorkflowTestActions: View {
    var result: AskWorkflowTestResult

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L(result.takesFailureActions ? "ask.workflow.editor.test.failureActions"
                    : "ask.workflow.editor.test.actions"))
                .font(.system(.subheadline, weight: .semibold)).foregroundStyle(TypefluxColor.tertiaryLabel.color)
                .padding(.bottom, 4)
            if result.actionSteps.isEmpty {
                Text(L("ask.workflow.editor.test.noActions")).font(.system(.callout))
                    .foregroundStyle(TypefluxColor.tertiaryLabel.color)
            }
            ForEach(Array(result.actionSteps.enumerated()), id: \.offset) { index, step in
                if index > 0 {
                    Rectangle().fill(TypefluxColor.separator.color).frame(height: 1)
                }
                row(step, outcome: result.actionOutcomes.indices.contains(index) ? result.actionOutcomes[index] : nil)
            }
            let missing = Array(Set(result.actionSteps.flatMap(\.missing))).sorted()
            if !missing.isEmpty {
                Text(L("ask.workflow.editor.test.missingJSON", missing.joined(separator: " ")))
                    .font(.system(.subheadline)).foregroundStyle(TypefluxColor.warning.color).padding(.top, 6)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func row(_ step: AskWorkflowActionStep, outcome: AskWorkflowActionOutcome?) -> some View {
        let (status, color) = Self.status(step, outcome)
        return HStack(spacing: 8) {
            AskWorkflowActionTile(kind: step.action.kind, size: 20)
            Text(step.title).font(.system(.callout)).foregroundStyle(TypefluxColor.label.color).lineLimit(1).fixedSize()
            if step.fromScript {
                AskWorkflowNoteChip(text: L("ask.workflow.editor.test.fromScript"))
            }
            Text(step.detail.replacingOccurrences(of: "\n", with: " ⏎ ")).font(.system(
                .subheadline,
                design: .monospaced
            ))
            .foregroundStyle(TypefluxColor.secondaryLabel.color).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 6)
            // The value gives way first: where the action ended matters more.
            Text(status).font(.system(.subheadline)).foregroundStyle(color).lineLimit(2)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 130, alignment: .trailing).layoutPriority(1)
        }
        .padding(.vertical, 7)
    }

    /// "Preview", "✓ Done", "Skipped: …", "✕ …".
    static func status(_ step: AskWorkflowActionStep, _ outcome: AskWorkflowActionOutcome?) -> (String, Color) {
        // A script action that is not allowed never runs, whatever else is wrong with it.
        if let reason = step.notRun { return (reason, TypefluxColor.warning.color) }
        if let problem = step.problem { return ("✕ " + problem, TypefluxColor.danger.color) }
        switch outcome?.status {
        case nil, .skipped(nil): return (L("ask.workflow.editor.test.actionPreview"), TypefluxColor.tertiaryLabel.color)
        case let .skipped(reason?): return (reason, TypefluxColor.warning.color)
        case .done: return (L("ask.workflow.editor.test.actionDone"), TypefluxColor.success.color)
        case let .fellBack(reason): return ("✓ " + reason, TypefluxColor.warning.color)
        case let .failed(reason): return ("✕ " + reason, TypefluxColor.danger.color)
        }
    }
}

/// The assistant: the conversation, proposal cards, the question before running
/// code with new risks, and the composer.
struct AskWorkflowAssistantPanel: View {
    @Environment(\.interfaceStyle) private var interfaceStyle

    @ObservedObject var model: AskWorkflowEditorModel
    @ObservedObject var assistant: AskWorkflowAssistant
    @State private var text = ""
    @State private var expandedSteps: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { reader in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if assistant.items.isEmpty {
                            emptyState
                        }
                        ForEach(AskWorkflowAssistantPanel.entries(assistant.items)) { entry in
                            switch entry {
                            case let .item(item): itemView(item)
                            case let .steps(id, summaries): stepsLine(id: id, summaries: summaries)
                            }
                        }
                        if assistant.isBusy {
                            HStack(alignment: .top, spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text(assistant.preview.isEmpty ? L("ask.workflow.assistant.working") : assistant
                                    .preview)
                                    .font(.system(.callout)).foregroundStyle(TypefluxColor.secondaryLabel.color)
                                    .lineLimit(6)
                            }
                        }
                        if let error = assistant.error {
                            Text(error).font(.system(.callout)).foregroundStyle(TypefluxColor.danger.color)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(12)
                }
                .onChange(of: assistant.items.count) { _ in withAnimation { reader.scrollTo("bottom") } }
            }
            // The assistant waits on this question, so it stays in view above the composer.
            if let run = model.pendingRun {
                approval(run).padding(.horizontal, 12).padding(.bottom, 10)
            }
            composer
        }
    }

    /// What the assistant is for, and a few requests to start from.
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "sparkles").font(.system(.title3, weight: .semibold))
                .foregroundStyle(TypefluxColor.accent.color)
                .frame(width: 34, height: 34)
                .background(TypefluxColor.accent.color.opacity(0.14),
                            in: RoundedRectangle(
                                cornerRadius: TypefluxRadius.form.value(for: interfaceStyle),
                                style: .continuous
                            ))
            Text(L("ask.workflow.assistant.empty")).font(.system(.callout))
                .foregroundStyle(TypefluxColor.secondaryLabel.color).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Self.suggestions, id: \.self) { key in
                    Button { text = L(key) } label: {
                        Text(L(key)).font(.system(.callout)).foregroundStyle(TypefluxColor.secondaryLabel.color)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .background(
                                TypefluxColor.contentBackground.color,
                                in: RoundedRectangle(
                                    cornerRadius: TypefluxRadius.form.value(for: interfaceStyle),
                                    style: .continuous
                                )
                            )
                            .overlay(RoundedRectangle(
                                cornerRadius: TypefluxRadius.form.value(for: interfaceStyle),
                                style: .continuous
                            )
                            .strokeBorder(TypefluxColor.separator.color))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 2)
        }
        .padding(.top, 6)
    }

    static let suggestions = [
        "ask.workflow.assistant.suggestion.keyword",
        "ask.workflow.assistant.suggestion.format",
        "ask.workflow.assistant.suggestion.runtime"
    ]

    /// "✓ Wrote main.py · 3 steps", opening to every step.
    private func stepsLine(id: String, summaries: [String]) -> some View {
        let expanded = expandedSteps.contains(id)
        return VStack(alignment: .leading, spacing: 3) {
            Button {
                if expanded {
                    expandedSteps.remove(id)
                } else {
                    expandedSteps.insert(id)
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle")
                    Text(summaries.last ?? "").lineLimit(1)
                    if summaries.count > 1 {
                        Text(L("ask.workflow.assistant.steps", summaries.count))
                            .foregroundStyle(TypefluxColor.tertiaryLabel.color)
                        Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(.footnote))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).disabled(summaries.count < 2)
            if expanded {
                ForEach(Array(summaries.dropLast().enumerated()), id: \.offset) { _, summary in
                    Text(summary).padding(.leading, 20)
                }
            }
        }
        .font(.system(.subheadline)).foregroundStyle(TypefluxColor.secondaryLabel.color)
    }

    @ViewBuilder private func itemView(_ item: AskWorkflowAssistant.Item) -> some View {
        switch item {
        case let .user(_, text):
            HStack {
                Spacer(minLength: 30)
                Text(text).font(.system(.callout)).textSelection(.enabled)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(
                        TypefluxColor.accent.color.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: TypefluxRadius.form.value(for: interfaceStyle))
                    )
            }
        case let .reply(_, text):
            VStack(alignment: .leading, spacing: 3) {
                Label(L("ask.workflow.assistant.title"), systemImage: "sparkles")
                    .font(.system(.subheadline)).foregroundStyle(TypefluxColor.tertiaryLabel.color)
                Text((try? AttributedString(markdown: text,
                                            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                        ?? AttributedString(text))
                    .font(.system(.callout)).textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case let .tool(_, summary, failed):
            Label(summary, systemImage: failed ? "xmark.circle" : "checkmark.circle")
                .font(.system(.subheadline))
                .foregroundStyle(failed ? TypefluxColor.warning.color : TypefluxColor.secondaryLabel.color)
        case let .proposal(id):
            if let proposal = model.proposal(id) {
                if proposal.state == .superseded {
                    supersededLine(proposal)
                } else {
                    proposalCard(proposal)
                }
            }
        case let .notice(_, text):
            Text(text).font(.system(.subheadline)).foregroundStyle(TypefluxColor.tertiaryLabel.color)
        }
    }

    private func proposalCard(_ proposal: AskWorkflowProposal) -> some View {
        let changes = model.draft.map { proposal.changes(against: $0) } ?? []
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles").foregroundStyle(TypefluxColor.accent.color)
                Text(L("ask.workflow.assistant.proposal")).font(.system(.callout, weight: .semibold))
                Spacer()
                Text(stateText(proposal, files: changes.count)).font(.system(.subheadline))
                    .foregroundStyle(TypefluxColor.tertiaryLabel.color)
            }
            .padding(10)
            Divider()
            if !proposal.summary.isEmpty {
                Text(proposal.summary).font(.system(.callout)).padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Divider()
            }
            if proposal.state == .pending, !changes.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(changes, id: \.path) { change in
                        HStack(spacing: 6) {
                            Text(change.path)
                            Text("+\(change.added)").foregroundStyle(TypefluxColor.success.color)
                            if change.removed > 0 {
                                Text("−\(change.removed)").foregroundStyle(TypefluxColor.danger.color)
                            }
                        }
                        .font(.system(.subheadline, design: .monospaced))
                    }
                }
                .padding(10)
                Divider()
            }
            proposalExtras(proposal)
            if proposal.state == .pending {
                Divider()
                proposalActions(proposal)
            }
        }
        .background(
            TypefluxColor.contentBackground.color,
            in: RoundedRectangle(cornerRadius: TypefluxRadius.form.value(for: interfaceStyle))
        )
        .overlay(RoundedRectangle(cornerRadius: TypefluxRadius.form.value(for: interfaceStyle))
            .strokeBorder(TypefluxColor.accent.color.opacity(proposal.state == .pending ? 0.5 : 0.15)))
    }

    /// Look at the differences, discard, or apply to the editor.
    private func proposalActions(_ proposal: AskWorkflowProposal) -> some View {
        HStack(spacing: 6) {
            Spacer()
            Button(L("ask.workflow.assistant.preview")) { model.previewingProposal = proposal.id }
                .buttonStyle(.borderless).controlSize(.small)
            Button(L("ask.workflow.assistant.discard")) { model.discard(proposal.id) }
                .buttonStyle(.bordered).controlSize(.small)
            Button(L("ask.workflow.assistant.apply")) { model.apply(proposal.id) }
                .buttonStyle(.borderedProminent).controlSize(.small)
                .accessibilityIdentifier("ask.workflow.assistant.apply")
        }
        .padding(10)
    }

    /// Its risks, and "Undo" right after it was applied.
    @ViewBuilder private func proposalExtras(_ proposal: AskWorkflowProposal) -> some View {
        if !proposal.risks.isEmpty {
            AskWorkflowRiskChips(risks: proposal.risks.sorted(), new: proposal.newRisks, showsAbsent: false)
                .padding(10)
        }
        if proposal.state == .applied, model.canUndoProposal, model.lastAppliedProposal == proposal.id {
            Divider()
            HStack {
                Text(L("ask.workflow.editor.proposalApplied")).font(.system(.subheadline))
                    .foregroundStyle(TypefluxColor.secondaryLabel.color)
                Spacer()
                Button(L("ask.workflow.editor.undoProposal")) { model.undoProposal() }
            }
            .controlSize(.small).padding(10)
        }
    }

    /// A proposal the next one replaced, as one line: "Proposal 1: … · 3/3 passed".
    private func supersededLine(_ proposal: AskWorkflowProposal) -> some View {
        let passed = proposal.tests.filter(\.succeeded).count
        return HStack(spacing: 6) {
            Image(systemName: "checkmark.circle").foregroundStyle(TypefluxColor.secondaryLabel.color)
            Text(L("ask.workflow.assistant.supersededLine", model.proposalNumber(proposal.id), proposal.summary))
                .foregroundStyle(TypefluxColor.secondaryLabel.color).lineLimit(2)
            Spacer(minLength: 6)
            Text(proposal.tests.isEmpty ? L("ask.workflow.assistant.untested")
                : L("ask.workflow.assistant.testedShort", passed, proposal.tests.count))
                .foregroundStyle(proposal.tests.isEmpty || passed < proposal.tests.count
                    ? TypefluxColor.tertiaryLabel.color : TypefluxColor.success.color)
        }
        .font(.system(.subheadline))
    }

    private func stateText(_ proposal: AskWorkflowProposal, files: Int) -> String {
        switch proposal.state {
        case .applied: return L("ask.workflow.assistant.applied")
        case .discarded, .superseded: return L("ask.workflow.assistant.discarded")
        case .pending:
            let count = L("ask.workflow.assistant.files", files)
            guard !proposal.tests.isEmpty else { return count + " · " + L("ask.workflow.assistant.untested") }
            return count + " · " + L("ask.workflow.assistant.testedSummary",
                                     proposal.tests.filter(\.succeeded).count, proposal.tests.count)
        }
    }
}

extension AskWorkflowAssistantPanel {
    private func approval(_ run: AskWorkflowEditorModel.PendingRun) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(L("ask.workflow.assistant.approval.titleNumbered", model.proposalNumber(run.proposalID)),
                      systemImage: "exclamationmark.triangle")
                    .font(.system(.callout, weight: .semibold)).foregroundStyle(TypefluxColor.warning.color)
                    .help(L("ask.workflow.assistant.approval.body"))
                Spacer()
                Text(L("ask.workflow.assistant.approval.paused")).font(.system(.subheadline))
                    .foregroundStyle(TypefluxColor.tertiaryLabel.color)
            }
            AskWorkflowRiskChips(risks: model.proposal(run.proposalID)?.risks.sorted() ?? run.risks,
                                 new: Set(run.risks), showsAbsent: false)
            HStack {
                Spacer()
                if let fallback = model.fallbackProposal {
                    Button(L("ask.workflow.assistant.approval.useOnly", model.proposalNumber(fallback.id))) {
                        model.useFallbackProposal()
                    }
                } else {
                    Button(L("ask.workflow.assistant.approval.decline")) { model.resolvePendingRun(false) }
                }
                Button(L("ask.workflow.assistant.preview")) { model.previewingProposal = run.proposalID }
                Button(L("ask.workflow.assistant.approval.allow")) { model.resolvePendingRun(true) }
                    .buttonStyle(.borderedProminent).tint(TypefluxColor.accent.color)
                    .accessibilityIdentifier("ask.workflow.assistant.allow")
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(
            TypefluxColor.warning.color.opacity(0.08),
            in: RoundedRectangle(cornerRadius: TypefluxRadius.form.value(for: interfaceStyle))
        )
        .overlay(RoundedRectangle(cornerRadius: TypefluxRadius.form.value(for: interfaceStyle))
            .strokeBorder(TypefluxColor.warning.color.opacity(0.5)))
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 6) {
                TextEditor(text: $text).font(.system(.callout)).frame(height: 44)
                    .scrollContentBackground(.hidden)
                    .overlay(alignment: .topLeading) {
                        if text.isEmpty {
                            Text(L("ask.workflow.assistant.placeholder")).font(.system(.callout))
                                .foregroundStyle(TypefluxColor.tertiaryLabel.color).padding(.leading, 5).padding(
                                    .top,
                                    1
                                )
                                .allowsHitTesting(false)
                        }
                    }
                    .accessibilityIdentifier("ask.workflow.assistant.input")
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: TypefluxRadius.textField.value(for: interfaceStyle))
                        .fill(LinearGradient(
                            colors: [.pink, .orange],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ))
                        .frame(width: 12, height: 12)
                    Text(assistant
                        .modelName == L("ask.workflow.assistant.cloud") ? L("ask.workflow.assistant.defaultModel")
                        : assistant.modelName).font(.system(.subheadline, weight: .semibold))
                    Text("·").foregroundStyle(TypefluxColor.tertiaryLabel.color)
                    Text(assistant.keepsLocally ? L("ask.workflow.assistant.local") : L("ask.workflow.assistant.cloud"))
                        .foregroundStyle(TypefluxColor.tertiaryLabel.color)
                    Image(systemName: "info.circle").foregroundStyle(TypefluxColor.tertiaryLabel.color)
                        .help(L("ask.workflow.assistant.privacy"))
                    Spacer()
                    if assistant.isBusy {
                        Button { model.stopAssistant() } label: {
                            Image(systemName: "stop.fill").font(.system(.footnote)).foregroundStyle(.white)
                                .frame(width: 24, height: 24)
                                .background(TypefluxColor.accent.color, in: Circle())
                        }
                        .buttonStyle(.plain).help(L("ask.workflow.assistant.stop"))
                    } else {
                        Button {
                            assistant.send(text)
                            text = ""
                        } label: {
                            Image(systemName: "arrow.up").font(.system(.subheadline, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 24, height: 24)
                                .background(TypefluxColor.accent.color.opacity(sendable ? 1 : 0.35), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(!sendable)
                        .help(L("ask.workflow.assistant.send"))
                    }
                }
                .font(.system(.subheadline))
            }
            .padding(10)
            .background(
                TypefluxColor.contentBackground.color,
                in: RoundedRectangle(cornerRadius: TypefluxRadius.form.value(for: interfaceStyle))
            )
            .overlay(RoundedRectangle(cornerRadius: TypefluxRadius.form.value(for: interfaceStyle))
                .strokeBorder(TypefluxColor.separator.color))
        }
        .padding(12)
    }

    private var sendable: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
