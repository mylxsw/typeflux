import SwiftUI

/// The middle of the editor: the flow strip, then the step being edited — forms
/// for keywords, input and output (or `workflow.json` itself), the code view for scripts.
struct AskWorkflowEditorCenter: View {
    @ObservedObject var model: AskWorkflowEditorModel

    var body: some View {
        VStack(spacing: 0) {
            AskWorkflowFlowStrip(model: model)
            Divider()
            if let id = model.previewingProposal, let proposal = model.proposal(id), let draft = model.draft {
                AskWorkflowDiffView(title: L("ask.workflow.editor.proposalPreview"), old: draft,
                                    new: proposal.applied(to: draft)) {
                    Button(L("ask.workflow.assistant.discard")) { model.discard(id) }
                    Button(L("ask.workflow.assistant.apply")) { model.apply(id) }.buttonStyle(.borderedProminent)
                    Button(L("ask.workflow.editor.close")) { model.previewingProposal = nil }
                }
            } else if model.showingDiff, let change = model.outsideChange, let draft = model.draft {
                AskWorkflowDiffView(title: L("ask.workflow.editor.outside.diffTitle"), old: draft, new: change.disk) {
                    Button(L("ask.workflow.editor.close")) { model.showingDiff = false }
                }
            } else if model.step == .script {
                scriptArea
            } else {
                configArea
            }
            statusBar
        }
    }

    // MARK: - Script

    private var scriptArea: some View {
        VStack(spacing: 0) {
            let paths = (model.draft?.files.keys.sorted() ?? [])
            HStack(spacing: 0) {
                ForEach(paths, id: \.self) { path in
                    tab(path, selected: model.selectedFile == path, dirty: model.draft?.isDirty(path) == true) {
                        model.selectedFile = path
                    }
                }
                Spacer()
            }
            .frame(height: 32)
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
        let markers = model.markers(for: path)
        return VStack(spacing: 0) {
            AskWorkflowCodeView(
                text: Binding(get: { model.draft?.text(of: path) ?? "" }, set: { model.setText($0, of: path) }),
                language: .detect(path: path, runtime: model.draft?.manifest?.command.runtime),
                markers: markers,
                reveal: model.reveal?.path == path ? model.reveal?.line : nil,
                onRevealed: { model.reveal = nil }
            )
            .id(path)
            .clipped()
            if !markers.isEmpty {
                AskWorkflowMarkerList(markers: markers) { line in model.reveal = (path, line) }
            }
        }
    }

    private func tab(_ title: String, selected: Bool, dirty: Bool, action: @escaping () -> Void) -> some View {
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
                if model.configMode == .json {
                    Button(L("ask.workflow.editor.format")) { model.formatManifest() }
                        .disabled(model.draft?.isFormEditable != true)
                } else {
                    Text(L("ask.workflow.editor.synced")).font(.system(size: 11))
                        .foregroundStyle(StudioTheme.textTertiary)
                }
            }
            .padding(.horizontal, 14).frame(height: 38)
            Divider()
            if model.configMode == .json || model.draft?.isFormEditable != true {
                code(AskWorkflowManifest.fileName)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        switch model.step {
                        case .keywords: AskWorkflowKeywordsForm(model: model)
                        case .input: AskWorkflowInputForm(model: model)
                        case .output, .script: AskWorkflowOutputForm(model: model)
                        }
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    // MARK: - Status bar

    private var statusBar: some View {
        HStack(spacing: 14) {
            let problems = model.problems
            if problems.isEmpty {
                Label(L("ask.workflow.editor.noProblems"), systemImage: "checkmark.circle")
                    .foregroundStyle(StudioTheme.success)
            } else {
                Button {
                    if let first = problems.first {
                        model.step = AskWorkflowDraft.step(for: first.field) ?? .keywords
                        model.configMode = .json
                        if let line = model.draft?.line(for: first.field) {
                            model.reveal = (AskWorkflowManifest.fileName, line)
                        }
                    }
                } label: {
                    Label(
                        L(
                            "ask.workflow.editor.problemSummary",
                            problems.count,
                            problems[0].field + ": " + problems[0].message
                        ),
                        systemImage: "xmark.circle"
                    )
                    .lineLimit(1)
                }
                .buttonStyle(.plain).foregroundStyle(StudioTheme.danger)
            }
            Spacer()
            if let folder = model.folder {
                Text(folder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .lineLimit(1).truncationMode(.middle).foregroundStyle(StudioTheme.textTertiary)
            }
        }
        .font(.system(size: 11)).padding(.horizontal, 12).frame(height: 26)
        .background(StudioTheme.surfaceMuted)
    }
}

/// Problems listed under the code, each a link to its line.
struct AskWorkflowMarkerList: View {
    var markers: [Int: String]
    var select: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(markers.keys.sorted(), id: \.self) { line in
                Button { select(line) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "xmark.octagon.fill").foregroundStyle(StudioTheme.danger)
                        Text(L("ask.workflow.editor.lineMessage", line, markers[line] ?? "")).lineLimit(2)
                        Spacer()
                    }
                    .font(.system(size: 11.5)).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(StudioTheme.danger.opacity(0.08))
    }
}

/// Keyword → input → script → output, with a summary of each and a dot on steps with problems.
struct AskWorkflowFlowStrip: View {
    @ObservedObject var model: AskWorkflowEditorModel

    var body: some View {
        let manifest = model.draft?.manifest
        HStack(spacing: 0) {
            node(.keywords, symbol: "keyboard", title: L("ask.workflow.editor.step.keywords"),
                 summary: (manifest?.keywords ?? []).map(\.keyword).joined(separator: "  "), mono: true)
            arrow
            node(
                .input,
                symbol: "text.quote",
                title: L("ask.workflow.editor.step.input"),
                summary: manifest.map(Self.input) ?? ""
            )
            arrow
            node(.script, symbol: "play", title: L("ask.workflow.editor.step.script"),
                 summary: manifest
                     .map {
                         ($0.command.script ?? L("ask.workflow.trust.inline")) + " " + $0.argumentTemplate
                             .joined(separator: " ")
                     } ?? "",
                 mono: true)
            arrow
            node(.output, symbol: "arrow.right.to.line", title: L("ask.workflow.editor.step.output"),
                 summary: manifest.map { L("ask.workflow.editor.output." + $0.output.rawValue) + " · " + L(
                     "ask.workflow.editor.seconds",
                     Int($0.timeout)
                 ) } ?? "")
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }

    static func input(_ manifest: AskWorkflowManifest) -> String {
        L("ask.workflow.editor.argument." + manifest.input.argument.rawValue) + " · "
            + L("ask.workflow.editor.selection." + manifest.input.selection.rawValue)
    }

    private var arrow: some View {
        Image(systemName: "arrow.right").font(.system(size: 10)).foregroundStyle(StudioTheme.textTertiary)
            .frame(width: 20)
    }

    private func node(_ step: AskWorkflowDraft.Step, symbol: String, title: String, summary: String,
                      mono: Bool = false) -> some View {
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
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Image(systemName: symbol).font(.system(size: 9.5))
                    Text(title).font(.system(size: 10.5, weight: .semibold))
                    Spacer()
                    if hasProblems {
                        Circle().fill(StudioTheme.danger).frame(width: 6, height: 6)
                    }
                }
                .foregroundStyle(StudioTheme.textTertiary)
                Text(summary.isEmpty ? "—" : summary)
                    .font(mono ? .system(size: 11.5, design: .monospaced) : .system(size: 12))
                    .lineLimit(1).truncationMode(.tail)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? StudioTheme.accentSoft : StudioTheme.controlSurface,
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(hasProblems ? StudioTheme.danger.opacity(0.6) : selected ? AskTheme.accent : StudioTheme
                    .border))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("ask.workflow.editor.step." + step.rawValue)
    }
}

/// Two versions of a workflow, file by file, line by line.
struct AskWorkflowDiffView<Actions: View>: View {
    var title: String
    var old: AskWorkflowDraft
    var new: AskWorkflowDraft
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.system(size: 12.5, weight: .semibold))
                Spacer()
                actions()
            }
            .padding(.horizontal, 14).frame(height: 40)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(changedPaths, id: \.self) { path in
                        Text(path).font(.system(size: 11.5, weight: .semibold)).padding(.horizontal, 12).padding(
                            .top,
                            10
                        ).padding(.bottom, 4)
                        ForEach(
                            Array(AskWorkflowDiff.lines(old: old.text(of: path) ?? "", new: new.text(of: path) ?? "")
                                .enumerated()),
                            id: \.offset
                        ) { _, line in
                            HStack(spacing: 8) {
                                Text(line.kind == .added ? "+" : line.kind == .removed ? "−" : " ").frame(width: 10)
                                Text(line.text.isEmpty ? " " : line.text).frame(
                                    maxWidth: .infinity,
                                    alignment: .leading
                                )
                            }
                            .font(.system(size: 12, design: .monospaced))
                            .padding(.horizontal, 12).padding(.vertical, 1)
                            .background(line.kind == .added ? Color.green.opacity(0.14)
                                : line.kind == .removed ? Color.red.opacity(0.14) : .clear)
                        }
                    }
                }
                .textSelection(.enabled)
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
    }

    private var changedPaths: [String] {
        Set(old.paths + new.paths).sorted().filter { old.text(of: $0) != new.text(of: $0) }
    }
}
