// swiftlint:disable file_length
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
    @State private var editingInfo = false

    enum Panel: String { case assistant, test }

    /// Opens the script step's run settings, for snapshots.
    private let showsRunSettings: Bool
    /// The test panel's first tab, for snapshots.
    private let testTab: AskWorkflowTestPanel.Tab

    init(model: AskWorkflowEditorModel, store: AskWorkflowStore, panel: Panel = .assistant,
         showsRunSettings: Bool = false, testTab: AskWorkflowTestPanel.Tab = .preview) {
        self.model = model
        self.store = store
        self.showsRunSettings = showsRunSettings
        self.testTab = testTab
        _panel = State(initialValue: panel)
    }

    var body: some View {
        HStack(spacing: 0) {
            AskWorkflowEditorSidebar(model: model, store: store, create: { creating = $0 })
                .frame(width: 220)
            Rectangle().fill(ModelVisualStyle.border).frame(width: 1)
            VStack(spacing: 0) {
                header
                Rectangle().fill(ModelVisualStyle.divider).frame(height: 1)
                banners
                HStack(spacing: 0) {
                    Group {
                        if model.draft != nil {
                            AskWorkflowEditorCenter(model: model, showsRunSettings: showsRunSettings)
                        } else {
                            empty
                        }
                    }
                    .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
                    if showsPanel, model.draft != nil {
                        Rectangle().fill(ModelVisualStyle.divider).frame(width: 1)
                        rightPanel.frame(width: 340)
                    }
                }
            }
        }
        .frame(minWidth: 960, minHeight: 560)
        .background(StudioTheme.windowBackground)
        .ignoresSafeArea(.container, edges: .top)
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
        .onReceive(NotificationCenter.default.publisher(for: .askWorkflowEditorReviewTrust)) { _ in
            reviewing = model.workflow
        }
        .onChange(of: model.assistant.items.count) { _ in
            // The assistant answering a "fix" request is worth looking at.
            if model.assistant.isBusy {
                panel = .assistant
            }
        }
    }

    // MARK: - Header

    /// One row with the window's title bar: the workflow, its state, then Save,
    /// Run test (the one primary button), the switch and the menus.
    private var header: some View {
        HStack(spacing: 10) {
            if let draft = model.draft {
                Image(systemName: model.workflow?.symbol ?? "sparkles")
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(AskWorkflowEditorStyle.tileColor(for: model.workflowID ?? "new"),
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                Button { editingInfo = true } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 5) {
                            Text(draft.manifest?.name ?? model.workflowID ?? L("ask.workflow.editor.newTitle"))
                                .font(.system(size: 14, weight: .semibold)).foregroundStyle(StudioTheme.textPrimary)
                                .lineLimit(1)
                            Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(StudioTheme.textTertiary)
                        }
                        Text([draft.manifest?.id, draft.manifest?.version].compactMap(\.self).joined(separator: " · "))
                            .font(.system(size: 11, design: .monospaced)).foregroundStyle(StudioTheme.textTertiary)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(draft.isFormEditable != true)
                .help(L("ask.workflow.editor.info.help"))
                .accessibilityIdentifier("ask.workflow.editor.info")
                .popover(isPresented: $editingInfo, arrowEdge: .bottom) {
                    AskWorkflowInfoForm(model: model) { editingInfo = false }
                }
                statusBadge
                Spacer()
                if model.unsavedLabel != nil {
                    HStack(spacing: 5) {
                        Circle().fill(Color.orange).frame(width: 7, height: 7)
                        Text(L("ask.workflow.editor.unsaved"))
                    }
                    .font(.system(size: 12)).foregroundStyle(StudioTheme.textSecondary)
                    .help(model.unsavedLabel ?? "")
                }
                if model.generation != nil {
                    // A generated workflow is saved into the launcher in one step.
                    Button(L("ask.workflow.editor.new.save")) { model.saveGenerated() }
                        .buttonStyle(AskWorkflowActionStyle(kind: .assistant))
                        .keyboardShortcut("s", modifiers: .command)
                        .disabled(model.assistant.isBusy || !model.canSaveGenerated)
                        .accessibilityIdentifier("ask.workflow.editor.saveGenerated")
                } else {
                    Button { model.save() } label: {
                        HStack(spacing: 6) {
                            Text(L("ask.workflow.editor.save"))
                            AskWorkflowShortcutHint(text: "⌘S")
                        }
                    }
                    .buttonStyle(AskWorkflowActionStyle())
                    .keyboardShortcut("s", modifiers: .command)
                    .help(L("ask.workflow.editor.save") + " ⌘S")
                    .accessibilityIdentifier("ask.workflow.editor.save")
                    Button {
                        panel = .test
                        showsPanel = true
                        model.runTest()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "play.fill").font(.system(size: 10))
                            Text(L("ask.workflow.editor.test.runButton"))
                            AskWorkflowShortcutHint(text: "⌘R")
                        }
                    }
                    .buttonStyle(AskWorkflowActionStyle(kind: .primary))
                    .keyboardShortcut("r", modifiers: .command)
                    .help(L("ask.workflow.editor.test.run") + " ⌘R")
                    .disabled(model.isTesting || !model.problems.isEmpty)
                }
                if let id = model.workflowID, model.generation == nil {
                    Rectangle().fill(ModelVisualStyle.border).frame(width: 1, height: 18).padding(.horizontal, 2)
                    Toggle(isOn: Binding(get: { store.isEnabled(id) }, set: { store.setEnabled(id, $0) })) {
                        Text(L("ask.settings.keywords.enabled")).font(.system(size: 12))
                            .foregroundStyle(StudioTheme.textSecondary)
                    }
                    .toggleStyle(.switch).controlSize(.small)
                    .accessibilityLabel(L("ask.settings.keywords.enabled"))
                }
                moreMenu
                Button { showsPanel.toggle() } label: {
                    Image(systemName: "sidebar.right").font(.system(size: 14))
                        .foregroundStyle(showsPanel ? StudioTheme.textPrimary : StudioTheme.textTertiary)
                        .frame(width: 28, height: 28).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut("t", modifiers: [.command, .option])
                .help(L("ask.workflow.editor.togglePanel") + " ⌥⌘T")
            } else {
                Text(L("ask.workflow.editor.title")).font(.system(size: 14, weight: .semibold))
                Spacer()
            }
        }
        .padding(.leading, 18).padding(.trailing, 14)
        .frame(height: 56)
    }

    private var moreMenu: some View {
        Menu {
            Toggle(L("ask.workflow.assistant.autoTestMenu"), isOn: $model.autoTest)
            Divider()
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
            Image(systemName: "ellipsis").font(.system(size: 14, weight: .semibold))
                .foregroundStyle(StudioTheme.textSecondary)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .frame(width: 28, height: 28)
        .accessibilityLabel(L("ask.workflow.more"))
    }

    @ViewBuilder private var statusBadge: some View {
        if model.generation != nil {
            AskWorkflowBadge(text: L("ask.workflow.editor.status.generating"), color: .purple, symbol: "sparkles")
        } else if !model.problems.isEmpty {
            AskWorkflowBadge(text: L("ask.workflow.editor.status.problems", model.problems.count), color: .red)
        } else if let workflow = model.workflow {
            switch workflow.status {
            case .ready:
                AskWorkflowBadge(text: L("ask.workflow.editor.status.ready"), color: StudioTheme.success,
                                 symbol: "checkmark.shield")
            case .untrusted, .modified: AskWorkflowBadge(text: L("ask.workflow.status.modified"), color: .orange)
            case .disabled: AskWorkflowBadge(text: L("ask.workflow.status.disabled"), color: .gray)
            case .invalid: AskWorkflowBadge(text: L("ask.workflow.status.invalid"), color: .red)
            }
        }
    }
}

extension AskWorkflowEditorView {
    // MARK: - Banners

    @ViewBuilder private var banners: some View {
        if let message = model.message {
            banner(symbol: "exclamationmark.circle", tint: StudioTheme.warning) {
                Text(message)
            } actions: {
                Button(L("ask.workflow.editor.dismiss")) { model.message = nil }
            }
        }
        if let change = model.outsideChange {
            banner(symbol: "exclamationmark.triangle", tint: StudioTheme.warning) {
                outsideText(change)
            } actions: {
                Button(L("ask.workflow.editor.outside.keepMine")) { model.keepMine() }
                Button(L("ask.workflow.editor.outside.loadTheirs")) { model.loadTheirs() }
                Button(L("ask.workflow.editor.outside.diffTrust")) { model.showingDiff = true }
                    .buttonStyle(AskWorkflowActionStyle(kind: .primary, small: true))
            }
        } else if model.needsTrust, let workflow = model.workflow {
            banner(symbol: "lock.shield", tint: StudioTheme.warning) {
                Text(L("ask.workflow.editor.needsTrust"))
            } actions: {
                Button(L("ask.workflow.review")) { reviewing = workflow }
                    .buttonStyle(AskWorkflowActionStyle(kind: .primary, small: true))
                    .accessibilityIdentifier("ask.workflow.editor.review")
            }
        }
        if let id = model.previewingProposal, model.proposal(id)?.state == .pending {
            banner(symbol: "sparkles", tint: AskWorkflowEditorStyle.assistant) {
                Text(L("ask.workflow.editor.previewBanner")).bold()
                    + Text(L("ask.workflow.editor.previewBannerDetail"))
            } actions: {
                Button(L("ask.workflow.assistant.discard")) { model.discard(id) }
                Button(L("ask.workflow.editor.applyToEditor")) { model.apply(id) }
                    .buttonStyle(AskWorkflowActionStyle(kind: .assistant, small: true))
            }
        }
    }

    private func outsideText(_ change: AskWorkflowEditorModel.OutsideChange) -> Text {
        let stats = model.outsideStats
        let files = (stats?.paths ?? [])
            .map { $0 == AskWorkflowManifest.fileName ? L("ask.workflow.editor.config") : $0 }
        return Text(L("ask.workflow.editor.outside.title", files.joined(separator: ", "))).bold()
            + Text(L("ask.workflow.editor.outside.detail", AskWorkflowEditorModel.relative(change.detectedAt),
                     stats?.added ?? 0, stats?.removed ?? 0))
    }

    private func banner(symbol: String, tint: Color, @ViewBuilder text: () -> Text,
                        @ViewBuilder actions: () -> some View) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: symbol).foregroundStyle(tint)
                text().font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                Spacer()
                HStack(spacing: 6) { actions() }.buttonStyle(AskWorkflowActionStyle(small: true))
            }
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(tint.opacity(0.10))
            Divider()
        }
    }

    // MARK: - Panels

    private var rightPanel: some View {
        VStack(spacing: 0) {
            AskWorkflowTabs(items: [
                .init(tab: Panel.assistant, title: L("ask.workflow.assistant.title"), symbol: "sparkles",
                      tint: AskWorkflowEditorStyle.assistant),
                .init(tab: Panel.test, title: L("ask.workflow.editor.test.title"), symbol: "play.fill",
                      badge: model.results.last.map { $0.succeeded ? nil : "●" } ?? nil)
            ], selection: $panel, size: 12.5, fills: true)
                .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 10)
            switch panel {
            case .assistant: AskWorkflowAssistantPanel(model: model, assistant: model.assistant)
            case .test:
                AskWorkflowTestPanel(model: model, tab: testTab) { panel = .assistant; model.fixWithAssistant() }
            }
        }
        .background(StudioTheme.windowBackground)
    }

    private var empty: some View {
        VStack(spacing: 12) {
            Image(systemName: "square.stack.3d.up").font(.system(size: 34)).foregroundStyle(StudioTheme.textTertiary)
            Text(L("ask.workflow.editor.empty")).foregroundStyle(StudioTheme.textSecondary)
            HStack {
                Button { creating = .assistant } label: {
                    Label(L("ask.workflow.editor.new.ai"), systemImage: "sparkles")
                }
                .buttonStyle(AskWorkflowActionStyle(kind: .assistant))
                Button(L("ask.workflow.editor.new.template")) { creating = .template }
                    .buttonStyle(AskWorkflowActionStyle())
            }
        }
    }

    private func openExternally() {
        guard let folder = model.folder, let path = model.selectedFile else { return }
        AskWorkflowEditorView.openInTextEditor(folder.appendingPathComponent(path))
    }

    /// Scripts are executable: open them in the text editor, never in whatever would run them.
    static func openInTextEditor(_ file: URL) {
        if let editor = NSWorkspace.shared.urlForApplication(toOpen: .plainText) {
            NSWorkspace.shared.open([file], withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration())
        }
    }
}

extension Notification.Name {
    /// Asks an open editor window to show the new-workflow sheet; `object` is the sheet's mode.
    static let askWorkflowEditorCreate = Notification.Name("AskWorkflowEditor.create")
    /// Asks the editor window to show the trust sheet for the open workflow.
    static let askWorkflowEditorReviewTrust = Notification.Name("AskWorkflowEditor.reviewTrust")
}

/// Workflows and their status; the open workflow's files are tabs over the code.
struct AskWorkflowEditorSidebar: View {
    @ObservedObject var model: AskWorkflowEditorModel
    @ObservedObject var store: AskWorkflowStore
    var create: (AskWorkflowNewSheet.Mode) -> Void
    @State private var switching: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The window's traffic lights sit here: there is no separate title bar.
            Color.clear.frame(height: 44)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(StudioTheme.textTertiary)
                TextField(L("ask.workflow.editor.search"), text: $model.search).textFieldStyle(.plain)
            }
            .font(.system(size: 12.5)).padding(.horizontal, 9).frame(height: 28)
            .background(ModelVisualStyle.control, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(ModelVisualStyle.border))
            .padding(.horizontal, 12).padding(.bottom, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("ask.workflow.editor.list", store.workflows.count))
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(StudioTheme.textTertiary)
                        .padding(.horizontal, 18).padding(.top, 6).padding(.bottom, 4)
                    if model.generation != nil {
                        row(Row(id: "new", title: model.draft?.manifest?.name ?? L("ask.workflow.editor.newTitle"),
                                subtitle: L("ask.workflow.editor.status.generating"), symbol: "sparkles",
                                dot: .purple, selected: true)) {}
                    }
                    ForEach(model.filteredWorkflows) { workflow in
                        let selected = workflow.id == model.workflowID && model.generation == nil
                        row(Row(id: workflow.id, title: workflow.manifest?.name ?? workflow.id,
                                subtitle: (workflow.manifest?.keywords ?? []).map(\.keyword).joined(separator: " · "),
                                symbol: workflow.symbol, dot: Self.color(workflow.status), selected: selected)) {
                            // A dirty draft or an unsaved generated workflow is settled first.
                            if model.isDirty || model.generation != nil, !selected {
                                switching = workflow.id
                            } else if !selected {
                                model.open(workflow.id)
                            }
                        }
                    }
                }
            }
            Rectangle().fill(ModelVisualStyle.divider).frame(height: 1)
            HStack(spacing: 6) {
                Menu {
                    Button { create(.assistant) } label: {
                        Label(L("ask.workflow.editor.new.ai"), systemImage: "sparkles")
                    }
                    Button(L("ask.workflow.editor.new.template")) { create(.template) }
                    if model.workflow != nil {
                        Button(L("ask.workflow.editor.duplicate")) { create(.duplicate) }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
                        Text(L("ask.workflow.editor.newWorkflow")).font(.system(size: 12.5, weight: .medium))
                    }
                    .foregroundStyle(StudioTheme.textPrimary)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .frame(maxWidth: .infinity).frame(height: 28)
                .background(ModelVisualStyle.control, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(ModelVisualStyle.border))
                .contentShape(Rectangle())
                .accessibilityIdentifier("ask.workflow.editor.new")
                Button { store.revealRoot() } label: {
                    Image(systemName: "folder").font(.system(size: 13)).foregroundStyle(StudioTheme.textSecondary)
                        .frame(width: 28, height: 28).contentShape(Rectangle())
                }
                .buttonStyle(.plain).help(L("ask.workflow.revealFolder"))
            }
            .padding(12)
        }
        .background(StudioTheme.surfaceMuted)
        .confirmationDialog(L("ask.workflow.editor.unsavedTitle"), isPresented: switchingBinding) {
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
    }

    private var switchingBinding: Binding<Bool> {
        Binding(get: { switching != nil }, set: {
            if !$0 {
                switching = nil
            }
        })
    }

    private struct Row {
        var id: String
        var title: String
        var subtitle: String
        var symbol: String
        var dot: Color
        var selected: Bool
    }

    private func row(_ row: Row, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: row.symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(AskWorkflowEditorStyle.tileColor(for: row.id),
                                in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.title).font(.system(size: 13, weight: .medium)).foregroundStyle(StudioTheme.textPrimary)
                        .lineLimit(1)
                    if !row.subtitle.isEmpty {
                        Text(row.subtitle).font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(StudioTheme.textTertiary).lineLimit(1)
                    }
                }
                Spacer()
                Circle().fill(row.dot).frame(width: 7, height: 7)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(row.selected ? StudioTheme.accentSoft : .clear,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
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
