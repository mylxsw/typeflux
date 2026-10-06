import SwiftUI

/// The middle of the editor: the flow strip, then the step being edited — forms
/// for keywords, input and output (or `workflow.json` itself), the code view for scripts.
struct AskWorkflowEditorCenter: View {
    @ObservedObject var model: AskWorkflowEditorModel
    @State private var addingFile = false
    @State private var newFile = ""

    var body: some View {
        VStack(spacing: 0) {
            if !(model.showingDiff && model.outsideChange != nil) {
                AskWorkflowFlowStrip(model: model)
                Divider()
            }
            if let id = model.previewingProposal, let proposal = model.proposal(id), let draft = model.draft {
                AskWorkflowDiffView(old: draft, new: proposal.applied(to: draft), labels: (
                    L("ask.workflow.editor.diff.current"), L("ask.workflow.editor.diff.proposed")
                ), suffix: L("ask.workflow.editor.diff.proposalSuffix")) {
                    Button(L("ask.workflow.editor.close")) { model.previewingProposal = nil }
                }
            } else if model.showingDiff, let change = model.outsideChange, let draft = model.draft {
                AskWorkflowDiffView(old: draft, new: change.disk, labels: (
                    L("ask.workflow.editor.diff.mine"), L("ask.workflow.editor.diff.theirs")
                ), suffix: L("ask.workflow.editor.diff.diffSuffix")) {
                    Button(L("ask.workflow.editor.outside.trustTheirs")) {
                        model.loadTheirs()
                        NotificationCenter.default.post(name: .askWorkflowEditorReviewTrust, object: nil)
                    }
                    Button(L("ask.workflow.editor.close")) { model.showingDiff = false }
                }
            } else if model.step == .script {
                scriptArea
            } else {
                configArea
            }
            if AskWorkflowStatusBar.hasNews(model) {
                AskWorkflowStatusBar(model: model)
            }
        }
        .alert(L("ask.workflow.editor.addFile"), isPresented: $addingFile) {
            TextField("helper.py", text: $newFile)
            Button(L("ask.workflow.editor.add")) { model.addFile(newFile); newFile = "" }
            Button(L("ask.workflow.cancel"), role: .cancel) { newFile = "" }
        }
    }

    // MARK: - Script

    private var scriptArea: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(model.draft?.files.keys.sorted() ?? [], id: \.self) { path in
                    AskWorkflowFileTab(title: path, selected: model.selectedFile == path,
                                       dirty: model.draft?.isDirty(path) == true) { model.selectedFile = path }
                        .contextMenu {
                            Button(L("ask.workflow.editor.removeFile"), role: .destructive) { model.removeFile(path) }
                        }
                }
                Button { addingFile = true } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless).foregroundStyle(StudioTheme.textTertiary).padding(.horizontal, 8)
                    .help(L("ask.workflow.editor.addFile"))
                Spacer()
                // ⌘F opens the find bar; the button itself stays out of sight.
                Button("") { model.findRequest += 1 }
                    .keyboardShortcut("f", modifiers: .command).opacity(0).frame(width: 0)
                    .accessibilityHidden(true)
            }
            .font(.system(size: 12))
            .frame(height: 34)
            Divider()
            if let path = model.selectedFile, path != AskWorkflowManifest.fileName, model.draft?.files[path] != nil {
                code(path)
            } else {
                Text(L("ask.workflow.editor.noScript")).foregroundStyle(StudioTheme.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func code(_ path: String) -> some View {
        AskWorkflowCodeView(
            text: Binding(get: { model.draft?.text(of: path) ?? "" }, set: { model.setText($0, of: path) }),
            language: .detect(path: path, runtime: model.draft?.manifest?.command.runtime),
            markers: model.markers(for: path),
            reveal: model.reveal?.path == path ? model.reveal?.line : nil,
            findRequest: model.findRequest,
            onRevealed: { model.reveal = nil },
            onCursor: { model.cursor = $0 }
        )
        .id(path)
        .clipped()
    }

    // MARK: - Config

    private var configArea: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $model.configMode) {
                    Text(L("ask.workflow.editor.form")).tag(AskWorkflowEditorModel.ConfigMode.form)
                    Text("workflow.json").tag(AskWorkflowEditorModel.ConfigMode.json)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                Spacer()
                if model.configMode == .json || model.draft?.isFormEditable != true {
                    Button(L("ask.workflow.editor.format")) { model.formatManifest() }
                        .disabled(model.draft?.isFormEditable != true)
                }
            }
            .padding(.horizontal, 14).frame(height: 40)
            Divider()
            if model.configMode == .json || model.draft?.isFormEditable != true {
                code(AskWorkflowManifest.fileName)
                if let suggestion = model.scriptSuggestion {
                    HStack(spacing: 8) {
                        Image(systemName: "wand.and.stars").foregroundStyle(StudioTheme.warning)
                        Text(L("ask.workflow.editor.quickFix.script", model.draft?.manifest?.command.script ?? "",
                               suggestion))
                        Spacer()
                        Button(L("ask.workflow.editor.quickFix.apply", suggestion)) { model.applyScriptSuggestion() }
                            .accessibilityIdentifier("ask.workflow.editor.quickFix")
                    }
                    .font(.system(size: 11.5)).padding(.horizontal, 12).padding(.vertical, 6)
                    .background(StudioTheme.warning.opacity(0.10))
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        switch model.step {
                        case .keywords: AskWorkflowKeywordsForm(model: model)
                        case .input: AskWorkflowInputForm(model: model)
                        case .output, .script: AskWorkflowOutputForm(model: model)
                        }
                    }
                    .padding(.horizontal, 22).padding(.vertical, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

/// A file tab: underlined when selected, an orange dot when changed.
struct AskWorkflowFileTab: View {
    var title: String
    var selected: Bool
    var dirty: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title).font(.system(size: 12))
                    .foregroundStyle(selected ? StudioTheme.textPrimary : StudioTheme.textTertiary)
                if dirty {
                    Circle().fill(Color.orange).frame(width: 6, height: 6)
                }
            }
            .padding(.horizontal, 12).frame(maxHeight: .infinity)
            .overlay(alignment: .bottom) {
                if selected {
                    Rectangle().fill(AskTheme.accent).frame(height: 2)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Problems or a failed test run, with the caret; during an outside change, what
/// changed and what was last trusted.
struct AskWorkflowStatusBar: View {
    @ObservedObject var model: AskWorkflowEditorModel

    /// The bar only shows up with something to say: problems, a failed run or an outside change.
    @MainActor static func hasNews(_ model: AskWorkflowEditorModel) -> Bool {
        model.outsideChange != nil || !model.problems.isEmpty
            || (model.step == .script && model.results.last.map { !$0.succeeded } == true)
    }

    var body: some View {
        HStack(spacing: 14) {
            leading
            Spacer(minLength: 8)
            trailing
        }
        .font(.system(size: 11)).padding(.horizontal, 12).frame(height: 26)
        .background(StudioTheme.surfaceMuted)
    }

    @ViewBuilder private var leading: some View {
        let problems = model.problems
        if let stats = model.outsideStats {
            Label(
                L("ask.workflow.editor.status.outside", stats.added, stats.removed),
                systemImage: "exclamationmark.triangle"
            )
            .foregroundStyle(StudioTheme.warning)
        } else if !problems.isEmpty {
            ForEach(Array(problems.prefix(2).enumerated()), id: \.offset) { _, problem in
                Button { model.revealProblem(problem) } label: {
                    Label(problem.field + ": " + problem.message, systemImage: "xmark.circle").lineLimit(1)
                }
                .buttonStyle(.plain).foregroundStyle(StudioTheme.danger)
            }
            if problems.count > 2 {
                Text(L("ask.workflow.editor.status.more", problems.count - 2)).foregroundStyle(StudioTheme.danger)
            }
        } else if let last = model.results.last, !last.succeeded, model.step == .script {
            Label(L("ask.workflow.editor.status.testFailed", last.summary), systemImage: "xmark.circle")
                .foregroundStyle(StudioTheme.danger)
        }
    }

    @ViewBuilder private var trailing: some View {
        if model.outsideChange != nil {
            if let hash = model.trustedHashLabel {
                Text(L("ask.workflow.editor.status.trusted", hash)).foregroundStyle(StudioTheme.textTertiary)
            }
        } else if let cursor = model.cursor {
            Text(L("ask.workflow.editor.status.cursor", cursor.line, cursor.column))
                .foregroundStyle(StudioTheme.textTertiary)
        }
    }
}

/// Keyword → input → script → output, with a summary of each and a dot on steps with problems.
struct AskWorkflowFlowStrip: View {
    @ObservedObject var model: AskWorkflowEditorModel

    var body: some View {
        let manifest = model.draft?.manifest
        HStack(spacing: 0) {
            node(.keywords, symbol: "keyboard", title: L("ask.workflow.editor.step.keywords")) {
                HStack(spacing: 4) {
                    ForEach(Array((manifest?.keywords ?? []).enumerated()), id: \.offset) { index, keyword in
                        let bad = model.problems.contains { $0.field == "keywords[\(index)]" }
                        AskWorkflowChip(text: keyword.keyword, style: bad ? .problem : .plain)
                    }
                    if let title = manifest?.keywords.first?.title, (manifest?.keywords.count ?? 0) == 1 {
                        Text(title).foregroundStyle(StudioTheme.textTertiary)
                    }
                }
            }
            arrow
            node(.input, symbol: "text.quote", title: L("ask.workflow.editor.step.input")) {
                Text(manifest.map(Self.input) ?? "—")
            }
            arrow
            node(.script, symbol: "play", title: L("ask.workflow.editor.step.script")) {
                Text([manifest?.command.runtime.title, manifest?.command.script ?? L("ask.workflow.trust.inline")]
                    .compactMap(\.self).joined(separator: " · "))
            }
            .help(model.runtimeInfo ?? "")
            arrow
            node(.output, symbol: "arrow.right.to.line", title: L("ask.workflow.editor.step.output")) {
                Text(manifest.map {
                    L("ask.workflow.editor.output." + $0.output.rawValue) + " · "
                        + L("ask.workflow.editor.seconds", Int($0.timeout))
                } ?? "—")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }

    static func input(_ manifest: AskWorkflowManifest) -> String {
        L("ask.workflow.editor.argument." + manifest.input.argument.rawValue) + " · "
            + L("ask.workflow.editor.selectionShort." + manifest.input.selection.rawValue)
    }

    private var arrow: some View {
        Image(systemName: "arrow.right").font(.system(size: 10)).foregroundStyle(StudioTheme.textTertiary)
            .frame(width: 20)
    }

    private func node(_ step: AskWorkflowDraft.Step, symbol: String, title: String,
                      @ViewBuilder summary: () -> some View) -> some View {
        let selected = model.step == step && model.previewingProposal == nil
        let hasProblems = !model.problems(for: step).isEmpty
        return Button {
            model.previewingProposal = nil
            model.showingDiff = false
            model.step = step
            if step == .script, let script = model.draft?.manifest?.command.script, model.draft?.files[script] != nil {
                model.selectedFile = script
            }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Image(systemName: symbol).font(.system(size: 9.5))
                    Text(title).font(.system(size: 10.5, weight: .semibold))
                    Spacer()
                    if hasProblems {
                        Circle().fill(StudioTheme.danger).frame(width: 6, height: 6)
                    }
                }
                .foregroundStyle(StudioTheme.textTertiary)
                summary().font(.system(size: 12)).lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading).clipped()
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? StudioTheme.accentSoft : StudioTheme.controlSurface,
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(hasProblems ? StudioTheme.danger.opacity(0.6)
                    : selected ? AskTheme.accent : StudioTheme.border))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("ask.workflow.editor.step." + step.rawValue)
    }
}

/// Two versions of a workflow: a tab per changed file, and the old version, the
/// line differences or the new version.
struct AskWorkflowDiffView<Actions: View>: View {
    enum Mode: Hashable { case old, diff, new }

    var old: AskWorkflowDraft
    var new: AskWorkflowDraft
    /// What the two versions are called: "Current" / "Proposal", "Mine" / "On disk".
    var labels: (String, String)
    /// After the file name in its tab: "· Proposal", "· Differences".
    var suffix: String
    @ViewBuilder var actions: () -> Actions
    @State private var mode: Mode = .diff
    @State private var path: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(changedPaths, id: \.self) { file in
                    AskWorkflowFileTab(title: file + " · " + suffix, selected: file == current, dirty: false) {
                        path = file
                    }
                }
                Spacer()
                Picker("", selection: $mode) {
                    Text(labels.0).tag(Mode.old)
                    Text(L("ask.workflow.editor.diff.differences")).tag(Mode.diff)
                    Text(labels.1).tag(Mode.new)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                actions().padding(.leading, 8)
            }
            .padding(.trailing, 12).frame(height: 38)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        HStack(spacing: 8) {
                            Text(line.kind == .added ? "+" : line.kind == .removed ? "−" : " ").frame(width: 10)
                            Text(line.text.isEmpty ? " " : line.text).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .font(.system(size: 12, design: .monospaced))
                        .strikethrough(line.kind == .removed, color: StudioTheme.danger.opacity(0.5))
                        .padding(.horizontal, 12).padding(.vertical, 1)
                        .background(line.kind == .added ? Color.green.opacity(0.14)
                            : line.kind == .removed ? Color.red.opacity(0.14) : .clear)
                    }
                }
                .padding(.vertical, 8)
                .textSelection(.enabled)
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
    }

    private var changedPaths: [String] {
        Set(old.paths + new.paths).sorted().filter { old.text(of: $0) != new.text(of: $0) }
    }

    private var current: String? {
        path.flatMap { changedPaths.contains($0) ? $0 : nil } ?? changedPaths.first
    }

    private var lines: [AskWorkflowDiff.Line] {
        guard let current else { return [] }
        let before = old.text(of: current) ?? "", after = new.text(of: current) ?? ""
        switch mode {
        case .diff: return AskWorkflowDiff.lines(old: before, new: after)
        case .old: return before.components(separatedBy: "\n").enumerated().map { .init(
                kind: .same,
                text: $1,
                number: $0 + 1
            ) }
        case .new: return after.components(separatedBy: "\n").enumerated().map { .init(
                kind: .same,
                text: $1,
                number: $0 + 1
            ) }
        }
    }
}
