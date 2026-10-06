import SwiftUI

/// New workflow: describe it and let the assistant write it, start from a template,
/// or copy the open one. Keywords are checked as they are typed. While the
/// assistant writes the workflow, its steps are listed here.
struct AskWorkflowNewSheet: View {
    enum Mode: String, Identifiable, CaseIterable {
        case assistant, template, duplicate
        var id: String {
            rawValue
        }
    }

    @ObservedObject var model: AskWorkflowEditorModel
    @State var mode: Mode
    var done: () -> Void

    @State private var description = ""
    @State private var name = ""
    @State private var keyword = ""
    @State private var id = ""
    @State private var editedID = false
    @State private var template: AskWorkflowTemplate = .pythonText
    @State private var runtime: AskWorkflowRuntime?
    @State private var generating: Bool
    @State private var showsOptions = false
    @State private var showsSteps = false

    init(model: AskWorkflowEditorModel, mode: Mode, generating: Bool = false, showsOptions: Bool = false,
         done: @escaping () -> Void) {
        self.model = model
        _mode = State(initialValue: mode)
        _generating = State(initialValue: generating)
        _showsOptions = State(initialValue: showsOptions)
        self.done = done
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L("ask.workflow.editor.new.title")).font(.system(size: 15, weight: .semibold))
                Text(mode == .assistant ? L("ask.workflow.editor.new.aiSubtitle") :
                    L("ask.workflow.editor.new.subtitle"))
                    .font(.system(size: 12)).foregroundStyle(StudioTheme.textSecondary)
            }
            if !generating {
                modePicker
            }
            switch mode {
            case .assistant: assistantFields
            case .template, .duplicate: templateTiles
            }
            if mode != .assistant {
                nameFields
            }
            footer
        }
        .padding(22)
        .frame(width: 640)
        .onChange(of: name) { newValue in
            if !editedID {
                id = model.store.suggestedID(for: newValue.isEmpty ? keyword : newValue)
            }
        }
        .onChange(of: keyword) { newValue in
            if !editedID, name.isEmpty {
                id = model.store.suggestedID(for: newValue)
            }
        }
        .onAppear {
            if mode == .duplicate, let source = model.draft?.manifest {
                name = source.name + " " + L("ask.workflow.editor.new.copySuffix")
            }
        }
    }

    private var modePicker: some View {
        HStack(spacing: 2) {
            modeButton(.assistant, title: "✦ " + L("ask.workflow.editor.new.ai"))
            modeButton(.template, title: L("ask.workflow.editor.new.template"))
            if model.workflow != nil {
                modeButton(.duplicate, title: L("ask.workflow.editor.new.duplicateShort"))
            }
        }
        .padding(2)
        .background(StudioTheme.controlSurface, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(StudioTheme.border))
        .fixedSize()
    }

    private func modeButton(_ value: Mode, title: String) -> some View {
        let selected = mode == value
        return Button { mode = value } label: {
            Text(title).font(.system(size: 12)).foregroundStyle(selected ? .white : StudioTheme.textSecondary)
                .padding(.horizontal, 12).frame(height: 26)
                .background(
                    selected ? (value == .assistant ? AskWorkflowEditorStyle.assistant : AskTheme.accent) : .clear,
                    in: RoundedRectangle(cornerRadius: 7)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - With the assistant

    /// Describe it; the language and keyword are optional and tucked away.
    @ViewBuilder private var assistantFields: some View {
        if generating, !description.isEmpty {
            Text(description).font(.system(size: 12.5)).foregroundStyle(StudioTheme.textSecondary).lineLimit(2)
                .padding(.leading, 10)
                .overlay(alignment: .leading) {
                    Rectangle().fill(AskWorkflowEditorStyle.assistant.opacity(0.6)).frame(width: 2)
                }
        }
        if generating {
            if model.assistant.isBusy || model.pendingRun != nil || model.assistant.error != nil
                || model.latestProposal == nil {
                progress
            } else {
                result
            }
        } else {
            TextEditor(text: $description).font(.system(size: 13)).frame(height: 96)
                .scrollContentBackground(.hidden).padding(6)
                .background(StudioTheme.controlSurface, in: RoundedRectangle(cornerRadius: 11))
                .overlay(RoundedRectangle(cornerRadius: 11)
                    .strokeBorder(AskWorkflowEditorStyle.assistant.opacity(0.55)))
                .overlay(alignment: .topLeading) {
                    if description.isEmpty {
                        Text(L("ask.workflow.editor.new.aiPlaceholder")).font(.system(size: 13))
                            .foregroundStyle(StudioTheme.textTertiary).padding(11).allowsHitTesting(false)
                    }
                }
                .accessibilityIdentifier("ask.workflow.editor.new.description")
            HStack(spacing: 6) {
                Text(L("ask.workflow.editor.new.examples")).foregroundStyle(StudioTheme.textTertiary)
                ForEach(["markdown", "ip", "code"], id: \.self) { example in
                    Button(L("ask.workflow.editor.new.example." + example)) {
                        description = L("ask.workflow.editor.new.example." + example + ".text")
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                }
                Spacer()
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { showsOptions.toggle() }
                } label: {
                    Label(L("ask.workflow.editor.new.options"),
                          systemImage: showsOptions ? "chevron.down" : "chevron.right")
                }
                .buttonStyle(.borderless).foregroundStyle(StudioTheme.textSecondary)
            }
            .font(.system(size: 11.5))
            if showsOptions {
                options
            }
        }
    }

    private var options: some View {
        HStack(spacing: 16) {
            HStack(spacing: 6) {
                Text(L("ask.workflow.trust.keywords")).foregroundStyle(StudioTheme.textSecondary)
                TextField(L("ask.workflow.editor.new.keywordAuto"), text: $keyword).textFieldStyle(.roundedBorder)
                    .font(.system(size: 12.5, design: .monospaced)).frame(width: 90)
                keywordStatus
            }
            HStack(spacing: 6) {
                Text(L("ask.workflow.editor.new.language")).foregroundStyle(StudioTheme.textSecondary)
                Picker("", selection: $runtime) {
                    Text(L("ask.workflow.editor.new.languageAuto")).tag(AskWorkflowRuntime?.none)
                    ForEach([AskWorkflowRuntime.python3, .node, .zsh], id: \.self) {
                        Text($0.title).tag(Optional($0))
                    }
                }
                .labelsHidden().fixedSize()
            }
            Spacer()
        }
        .font(.system(size: 12))
    }

}

extension AskWorkflowNewSheet {
    /// One line on what the assistant is doing; the steps behind "Details".
    private var progress: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if let error = model.assistant.error {
                    Image(systemName: "xmark.octagon").foregroundStyle(StudioTheme.danger)
                    Text(error).foregroundStyle(StudioTheme.danger).lineLimit(3)
                } else if model.pendingRun != nil {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(StudioTheme.warning)
                    Text(L("ask.workflow.editor.new.askRun"))
                } else {
                    ProgressView().controlSize(.small)
                    Text(currentStep).lineLimit(1)
                }
                Spacer()
                if let proposal = model.latestProposal {
                    Text(versionText(proposal)).foregroundStyle(StudioTheme.textTertiary)
                }
            }
            .font(.system(size: 12.5))
            if let run = model.pendingRun {
                AskWorkflowRiskChips(risks: run.risks, new: Set(run.risks), showsAbsent: false)
                HStack {
                    Spacer()
                    Button(L("ask.workflow.assistant.approval.decline")) { model.resolvePendingRun(false) }
                    Button(L("ask.workflow.assistant.approval.allow")) { model.resolvePendingRun(true) }
                        .buttonStyle(.borderedProminent).tint(AskWorkflowEditorStyle.assistant)
                }
                .controlSize(.small)
            }
            DisclosureGroup(isExpanded: $showsSteps) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                        Label(step, systemImage: "checkmark.circle").foregroundStyle(StudioTheme.textSecondary)
                    }
                }
                .font(.system(size: 11.5)).padding(.top, 4).frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Text(L("ask.workflow.editor.new.details", steps.count)).font(.system(size: 11.5))
                    .foregroundStyle(StudioTheme.textTertiary)
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(StudioTheme.controlSurface.opacity(0.5), in: RoundedRectangle(cornerRadius: 11))
    }

    /// The finished workflow: what to type, what the assistant said, how a test run
    /// looks in the launcher and what the code may do.
    private var result: some View {
        let candidate = model.draft.map { model.latestProposal?.applied(to: $0) ?? $0 }
        let manifest = candidate?.manifest
        let keyword = manifest?.keywords.first?.keyword ?? ""
        // A passing run with input shows best what the workflow does.
        let tests = model.latestProposal?.tests ?? []
        let test = tests.last { $0.succeeded && !$0.input.query.isEmpty } ?? tests.last { $0.succeeded } ?? tests.last
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(StudioTheme.success)
                Text(L("ask.workflow.editor.new.doneTitle", manifest?.name ?? keyword))
                    .font(.system(size: 13.5, weight: .semibold))
                Spacer()
                if let proposal = model.latestProposal {
                    Text(versionText(proposal)).font(.system(size: 11.5)).foregroundStyle(StudioTheme.textTertiary)
                }
            }
            if !keyword.isEmpty {
                HStack(spacing: 4) {
                    Text(L("ask.workflow.editor.new.usage.before"))
                    AskWorkflowChip(text: keyword, style: .token)
                    Text(L("ask.workflow.editor.new.usage.after"))
                }
                .font(.system(size: 12)).foregroundStyle(StudioTheme.textSecondary)
            }
            if let test, let manifest {
                AskWorkflowLauncherPreview(name: manifest.name, keyword: keyword, query: test.input.query,
                                           result: test, output: manifest.output, timeout: manifest.timeout)
            } else if let reply = lastReply {
                Text(reply).font(.system(size: 12)).foregroundStyle(StudioTheme.textSecondary).lineLimit(5)
            }
            if let risks = model.latestProposal?.risks, !risks.isEmpty {
                AskWorkflowRiskChips(risks: risks.sorted(), new: [], showsAbsent: false)
            }
        }
    }

    /// The latest thing the assistant did, as a sentence.
    private var currentStep: String {
        steps.last.map { L("ask.workflow.editor.new.after", $0) } ?? L("ask.workflow.assistant.working")
    }

    private var steps: [String] {
        model.assistant.items.compactMap { item -> String? in
            guard case let .tool(_, summary, _) = item else { return nil }
            return summary
        }
    }

    /// "Version 2 · 4/5 passed".
    private func versionText(_ proposal: AskWorkflowProposal) -> String {
        let version = L("ask.workflow.editor.new.version", model.proposalNumber(proposal.id))
        guard !proposal.tests.isEmpty else { return version }
        return version + " · " + L("ask.workflow.editor.new.passed",
                                   proposal.tests.filter(\.succeeded).count, proposal.tests.count)
    }

    private var lastReply: String? {
        for item in model.assistant.items.reversed() {
            if case let .reply(_, text) = item {
                return text
            }
        }
        return nil
    }
}

extension AskWorkflowNewSheet {
    // MARK: - From a template

    private var templateTiles: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
            ForEach(AskWorkflowTemplate.allCases) { item in
                tile(Tile(runtime: item.runtime.title, title: L("ask.workflow.editor.new.tile." + item.rawValue),
                          detail: L("ask.workflow.editor.new.tileDetail." + item.rawValue),
                          code: Self.snippet(item.script)),
                     selected: mode == .template && template == item) {
                    mode = .template
                    template = item
                }
            }
            if let source = model.workflow, let manifest = source.manifest {
                tile(Tile(runtime: L("ask.workflow.editor.new.copyBadge"),
                          title: L("ask.workflow.editor.duplicateTitle"),
                          detail: L("ask.workflow.editor.new.duplicateHint", manifest.name),
                          code: source.id + " → " + (id.isEmpty ? source.id + "-2" : id)),
                     selected: mode == .duplicate) {
                    mode = .duplicate
                    if name.isEmpty {
                        name = manifest.name + " " + L("ask.workflow.editor.new.copySuffix")
                    }
                }
            }
        }
    }

    /// The first lines of a template's script that are not comments.
    static func snippet(_ script: String) -> String {
        script.components(separatedBy: "\n")
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return !trimmed.isEmpty && !trimmed.hasPrefix("#") && !trimmed.hasPrefix("//")
                    && !trimmed.hasPrefix("import ")
            }
            .suffix(2).joined(separator: "\n")
    }

    /// What a start tile shows: its runtime, name, what it does and a bit of its code.
    struct Tile {
        var runtime: String
        var title: String
        var detail: String
        var code: String
    }

    private func tile(_ tile: Tile, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    AskWorkflowBadge(text: tile.runtime, color: .blue)
                    Text(tile.title).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                }
                Text(tile.detail).font(.system(size: 11.5)).foregroundStyle(StudioTheme.textTertiary)
                    .lineLimit(2).frame(height: 30, alignment: .topLeading)
                Text(tile.code).font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(StudioTheme.textSecondary)
                    .lineLimit(2).frame(maxWidth: .infinity, minHeight: 34, alignment: .topLeading)
                    .padding(7).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            }
            .padding(11)
            .background(
                selected ? StudioTheme.accentSoft : StudioTheme.controlSurface,
                in: RoundedRectangle(cornerRadius: 11)
            )
            .overlay(RoundedRectangle(cornerRadius: 11)
                .strokeBorder(selected ? AskTheme.accent.opacity(0.75) : StudioTheme.border))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Fields and footer

    private var nameFields: some View {
        HStack(alignment: .top, spacing: 12) {
            field(L("ask.workflow.editor.name"), text: $name, placeholder: L("ask.workflow.editor.new.namePlaceholder"))
            VStack(alignment: .leading, spacing: 4) {
                field(L("ask.workflow.trust.keywords"), text: $keyword, placeholder: "fx", mono: true)
                keywordStatus.font(.system(size: 11))
            }
            .frame(width: 160)
            field(L("ask.workflow.editor.new.id"), text: Binding(get: { id }, set: { id = $0; editedID = true }),
                  placeholder: "local.workflow", mono: true)
        }
    }

    @ViewBuilder private var keywordStatus: some View {
        if !keyword.isEmpty {
            if let problem = keywordProblem {
                Text(problem).foregroundStyle(StudioTheme.danger).lineLimit(2)
            } else {
                Label(L("ask.workflow.editor.new.keywordFree"), systemImage: "checkmark")
                    .foregroundStyle(StudioTheme.success)
            }
        }
    }

    private var footer: some View {
        HStack(alignment: .center) {
            if !generating {
                Text(footnote).font(.system(size: 11.5)).foregroundStyle(StudioTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if generating {
                if model.assistant.isBusy {
                    Button(L("ask.workflow.assistant.stop")) { model.assistant.stop() }
                } else if model.canSaveGenerated {
                    Button(L("ask.workflow.editor.new.adjust")) { done() }
                        .accessibilityIdentifier("ask.workflow.editor.new.review")
                    Button(L("ask.workflow.editor.new.save")) {
                        if model.saveGenerated() {
                            done()
                        }
                    }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .tint(AskWorkflowEditorStyle.assistant)
                    .accessibilityIdentifier("ask.workflow.editor.new.save")
                } else {
                    Button(L("ask.workflow.editor.close")) { done() }
                }
            } else {
                Button(L("ask.workflow.cancel"), action: done).keyboardShortcut(.cancelAction)
                Button(mode == .assistant ? L("ask.workflow.editor.new.generate") :
                    L("ask.workflow.editor.new.create")) {
                        create()
                    }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .tint(mode == .assistant ? AskWorkflowEditorStyle.assistant : AskTheme.accent)
                    .disabled(!canCreate)
                    .accessibilityIdentifier("ask.workflow.editor.new.create")
            }
        }
        .padding(.top, 4)
    }

    private var footnote: String {
        switch mode {
        case .assistant: L("ask.workflow.editor.new.aiFootnote")
        case .template, .duplicate: L("ask.workflow.editor.new.footnote")
        }
    }

    private func field(_ title: String, text: Binding<String>, placeholder: String, mono: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 11)).foregroundStyle(StudioTheme.textTertiary)
            TextField(placeholder, text: text).textFieldStyle(.roundedBorder)
                .font(mono ? .system(size: 12.5, design: .monospaced) : .system(size: 12.5))
        }
    }

    private var keywordProblem: String? {
        model.store.keywordProblem(keyword, builtIn: model.builtInKeywords)
    }

    private var generatedID: String {
        model.store.suggestedID(for: keyword.isEmpty ? "workflow" : keyword)
    }

    private var canCreate: Bool {
        if mode == .assistant {
            // The assistant picks a keyword when none is given.
            return (keyword.isEmpty || keywordProblem == nil)
                && !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !keyword.isEmpty, keywordProblem == nil else { return false }
        return AskWorkflowManifest.isValidID(id)
    }

    private func create() {
        let finalName = name.trimmingCharacters(in: .whitespaces)
        switch mode {
        case .assistant:
            // The assistant names it; the id follows the keyword until then.
            if model.generate(description: description, name: finalName, keyword: keyword, id: generatedID,
                              runtime: runtime) {
                generating = true
            }
        case .template:
            if model.create(template, name: finalName, keyword: keyword, id: id) {
                done()
            }
        case .duplicate:
            if model.duplicate(model.workflowID ?? "", name: finalName, keyword: keyword, id: id) {
                done()
            }
        }
    }
}
