import AppKit
import SwiftUI

/// The workflow editor window: workflows on the left, the flow strip and the step
/// being edited in the middle, the assistant and test runs on the right.
/// See `docs/design/ask-workflow-editor.md` §2.
struct AskWorkflowEditorView: View {
    @ObservedObject var model: AskWorkflowEditorModel
    @ObservedObject var store: AskWorkflowStore
    @State private var creating: AskWorkflowNewSheet.Mode?
    @State private var reviewing: AskWorkflow?
    @State private var confirmingDelete = false
    @State private var panel: Panel
    @State private var showsPanel = true

    enum Panel: String { case assistant, test }

    init(model: AskWorkflowEditorModel, store: AskWorkflowStore, panel: Panel = .assistant) {
        self.model = model
        self.store = store
        _panel = State(initialValue: panel)
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            banners
            HStack(spacing: 0) {
                AskWorkflowEditorSidebar(model: model, store: store, create: { creating = $0 })
                    .frame(width: 214)
                Divider()
                Group {
                    if model.draft != nil {
                        AskWorkflowEditorCenter(model: model)
                    } else {
                        empty
                    }
                }
                .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
                if showsPanel, model.draft != nil {
                    Divider()
                    rightPanel.frame(width: 360)
                }
            }
        }
        .frame(minWidth: 960, minHeight: 560)
        .background(StudioTheme.windowBackground)
        .sheet(item: $creating) { mode in
            AskWorkflowNewSheet(model: model, mode: mode) { creating = nil }
        }
        .sheet(item: $reviewing) { workflow in
            AskWorkflowTrustSheet(workflow: workflow, summary: AskWorkflowTrustSummary(workflow),
                                  onTrust: { model.trust(); reviewing = nil },
                                  onReveal: { NSWorkspace.shared.activateFileViewerSelecting([workflow.folder]) },
                                  onCancel: { reviewing = nil })
        }
        .confirmationDialog(L("ask.workflow.editor.deleteTitle", model.draft?.manifest?.name ?? model.workflowID ?? ""),
                            isPresented: $confirmingDelete) {
            Button(L("ask.workflow.delete"), role: .destructive) { model.delete() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .askWorkflowEditorCreate)) { note in
            creating = (note.object as? AskWorkflowNewSheet.Mode) ?? .assistant
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            if let draft = model.draft {
                Image(systemName: model.workflow?.symbol ?? "sparkles")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(AskTheme.accent, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(draft.manifest?.name ?? model.workflowID ?? L("ask.workflow.editor.newTitle"))
                        .font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
                    Text([draft.manifest?.id, draft.manifest?.version].compactMap(\.self).joined(separator: " · "))
                        .font(.system(size: 11)).foregroundStyle(StudioTheme.textTertiary).lineLimit(1)
                }
                if let runtime = draft.manifest?.command.runtime.title {
                    badge(runtime, color: .blue)
                }
                statusBadge
                Spacer()
                if draft.isDirty {
                    Label(L("ask.workflow.editor.unsaved"), systemImage: "circle.fill")
                        .labelStyle(.titleAndIcon).font(.system(size: 11.5))
                        .foregroundStyle(StudioTheme.textSecondary).imageScale(.small)
                } else {
                    Text(L("ask.workflow.editor.saved")).font(.system(size: 11.5))
                        .foregroundStyle(StudioTheme.textTertiary)
                }
                Button(L("ask.workflow.editor.save")) { model.save() }
                    .keyboardShortcut("s", modifiers: .command)
                    .accessibilityIdentifier("ask.workflow.editor.save")
                Button {
                    panel = .test
                    showsPanel = true
                    model.runTest()
                } label: {
                    Label(L("ask.workflow.editor.test.run"), systemImage: "play.fill")
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model.isTesting || model.generation != nil)
                Menu {
                    Button(L("ask.workflow.editor.togglePanel")) { showsPanel.toggle() }
                        .keyboardShortcut("t", modifiers: [.command, .option])
                    if let folder = model.folder {
                        Button(L("ask.workflow.reveal")) { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
                    }
                    if model.workflow != nil {
                        Button(L("ask.workflow.editor.openExternal")) { openExternally() }
                        Button(L("ask.workflow.editor.duplicate")) { creating = .duplicate }
                        Divider()
                        Button(L("ask.workflow.delete"), role: .destructive) { confirmingDelete = true }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel(L("ask.workflow.more"))
                if let id = model.workflowID, model.generation == nil {
                    Toggle("", isOn: Binding(get: { store.isEnabled(id) }, set: { store.setEnabled(id, $0) }))
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                        .accessibilityLabel(L("ask.settings.keywords.enabled"))
                }
            } else {
                Text(L("ask.workflow.editor.title")).font(.system(size: 13.5, weight: .semibold))
                Spacer()
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 50)
    }

    @ViewBuilder private var statusBadge: some View {
        if model.generation != nil {
            badge(L("ask.workflow.editor.status.generating"), color: .purple)
        } else if !model.problems.isEmpty {
            badge(L("ask.workflow.editor.status.problems", model.problems.count), color: .red)
        } else if let workflow = model.workflow {
            switch workflow.status {
            case .ready: badge(L("ask.workflow.editor.status.ready"), color: .green)
            case .untrusted, .modified: badge(L("ask.workflow.status.modified"), color: .orange)
            case .disabled: badge(L("ask.workflow.status.disabled"), color: .gray)
            case .invalid: badge(L("ask.workflow.status.invalid"), color: .red)
            }
        }
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text).font(.system(size: 11, weight: .semibold)).foregroundStyle(color)
            .padding(.horizontal, 7).frame(height: 20)
            .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    // MARK: - Banners

    @ViewBuilder private var banners: some View {
        if let message = model.message {
            banner(symbol: "exclamationmark.circle", text: message, tint: StudioTheme.warning) {
                Button(L("ask.workflow.editor.dismiss")) { model.message = nil }
            }
        }
        if model.outsideChange != nil {
            banner(
                symbol: "exclamationmark.triangle",
                text: L("ask.workflow.editor.outside"),
                tint: StudioTheme.warning
            ) {
                Button(L("ask.workflow.editor.outside.keepMine")) { model.keepMine() }
                Button(L("ask.workflow.editor.outside.loadTheirs")) { model.loadTheirs() }
                Button(L("ask.workflow.editor.outside.diff")) { model.showingDiff.toggle() }
            }
        } else if model.needsTrust, let workflow = model.workflow {
            banner(symbol: "lock.shield", text: L("ask.workflow.editor.needsTrust"), tint: StudioTheme.warning) {
                Button(L("ask.workflow.review")) { reviewing = workflow }
                    .accessibilityIdentifier("ask.workflow.editor.review")
            }
        }
        if model.generation != nil {
            banner(symbol: "sparkles", text: L("ask.workflow.editor.generationNotice"), tint: .purple) {
                Button(L("ask.workflow.editor.saveGenerated")) { model.save() }
                    .disabled(!model.problems.isEmpty || model.assistant.isBusy)
            }
        }
        if model.canUndoProposal {
            banner(symbol: "sparkles", text: L("ask.workflow.editor.proposalApplied"), tint: .purple) {
                Button(L("ask.workflow.editor.undoProposal")) { model.undoProposal() }
            }
        }
    }

    private func banner(symbol: String, text: String, tint: Color,
                        @ViewBuilder actions: () -> some View) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: symbol).foregroundStyle(tint)
                Text(text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                Spacer()
                actions()
            }
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(tint.opacity(0.10))
            Divider()
        }
    }

    // MARK: - Panels

    private var rightPanel: some View {
        VStack(spacing: 0) {
            Picker("", selection: $panel) {
                Label(L("ask.workflow.assistant.title"), systemImage: "sparkles").tag(Panel.assistant)
                Label(L("ask.workflow.editor.test.title"), systemImage: "play.circle").tag(Panel.test)
            }
            .pickerStyle(.segmented).labelsHidden()
            .padding(10)
            Divider()
            switch panel {
            case .assistant: AskWorkflowAssistantPanel(model: model, assistant: model.assistant)
            case .test: AskWorkflowTestPanel(model: model) { panel = .assistant; model.fixWithAssistant() }
            }
        }
        .background(StudioTheme.surface)
    }

    private var empty: some View {
        VStack(spacing: 12) {
            Image(systemName: "square.stack.3d.up").font(.system(size: 34)).foregroundStyle(StudioTheme.textTertiary)
            Text(L("ask.workflow.editor.empty")).foregroundStyle(StudioTheme.textSecondary)
            HStack {
                Button { creating = .assistant } label: {
                    Label(L("ask.workflow.editor.new.ai"), systemImage: "sparkles")
                }
                Button(L("ask.workflow.editor.new.template")) { creating = .template }
            }
        }
    }

    private func openExternally() {
        guard let folder = model.folder, let path = model.selectedFile else { return }
        let file = folder.appendingPathComponent(path)
        // Scripts are executable: open them in the text editor, never in whatever would run them.
        if let editor = NSWorkspace.shared.urlForApplication(toOpen: .plainText) {
            NSWorkspace.shared.open([file], withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration())
        }
    }
}

extension Notification.Name {
    /// Asks an open editor window to show the new-workflow sheet; `object` is the sheet's mode.
    static let askWorkflowEditorCreate = Notification.Name("AskWorkflowEditor.create")
}

/// Workflows, their status, and the open workflow's files.
struct AskWorkflowEditorSidebar: View {
    @ObservedObject var model: AskWorkflowEditorModel
    @ObservedObject var store: AskWorkflowStore
    var create: (AskWorkflowNewSheet.Mode) -> Void
    @State private var newFile = ""
    @State private var addingFile = false
    @State private var switching: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField(L("ask.workflow.editor.search"), text: $model.search)
                .textFieldStyle(.roundedBorder).padding(10)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("ask.workflow.editor.list", store.workflows.count))
                        .font(.system(size: 10.5, weight: .semibold)).foregroundStyle(StudioTheme.textTertiary)
                        .padding(.horizontal, 14).padding(.vertical, 4)
                    if model.generation != nil {
                        row(Row(title: model.draft?.manifest?.name ?? L("ask.workflow.editor.newTitle"),
                                subtitle: L("ask.workflow.editor.status.generating"), symbol: "sparkles", dot: .purple,
                                selected: true)) {}
                        files
                    }
                    ForEach(model.filteredWorkflows) { workflow in
                        let selected = workflow.id == model.workflowID && model.generation == nil
                        row(Row(title: workflow.manifest?.name ?? workflow.id,
                                subtitle: (workflow.manifest?.keywords ?? []).map(\.keyword).joined(separator: " · "),
                                symbol: workflow.symbol, dot: Self.color(workflow.status), selected: selected)) {
                            // A dirty draft or an unsaved generated workflow is settled first.
                            if model.isDirty || model.generation != nil, !selected {
                                switching = workflow.id
                            } else if !selected {
                                model.open(workflow.id)
                            }
                        }
                        if selected {
                            files
                        }
                    }
                }
            }
            Divider()
            HStack {
                Menu {
                    Button { create(.assistant) } label: { Label(
                        L("ask.workflow.editor.new.ai"),
                        systemImage: "sparkles"
                    ) }
                    Button(L("ask.workflow.editor.new.template")) { create(.template) }
                    if model.workflow != nil {
                        Button(L("ask.workflow.editor.duplicate")) { create(.duplicate) }
                    }
                } label: {
                    Label(L("ask.workflow.editor.new"), systemImage: "plus")
                }
                .menuStyle(.borderlessButton).fixedSize()
                .accessibilityIdentifier("ask.workflow.editor.new")
                Spacer()
                Button { store.revealRoot() } label: { Image(systemName: "folder") }
                    .buttonStyle(.borderless).help(L("ask.workflow.revealFolder"))
            }
            .font(.system(size: 12)).padding(10)
        }
        .background(StudioTheme.surfaceMuted)
        .confirmationDialog(L("ask.workflow.editor.unsavedTitle"), isPresented: Binding(get: { switching != nil },
                                                                                        set: {
                                                                                            if !$0 {
                                                                                                switching = nil
                                                                                            }
                                                                                        })) {
            Button(L("ask.workflow.editor.save")) {
                if model.save(), let id = switching {
                    model.open(id)
                }
                switching = nil
            }
            Button(L("ask.workflow.editor.discard"), role: .destructive) {
                if let id = switching {
                    model.open(id)
                }
                switching = nil
            }
        }
        .alert(L("ask.workflow.editor.addFile"), isPresented: $addingFile) {
            TextField("helper.py", text: $newFile)
            Button(L("ask.workflow.editor.add")) { model.addFile(newFile); newFile = "" }
            Button(L("ask.workflow.cancel"), role: .cancel) { newFile = "" }
        }
    }

    private var files: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(model.draft?.paths ?? [], id: \.self) { path in
                let selected = model.selectedFile == path
                Button {
                    model.selectedFile = path
                    model.step = path == AskWorkflowManifest.fileName ? .keywords : .script
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: path == AskWorkflowManifest.fileName ? "gearshape" : "doc.text")
                            .font(.system(size: 10.5)).frame(width: 14)
                        Text(path == AskWorkflowManifest.fileName ? L("ask.workflow.editor.config") : path)
                            .font(.system(size: 11.5)).lineLimit(1)
                        Spacer()
                        if model.draft?.isDirty(path) == true {
                            Circle().fill(Color.orange).frame(width: 6, height: 6)
                        }
                    }
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(selected ? StudioTheme.controlSurface : .clear, in: RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contextMenu {
                    if path != AskWorkflowManifest.fileName {
                        Button(L("ask.workflow.editor.removeFile"), role: .destructive) { model.removeFile(path) }
                    }
                }
            }
            Button { addingFile = true } label: {
                Label(L("ask.workflow.editor.addFile"), systemImage: "plus").font(.system(size: 11))
            }
            .buttonStyle(.borderless).padding(.horizontal, 8).padding(.vertical, 2)
        }
        .padding(.leading, 26).padding(.trailing, 6).padding(.bottom, 4)
    }

    private struct Row {
        var title: String
        var subtitle: String
        var symbol: String
        var dot: Color
        var selected: Bool
    }

    private func row(_ row: Row, action: @escaping () -> Void) -> some View {
        let title = row.title, subtitle = row.subtitle, symbol = row.symbol, dot = row.dot, selected = row.selected
        return Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(
                        AskTheme.accent.opacity(0.85),
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                    )
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).font(.system(size: 12.5)).lineLimit(1)
                    if !subtitle.isEmpty {
                        Text(subtitle).font(.system(size: 10.5)).foregroundStyle(StudioTheme.textTertiary).lineLimit(1)
                    }
                }
                Spacer()
                Circle().fill(dot).frame(width: 7, height: 7)
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(selected ? StudioTheme.accentSoft : .clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
    }

    static func color(_ status: AskWorkflow.Status) -> Color {
        switch status {
        case .ready: .green
        case .untrusted, .modified: .orange
        case .invalid: .red
        case .disabled: .gray
        }
    }
}
