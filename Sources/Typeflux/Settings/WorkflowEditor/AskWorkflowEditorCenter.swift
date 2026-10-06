// swiftlint:disable file_length
import SwiftUI

/// The middle of the editor: the numbered steps, then the step being edited —
/// forms for keywords, input and output (or `workflow.json` itself), the code card
/// for scripts. See `docs/design/launcher-keywords-workflow-editor.md` §3.2.
struct AskWorkflowEditorCenter: View {
    @ObservedObject var model: AskWorkflowEditorModel
    @State private var addingFile = false
    @State private var newFile = ""
    @State private var showsRunSettings: Bool

    init(model: AskWorkflowEditorModel, showsRunSettings: Bool = false) {
        self.model = model
        _showsRunSettings = State(initialValue: showsRunSettings)
    }

    var body: some View {
        VStack(spacing: 0) {
            if !(model.showingDiff && model.outsideChange != nil) {
                AskWorkflowFlowStrip(model: model)
            }
            if let id = model.previewingProposal, let proposal = model.proposal(id), let draft = model.draft {
                AskWorkflowDiffView(old: draft, new: proposal.applied(to: draft), labels: (
                    L("ask.workflow.editor.diff.current"), L("ask.workflow.editor.diff.proposed")
                ), suffix: L("ask.workflow.editor.diff.proposalSuffix")) {
                    Button(L("ask.workflow.editor.close")) { model.previewingProposal = nil }
                        .buttonStyle(AskWorkflowActionStyle(small: true))
                }
                .codeCard()
            } else if model.showingDiff, let change = model.outsideChange, let draft = model.draft {
                AskWorkflowDiffView(old: draft, new: change.disk, labels: (
                    L("ask.workflow.editor.diff.mine"), L("ask.workflow.editor.diff.theirs")
                ), suffix: L("ask.workflow.editor.diff.diffSuffix")) {
                    Button(L("ask.workflow.editor.outside.trustTheirs")) {
                        model.loadTheirs()
                        NotificationCenter.default.post(name: .askWorkflowEditorReviewTrust, object: nil)
                    }
                    .buttonStyle(AskWorkflowActionStyle(small: true))
                    Button(L("ask.workflow.editor.close")) { model.showingDiff = false }
                        .buttonStyle(AskWorkflowActionStyle(small: true))
                }
                .codeCard()
                .padding(.top, 14)
            } else if model.step == .script {
                scriptArea
            } else {
                configArea
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
            HStack(spacing: 4) {
                ForEach(fileOrder, id: \.self) { path in
                    AskWorkflowFileTab(title: path, selected: model.selectedFile == path,
                                       dirty: model.draft?.isDirty(path) == true) { model.selectedFile = path }
                        .contextMenu {
                            Button(L("ask.workflow.editor.removeFile"), role: .destructive) { model.removeFile(path) }
                        }
                }
                Button { addingFile = true } label: {
                    Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
                        .frame(width: 24, height: 24).contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(StudioTheme.textTertiary)
                .help(L("ask.workflow.editor.addFile"))
                Spacer()
                // ⌘F opens the find bar; the button itself stays out of sight.
                Button("") { model.findRequest += 1 }
                    .keyboardShortcut("f", modifiers: .command).opacity(0).frame(width: 0)
                    .accessibilityHidden(true)
                Button { withAnimation(.easeOut(duration: 0.15)) { showsRunSettings.toggle() } } label: {
                    Label(runSettingsTitle, systemImage: "gearshape")
                }
                .buttonStyle(AskWorkflowActionStyle(kind: showsRunSettings ? .secondary : .ghost, small: true))
                .accessibilityIdentifier("ask.workflow.editor.runSettings")
            }
            .padding(.horizontal, 20).padding(.bottom, 8)
            VStack(spacing: 0) {
                if showsRunSettings {
                    AskWorkflowRunSettings(model: model)
                        .background(ModelVisualStyle.surface)
                    Rectangle().fill(ModelVisualStyle.divider).frame(height: 1)
                }
                if let path = model.selectedFile, path != AskWorkflowManifest.fileName,
                   model.draft?.files[path] != nil {
                    code(path)
                } else {
                    Text(L("ask.workflow.editor.noScript")).foregroundStyle(StudioTheme.textSecondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                Rectangle().fill(ModelVisualStyle.divider).frame(height: 1)
                AskWorkflowStatusBar(model: model)
            }
            .codeCard()
        }
        .onAppear {
            // Open them when a run setting has a problem; the status bar points there.
            if !model.problems(for: .script).filter({ !$0.field.hasPrefix("command") }).isEmpty {
                showsRunSettings = true
            }
        }
    }

    /// The script first, then the other files by name.
    private var fileOrder: [String] {
        let script = model.draft?.manifest?.command.script
        let files = model.draft?.files.keys.sorted() ?? []
        return files.filter { $0 == script } + files.filter { $0 != script }
    }

    /// "Run settings · Python · 30 s".
    private var runSettingsTitle: String {
        guard let manifest = model.draft?.manifest else { return L("ask.workflow.editor.runSettings") }
        return [L("ask.workflow.editor.runSettings"), manifest.command.runtime.title,
                L("ask.workflow.editor.seconds", Int(manifest.timeout))].joined(separator: " · ")
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

    @ViewBuilder private var configArea: some View {
        if model.configMode == .json || model.draft?.isFormEditable != true {
            VStack(spacing: 0) {
                code(AskWorkflowManifest.fileName)
                if let suggestion = model.scriptSuggestion {
                    Rectangle().fill(ModelVisualStyle.divider).frame(height: 1)
                    HStack(spacing: 8) {
                        Image(systemName: "wand.and.stars").foregroundStyle(StudioTheme.warning)
                        Text(L("ask.workflow.editor.quickFix.script", model.draft?.manifest?.command.script ?? "",
                               suggestion))
                        Spacer()
                        Button(L("ask.workflow.editor.quickFix.apply", suggestion)) { model.applyScriptSuggestion() }
                            .buttonStyle(AskWorkflowActionStyle(small: true))
                            .accessibilityIdentifier("ask.workflow.editor.quickFix")
                    }
                    .font(.system(size: 11.5)).padding(.horizontal, 12).padding(.vertical, 6)
                    .background(StudioTheme.warning.opacity(0.10))
                }
                if AskWorkflowStatusBar.hasNews(model) {
                    Rectangle().fill(ModelVisualStyle.divider).frame(height: 1)
                    AskWorkflowStatusBar(model: model)
                }
            }
            .codeCard()
        } else {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        switch model.step {
                        case .keywords: AskWorkflowKeywordsForm(model: model)
                        case .input: AskWorkflowInputForm(model: model)
                        case .output, .script: AskWorkflowOutputForm(model: model)
                        }
                    }
                    .padding(.horizontal, 20).padding(.top, 6).padding(.bottom, 20)
                    .frame(maxWidth: 880, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if AskWorkflowStatusBar.hasNews(model) {
                    Rectangle().fill(ModelVisualStyle.divider).frame(height: 1)
                    AskWorkflowStatusBar(model: model)
                }
            }
        }
    }
}

extension View {
    /// The rounded card code and diffs sit in, inset from the editor's edges.
    func codeCard() -> some View {
        background(Color(nsColor: .textBackgroundColor).opacity(0.55))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(ModelVisualStyle.border))
            .padding(.horizontal, 20).padding(.bottom, 16)
    }
}

/// A file tab: a pill, raised when selected, with an orange dot when changed.
struct AskWorkflowFileTab: View {
    var title: String
    var selected: Bool
    var dirty: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title).font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(selected ? StudioTheme.textPrimary : StudioTheme.textSecondary)
                    .lineLimit(1)
                if dirty {
                    Circle().fill(Color.orange).frame(width: 6, height: 6)
                }
            }
            .padding(.horizontal, 10).frame(height: 26)
            .background(
                selected ? ModelVisualStyle.surface : .clear,
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(selected ? ModelVisualStyle.border : .clear))
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
        .font(.system(size: 11)).padding(.horizontal, 12).frame(height: 28)
        .background(ModelVisualStyle.surface)
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
        } else {
            Label(L("ask.workflow.editor.status.noProblems"), systemImage: "checkmark")
                .foregroundStyle(StudioTheme.textTertiary)
        }
    }

    @ViewBuilder private var trailing: some View {
        if model.outsideChange != nil {
            if let hash = model.trustedHashLabel {
                Text(L("ask.workflow.editor.status.trusted", hash)).foregroundStyle(StudioTheme.textTertiary)
            }
        } else {
            HStack(spacing: 14) {
                if model.step == .script, let runtime = model.runtimeInfo {
                    Text(runtime).lineLimit(1).truncationMode(.middle)
                }
                if let cursor = model.cursor {
                    Text(L("ask.workflow.editor.status.cursor", cursor.line, cursor.column))
                }
                Text("UTF-8")
            }
            .foregroundStyle(StudioTheme.textTertiary)
        }
    }
}

/// ① Keywords — ② Input — ③ Script — ④ Output: numbered steps with a short
/// summary each; the selected one is raised, steps with problems get a red dot.
/// The `workflow.json` switch sits at the end.
struct AskWorkflowFlowStrip: View {
    @ObservedObject var model: AskWorkflowEditorModel

    private let steps: [AskWorkflowDraft.Step] = [.keywords, .input, .script, .output]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(steps.enumerated()), id: \.element) { index, step in
                if index > 0 {
                    Rectangle().fill(ModelVisualStyle.border).frame(width: 14, height: 1)
                }
                node(step, number: index + 1)
            }
            Spacer(minLength: 12)
            if showsJSON, model.draft?.isFormEditable == true {
                Button(L("ask.workflow.editor.format")) { model.formatManifest() }
                    .buttonStyle(AskWorkflowActionStyle(kind: .ghost, small: true))
            }
            Button {
                if showsJSON {
                    model.configMode = .form
                } else {
                    model.configMode = .json
                    if model.step == .script {
                        model.step = .keywords
                    }
                }
            } label: {
                Label(showsJSON ? L("ask.workflow.editor.form") : "JSON",
                      systemImage: showsJSON ? "list.bullet.rectangle" : "curlybraces")
            }
            .buttonStyle(AskWorkflowActionStyle(kind: showsJSON ? .secondary : .ghost, small: true))
            .help(L("ask.workflow.editor.jsonHelp"))
            .disabled(model.draft?.isFormEditable != true && !showsJSON)
            .accessibilityIdentifier("ask.workflow.editor.json")
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private var showsJSON: Bool {
        model.step != .script && (model.configMode == .json || model.draft?.isFormEditable != true)
    }

    static func input(_ manifest: AskWorkflowManifest) -> String {
        L("ask.workflow.editor.argumentShort." + manifest.input.argument.rawValue) + " · "
            + L("ask.workflow.editor.selectionShort." + manifest.input.selection.rawValue)
    }

    private func summary(_ step: AskWorkflowDraft.Step) -> String {
        guard let manifest = model.draft?.manifest else { return "—" }
        switch step {
        case .keywords: return manifest.keywords.map(\.keyword).joined(separator: " · ")
        case .input: return Self.input(manifest)
        case .script: return manifest.command.script ?? L("ask.workflow.trust.inline")
        case .output:
            return AskWorkflowEditorModel.outputSummary(manifest.output)
        }
    }

    private func node(_ step: AskWorkflowDraft.Step, number: Int) -> some View {
        let selected = model.step == step && model.previewingProposal == nil && !showsJSONFor(step)
        let hasProblems = !model.problems(for: step).isEmpty
            || (step == .script && model.results.last.map { !$0.succeeded } == true)
        return Button {
            model.previewingProposal = nil
            model.showingDiff = false
            model.step = step
            if step != .script, model.draft?.isFormEditable == true {
                model.configMode = .form
            }
            if step == .script, let script = model.draft?.manifest?.command.script, model.draft?.files[script] != nil {
                model.selectedFile = script
            }
        } label: {
            HStack(spacing: 9) {
                Text("\(number)").font(.system(size: 11.5, weight: .bold))
                    .foregroundStyle(selected ? Color.white : StudioTheme.textSecondary)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(selected ? AskTheme.accent : StudioTheme.textSecondary.opacity(0.12)))
                    .overlay(alignment: .topTrailing) {
                        if hasProblems {
                            Circle().fill(StudioTheme.danger).frame(width: 8, height: 8)
                                .overlay(Circle().strokeBorder(StudioTheme.windowBackground, lineWidth: 1.5))
                                .offset(x: 2, y: -2)
                        }
                    }
                VStack(alignment: .leading, spacing: 1) {
                    Text(L("ask.workflow.editor.step." + step.rawValue)).font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(StudioTheme.textPrimary).lineLimit(1)
                    Text(summary(step)).font(.system(size: 11.5)).foregroundStyle(StudioTheme.textTertiary)
                        .lineLimit(1).truncationMode(.tail)
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 8).padding(.trailing, 10).frame(height: 44)
            .frame(maxWidth: .infinity)
            .background(
                selected ? ModelVisualStyle.surface : .clear,
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(selected ? ModelVisualStyle.border : .clear))
            .shadow(color: .black.opacity(selected ? 0.12 : 0), radius: 2, y: 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(step == .script ? model.runtimeInfo ?? "" : "")
        .accessibilityIdentifier("ask.workflow.editor.step." + step.rawValue)
    }

    /// While `workflow.json` is open no form step is highlighted.
    private func showsJSONFor(_ step: AskWorkflowDraft.Step) -> Bool {
        step != .script && showsJSON
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
