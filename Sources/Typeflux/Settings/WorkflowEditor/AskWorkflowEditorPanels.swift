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
            input
            Divider()
            if let result = model.results.last {
                HStack {
                    AskWorkflowTabs(items: Tab.allCases.map { tab in
                        .init(tab: tab, title: L("ask.workflow.editor.test.tab." + tab.rawValue),
                              badge: tab == .stderr && !result.succeeded && !result.stderr.isEmpty
                                  ? "\(result.stderr.split(separator: "\n").count)" : nil)
                    }, selection: $tab, size: 11.5)
                    Spacer()
                }
                .padding(.horizontal, 8).padding(.top, 10)
                Divider()
                meta(result)
                ScrollView { detail(result).padding(.horizontal, 12).padding(.bottom, 12) }
            } else {
                Text(L("ask.workflow.editor.test.empty")).font(.system(size: 12))
                    .foregroundStyle(StudioTheme.textTertiary).padding(12)
                Spacer()
            }
            Divider()
            history
        }
    }

    // MARK: - Input

    private var input: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L("ask.workflow.editor.test.title")).font(.system(size: 12.5, weight: .semibold))
                Spacer()
                AskWorkflowBadge(text: L("ask.workflow.editor.test.sameRunner"), color: StudioTheme.textSecondary)
            }
            let keywords = model.draft?.manifest?.keywords.map(\.keyword) ?? []
            HStack(spacing: 5) {
                Text(L("ask.workflow.editor.test.inputBefore"))
                if keywords.count > 1 {
                    Menu {
                        ForEach(keywords, id: \.self) { keyword in Button(keyword) { model.testKeyword = keyword } }
                    } label: {
                        AskWorkflowChip(text: (model.testKeyword ?? keywords[0]) + " ▾")
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                } else if let keyword = keywords.first {
                    AskWorkflowChip(text: keyword)
                }
                Text(L("ask.workflow.editor.test.inputAfter"))
            }
            .font(.system(size: 11)).foregroundStyle(StudioTheme.textTertiary)
            TextField(L("ask.workflow.editor.test.placeholder"), text: $model.testQuery)
                .textFieldStyle(.roundedBorder).onSubmit { model.runTest() }
                .accessibilityIdentifier("ask.workflow.editor.test.query")
            Toggle(L("ask.workflow.editor.test.withSelection"), isOn: $model.testUsesSelection)
                .toggleStyle(.checkbox).font(.system(size: 12))
            if model.testUsesSelection {
                TextEditor(text: $model.testSelection).font(.system(size: 12)).frame(height: 54)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(StudioTheme.border))
            }
            if model.isTesting {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    TimelineView(.periodic(from: .now, by: 0.1)) { context in
                        Text(L("ask.workflow.editor.test.running",
                               context.date.timeIntervalSince(model.testStartedAt ?? context.date)))
                            .font(.system(size: 11.5)).foregroundStyle(StudioTheme.textSecondary)
                            .monospacedDigit()
                    }
                    Spacer()
                    Button(L("ask.workflow.editor.test.stop")) { model.stopTest() }.controlSize(.small)
                }
            }
        }
        .padding(12)
    }

    // MARK: - Result

    private func meta(_ result: AskWorkflowTestResult) -> some View {
        HStack(spacing: 6) {
            Image(systemName: result.succeeded ? "checkmark" : "xmark").font(.system(size: 10, weight: .bold))
            Text(result.summary)
            if result.succeeded, !result.stdout.isEmpty {
                Text("· " + L("ask.workflow.editor.test.lines",
                              result.stdout.trimmingCharacters(in: .newlines).split(separator: "\n").count))
            }
            Spacer()
            if !result.succeeded {
                Button { fix() } label: { Label(L("ask.workflow.assistant.fix"), systemImage: "sparkles") }
                    .controlSize(.small).tint(AskWorkflowEditorStyle.assistant)
                    .accessibilityIdentifier("ask.workflow.editor.fix")
            }
            Text(AskWorkflowEditorModel.relative(result.date)).foregroundStyle(StudioTheme.textTertiary)
        }
        .font(.system(size: 11.5))
        .foregroundStyle(result.succeeded ? StudioTheme.success : StudioTheme.danger)
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    @ViewBuilder private func detail(_ result: AskWorkflowTestResult) -> some View {
        let manifest = model.draft?.manifest
        switch tab {
        case .preview:
            preview(result, input: true)
        case .stdout:
            mono(result.stdout.isEmpty ? L("ask.workflow.editor.test.nothing") : result.stdout)
        case .stderr:
            VStack(alignment: .leading, spacing: 10) {
                stderrLog(result.stderr)
                if !result.succeeded, manifest != nil {
                    Text(L("ask.workflow.editor.test.launcherShows")).font(.system(size: 11))
                        .foregroundStyle(StudioTheme.textTertiary)
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
            query: result.input.query, result: result, output: manifest?.output ?? .text,
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
                        Text(line).underline().foregroundStyle(AskTheme.accent)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                } else {
                    Text(line.isEmpty ? " " : line)
                        .foregroundStyle(line.contains("Error") || line.contains("error")
                            ? StudioTheme.danger : StudioTheme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .font(.system(size: 11.5, design: .monospaced)).textSelection(.enabled)
        .padding(10)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private func mono(_ text: String) -> some View {
        Text(text).font(.system(size: 11.5, design: .monospaced)).textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading).padding(10)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - History

    private var history: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L("ask.workflow.editor.test.recent")).font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(StudioTheme.textTertiary)
            let items = model.history
            if items.isEmpty {
                Text("—").font(.system(size: 11.5)).foregroundStyle(StudioTheme.textTertiary)
            }
            ForEach(items) { item in
                HStack(spacing: 8) {
                    Image(systemName: item.succeeded ? "checkmark" : "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(item.succeeded ? StudioTheme.success : StudioTheme.danger)
                        .frame(width: 12)
                    Text(item.title).lineLimit(1)
                    Spacer()
                    Text(String(format: "%.2f s", item.duration)).foregroundStyle(StudioTheme.textTertiary)
                        .monospacedDigit()
                    Text(AskWorkflowEditorModel.relative(item.date)).foregroundStyle(StudioTheme.textTertiary)
                }
                .font(.system(size: 11.5))
            }
        }
        .padding(12)
        .id(log.entries.count)
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
                .onChange(of: model.pendingRun) { _ in
                    // After the card is laid out, so all of it comes into view.
                    DispatchQueue.main.async { withAnimation { reader.scrollTo("bottom") } }
                }
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
                Text(text).font(.system(size: 12.5)).textSelection(.enabled)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(StudioTheme.accentSoft, in: RoundedRectangle(cornerRadius: 12))
            }
        case let .reply(_, text):
            VStack(alignment: .leading, spacing: 3) {
                Label(L("ask.workflow.assistant.title"), systemImage: "sparkles")
                    .font(.system(size: 11)).foregroundStyle(StudioTheme.textTertiary)
                Text((try? AttributedString(markdown: text,
                                            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                        ?? AttributedString(text))
                    .font(.system(size: 12.5)).textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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
                Image(systemName: "sparkles").foregroundStyle(AskWorkflowEditorStyle.assistant)
                Text(L("ask.workflow.assistant.proposal")).font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(stateText(proposal, files: changes.count)).font(.system(size: 11))
                    .foregroundStyle(StudioTheme.textTertiary)
            }
            .padding(10)
            Divider()
            if !proposal.summary.isEmpty {
                Text(proposal.summary).font(.system(size: 12)).padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Divider()
            }
            if proposal.state == .pending, !changes.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(changes, id: \.path) { change in
                        HStack(spacing: 6) {
                            Text(change.path)
                            Text("+\(change.added)").foregroundStyle(StudioTheme.success)
                            if change.removed > 0 {
                                Text("−\(change.removed)").foregroundStyle(StudioTheme.danger)
                            }
                        }
                        .font(.system(size: 11.5, design: .monospaced))
                    }
                }
                .padding(10)
                Divider()
            }
            AskWorkflowRiskChips(risks: proposal.risks.sorted(), new: proposal.newRisks, showsAbsent: true)
                .padding(10)
            if proposal.state == .pending {
                Divider()
                HStack {
                    Spacer()
                    Button(L("ask.workflow.assistant.discard")) { model.discard(proposal.id) }
                    Button(L("ask.workflow.assistant.preview")) { model.previewingProposal = proposal.id }
                    Button(L("ask.workflow.assistant.apply")) { model.apply(proposal.id) }
                        .buttonStyle(.borderedProminent).tint(AskWorkflowEditorStyle.assistant)
                        .accessibilityIdentifier("ask.workflow.assistant.apply")
                }
                .controlSize(.small).padding(10)
            }
        }
        .background(StudioTheme.controlSurface, in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11)
            .strokeBorder(AskWorkflowEditorStyle.assistant.opacity(proposal.state == .pending ? 0.5 : 0.15)))
    }

    private func stateText(_ proposal: AskWorkflowProposal, files: Int) -> String {
        switch proposal.state {
        case .applied: return L("ask.workflow.assistant.applied")
        case .discarded: return L("ask.workflow.assistant.discarded")
        case .pending:
            let count = L("ask.workflow.assistant.files", files)
            guard !proposal.tests.isEmpty else { return count + " · " + L("ask.workflow.assistant.untested") }
            return count + " · " + L("ask.workflow.assistant.testedSummary",
                                     proposal.tests.filter(\.succeeded).count, proposal.tests.count)
        }
    }

    private func approval(_ run: AskWorkflowEditorModel.PendingRun) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(L("ask.workflow.assistant.approval.titleNumbered", model.proposalNumber(run.proposalID)),
                      systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(StudioTheme.warning)
                Spacer()
                Text(L("ask.workflow.assistant.approval.paused")).font(.system(size: 11))
                    .foregroundStyle(StudioTheme.textTertiary)
            }
            AskWorkflowRiskChips(risks: model.proposal(run.proposalID)?.risks.sorted() ?? run.risks,
                                 new: Set(run.risks), showsAbsent: false)
            Text(L("ask.workflow.assistant.approval.body")).font(.system(size: 11.5))
                .foregroundStyle(StudioTheme.textSecondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(L("ask.workflow.assistant.preview")) { model.previewingProposal = run.proposalID }
                Button(L("ask.workflow.assistant.approval.decline")) { model.resolvePendingRun(false) }
                Button(L("ask.workflow.assistant.approval.allow")) { model.resolvePendingRun(true) }
                    .buttonStyle(.borderedProminent).tint(AskWorkflowEditorStyle.assistant)
                    .accessibilityIdentifier("ask.workflow.assistant.allow")
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(StudioTheme.warning.opacity(0.08), in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(StudioTheme.warning.opacity(0.5)))
    }

    /// What the assistant gets with each message: the open files and the last test run.
    private var context: [String] {
        guard let draft = model.draft else { return [] }
        var chips = Array(draft.files.keys.sorted().filter { !$0.lowercased().hasSuffix(".md") }.prefix(2))
        chips.append(AskWorkflowManifest.fileName)
        if let last = model.results.last {
            chips.append(L("ask.workflow.assistant.context.lastTest") + (last.succeeded ? " ✓" : " ✕"))
        }
        return chips
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    ForEach(context, id: \.self) { chip in
                        Text(chip).font(.system(size: 10.5)).foregroundStyle(StudioTheme.textSecondary)
                            .padding(.horizontal, 6).frame(height: 18)
                            .background(StudioTheme.controlSurface, in: RoundedRectangle(cornerRadius: 5))
                            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(StudioTheme.border))
                    }
                }
                TextEditor(text: $text).font(.system(size: 12.5)).frame(height: 44)
                    .scrollContentBackground(.hidden)
                    .overlay(alignment: .topLeading) {
                        if text.isEmpty {
                            Text(L("ask.workflow.assistant.placeholder")).font(.system(size: 12.5))
                                .foregroundStyle(StudioTheme.textTertiary).padding(.leading, 5).padding(.top, 1)
                                .allowsHitTesting(false)
                        }
                    }
                    .accessibilityIdentifier("ask.workflow.assistant.input")
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(LinearGradient(
                            colors: [.pink, .orange],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ))
                        .frame(width: 12, height: 12)
                    Text(assistant
                        .modelName == L("ask.workflow.assistant.cloud") ? L("ask.workflow.assistant.defaultModel")
                        : assistant.modelName).font(.system(size: 11, weight: .semibold))
                    Text("·").foregroundStyle(StudioTheme.textTertiary)
                    Text(assistant.keepsLocally ? L("ask.workflow.assistant.local") : L("ask.workflow.assistant.cloud"))
                        .foregroundStyle(StudioTheme.textTertiary)
                    Spacer()
                    if assistant.isBusy {
                        Button { assistant.stop() } label: {
                            Image(systemName: "stop.fill").font(.system(size: 10)).foregroundStyle(.white)
                                .frame(width: 24, height: 24)
                                .background(AskWorkflowEditorStyle.assistant, in: Circle())
                        }
                        .buttonStyle(.plain).help(L("ask.workflow.assistant.stop"))
                    } else {
                        Button {
                            assistant.send(text)
                            text = ""
                        } label: {
                            Image(systemName: "arrow.up").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                                .frame(width: 24, height: 24)
                                .background(AskWorkflowEditorStyle.assistant.opacity(sendable ? 1 : 0.35), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(!sendable)
                        .help(L("ask.workflow.assistant.send"))
                    }
                }
                .font(.system(size: 11))
            }
            .padding(10)
            .background(StudioTheme.controlSurface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(StudioTheme.border))
            HStack {
                Toggle(L("ask.workflow.assistant.autoTest"), isOn: $model.autoTest).toggleStyle(.checkbox)
                    .font(.system(size: 11)).help(L("ask.workflow.assistant.autoTest.help"))
                Spacer()
            }
            Text(L("ask.workflow.assistant.privacy")).font(.system(size: 10.5))
                .foregroundStyle(StudioTheme.textTertiary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
    }

    private var sendable: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Risk tags, new ones highlighted; optionally also what the code does not do.
struct AskWorkflowRiskChips: View {
    var risks: [AskWorkflowRisk]
    var new: Set<AskWorkflowRisk>
    var showsAbsent: Bool

    var body: some View {
        let kinds = Set(risks.map(\.kind))
        VStack(alignment: .leading, spacing: 4) {
            ForEach(risks, id: \.self) { risk in
                chip(new.contains(risk) || !showsAbsent ? risk.title : risk.title + L("ask.workflow.risk.existing"),
                     symbol: risk.kind == .network ? "network" : risk.isHigh ? "exclamationmark.shield" : "doc",
                     highlighted: new.contains(risk))
            }
            if showsAbsent {
                HStack(spacing: 4) {
                    if !kinds.contains(.writesFiles), !kinds.contains(.deletes) {
                        chip(L("ask.workflow.risk.noWrites"), symbol: nil, highlighted: false)
                    }
                    if !kinds.contains(.runsPrograms) {
                        chip(L("ask.workflow.risk.noPrograms"), symbol: nil, highlighted: false)
                    }
                }
            }
        }
    }

    private func chip(_ text: String, symbol: String?, highlighted: Bool) -> some View {
        HStack(spacing: 4) {
            if let symbol {
                Image(systemName: symbol)
            }
            Text(text)
        }
        .font(.system(size: 11))
        .foregroundStyle(highlighted ? Color.orange : StudioTheme.textSecondary)
        .padding(.horizontal, 7).padding(.vertical, 2)
        .background((highlighted ? Color.orange : Color.gray).opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6)
            .strokeBorder(highlighted ? Color.orange.opacity(0.35) : StudioTheme.border))
        .fixedSize()
    }
}
