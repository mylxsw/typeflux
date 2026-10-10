import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// What settings says about a workflow, kept apart from the view so it can be tested.
struct AskWorkflowSummary: Equatable {
    var title: String
    var runtime: String?
    var description: String
    var notices: [String]
    var lastRun: String?
    var lastRunFailed: Bool
    var keywords: [String]
    var status: String
    var level: AgentCapabilityStatus.Level
    /// The workflow waits for the user to look at it and trust it.
    var needsTrust: Bool

    /// Healthy and disabled states are already conveyed by the switch.
    var showsStatus: Bool {
        level == .attention
    }

    var runNotice: String? {
        lastRunFailed ? L("ask.workflow.lastRun.failed") : nil
    }

    init(_ workflow: AskWorkflow, conflicts: [AskKeyword] = [], lastRun: AskWorkflowLog.Entry? = nil) {
        let name = workflow.manifest?.name ?? ""
        title = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? workflow.id : name
        runtime = workflow.manifest?.command.runtime.title
        keywords = workflow.manifest?.keywords.map(\.keyword) ?? []
        needsTrust = workflow.status == .untrusted || workflow.status == .modified
        switch workflow.status {
        case .ready: (status, level) = (L("ask.workflow.status.ready"), .ready)
        case .untrusted: (status, level) = (L("ask.workflow.status.untrusted"), .attention)
        case .modified: (status, level) = (L("ask.workflow.status.modified"), .attention)
        case .invalid: (status, level) = (L("ask.workflow.status.invalid"), .attention)
        case .disabled: (status, level) = (L("ask.workflow.status.disabled"), .off)
        }
        description = workflow.manifest?.description ?? ""
        notices = []
        if case let .invalid(problems) = workflow.status {
            notices = problems.map { "\($0.field): \($0.message)" }
        }
        let clashing = conflicts.filter { $0.pluginID == AskWorkflowPlugin.idPrefix + workflow.id }.map(\.keyword)
        if !clashing.isEmpty {
            notices.append(L("ask.workflow.conflicts", clashing.joined(separator: ", ")))
        }
        self.lastRun = lastRun.map {
            $0.timedOut ? L("ask.workflow.lastRun.timedOut", $0.duration)
                : L("ask.workflow.lastRun", Int($0.exitCode), $0.duration)
        }
        lastRunFailed = lastRun.map { $0.timedOut || $0.exitCode != 0 } ?? false
    }
}

/// What the trust sheet shows before a workflow may run: what starts it, the
/// command it runs, what it receives, and every file in it.
struct AskWorkflowTrustSummary: Equatable {
    var keywords: [String]
    var command: String
    var selection: String
    /// What runs after a run: "Copy to clipboard: {output.line1}"; empty when nothing does.
    var actions: [String]
    var files: [String]
    var preview: String

    static let previewLines = 40

    init(_ workflow: AskWorkflow, fileManager: FileManager = .default) {
        let manifest = workflow.manifest
        // A keyword with its own entry says which file it runs: "rate → table.py".
        keywords = (manifest?.keywords ?? []).map { keyword in
            keyword.script.map { keyword.keyword + " → " + $0 } ?? keyword.keyword
        }
        if let manifest {
            let program = manifest.command.interpreter ?? manifest.command.runtime.interpreterName
            let target = manifest.command.script ?? L("ask.workflow.trust.inline")
            command = ([program, target].compactMap(\.self) + manifest.argumentTemplate).joined(separator: " ")
                + " · " + L("ask.workflow.trust.timeout", Int(manifest.timeout))
            switch manifest.input.selection {
            case .never: selection = L("ask.workflow.trust.selection.never")
            case .ifEmpty: selection = L("ask.workflow.trust.selection.ifEmpty")
            case .always: selection = L("ask.workflow.trust.selection.always")
            }
        } else {
            command = ""
            selection = ""
        }
        actions = Self.actions(manifest?.output)
        let root = workflow.folder.standardizedFileURL.path
        let enumerator = fileManager.enumerator(at: workflow.folder, includingPropertiesForKeys: [.isRegularFileKey])
        var files: [String] = []
        while let url = enumerator?.nextObject() as? URL {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
               url.lastPathComponent != ".DS_Store" {
                files.append(String(url.standardizedFileURL.path.dropFirst(root.count + 1)))
            }
        }
        self.files = files.sorted()
        let script = manifest?.command.inline ?? manifest?.command.script
            .flatMap { AskWorkflowManifest.scriptURL($0, in: workflow.folder) }
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        preview = script.split(separator: "\n", omittingEmptySubsequences: false).prefix(Self.previewLines)
            .joined(separator: "\n")
    }

    /// Each configured action as one line, success ones first, failure ones marked.
    static func actions(_ output: AskWorkflowManifest.Output?) -> [String] {
        guard let output else { return [] }
        func line(_ action: AskWorkflowAction) -> String {
            let main = action.kind.flatMap { action[$0.requiredField] } ?? ""
            let title = action.kind?.title ?? action.action
            return main.isEmpty ? title : title + ": " + main
        }
        // Actions the script adds are not in the manifest: say that it may add them.
        return output.onSuccess.map(line)
            + output.onFailure.map { L("ask.workflow.trust.onFailure", line($0)) }
            + (output.scriptActions ? [L("ask.workflow.trust.scriptActions")] : [])
    }
}

/// Settings → Launcher → Workflows: installed workflows, creation tools and the trust sheet.
struct AskWorkflowSettingsView: View {
    @ObservedObject var store: AskWorkflowStore
    @ObservedObject var log: AskWorkflowLog = .shared
    let settings: SettingsStore

    @State private var reviewing: AskWorkflow?
    @State private var failure: String?
    @State private var showingGallery = false
    @State private var deleting: AskWorkflow?
    @State private var runDetails: AskWorkflowRunDetails?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            ModelSurface { list }
        }
        .onAppear { store.reload() }
        .sheet(isPresented: $showingGallery) {
            AskWorkflowGallerySheet(
                store: store,
                builtIn: settings.effectiveAskLauncherKeywords(reserving: store.workflows),
                open: { id in
                    showingGallery = false
                    AskWorkflowEditorWindowController.shared.show(workflowID: id)
                },
                done: { showingGallery = false }
            )
        }
        .sheet(item: $reviewing) { workflow in
            AskWorkflowTrustSheet(workflow: workflow, summary: AskWorkflowTrustSummary(workflow),
                                  onTrust: { store.trust(workflow.id); reviewing = nil },
                                  onReveal: { NSWorkspace.shared.activateFileViewerSelecting([workflow.folder]) },
                                  onCancel: { reviewing = nil })
        }
        .sheet(item: $runDetails) { $0 }
        .confirmationDialog(L("ask.workflow.editor.deleteTitle", deleting?.manifest?.name ?? deleting?.id ?? ""),
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            presenting: deleting) { workflow in
            Button(L("ask.workflow.delete"), role: .destructive) {
                delete(workflow)
                deleting = nil
            }
            Button(L("common.cancel"), role: .cancel) { deleting = nil }
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            if store.workflows.isEmpty {
                AskWorkflowGalleryStarter(store: store, gallery: .bundled,
                                          builtIn: settings.effectiveAskLauncherKeywords(reserving: store.workflows),
                                          browse: { showingGallery = true },
                                          open: { AskWorkflowEditorWindowController.shared.show(workflowID: $0) })
                ModelRowDivider(leading: 18)
            }
            let builtIn = settings.effectiveAskLauncherKeywords(reserving: store.workflows)
            let conflicts = AskWorkflowStore.keywords(of: store.plugins { (nil, nil) }, excluding: builtIn).conflicts
            ForEach(Array(store.workflows.enumerated()), id: \.element.id) { index, workflow in
                if index > 0 { ModelRowDivider(leading: 66) }
                row(
                    workflow,
                    summary: AskWorkflowSummary(workflow, conflicts: conflicts, lastRun: log.last(for: workflow.id))
                )
            }
            if let failure {
                Text(failure).font(.system(size: 11.5)).foregroundStyle(StudioTheme.warning)
                    .padding(.horizontal, 18).padding(.vertical, 6)
            }
        }
    }

    /// The pane title and its actions share a header, with a two-line fallback for narrow panes.
    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 0) {
                paneTitle.fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 12)
                actions
            }
            VStack(alignment: .leading, spacing: 10) {
                paneTitle
                HStack { Spacer(minLength: 0); actions }
            }
        }
    }

    private var paneTitle: some View {
        AgentPaneHeader(symbol: LauncherSettingsPane.workflows.symbol, title: LauncherSettingsPane.workflows.title)
    }

    private var actions: some View {
        HStack(spacing: 8) {
            galleryButton
            maintenanceMenu
            creationMenu
        }
        .fixedSize()
    }

    private var galleryButton: some View {
        Button { showingGallery = true } label: {
            Label(L("ask.workflow.gallery.title"), systemImage: "square.grid.2x2")
        }
        .buttonStyle(ModelActionStyle())
        .accessibilityIdentifier("ask.workflow.gallery")
    }

    private var creationMenu: some View {
        SettingsActionMenu(title: L("ask.workflow.new"), symbol: "plus", primary: true,
                           identifier: "ask.workflow.new", items: [
                            .action(L("ask.workflow.editor.new.ai"), symbol: "sparkles", {
                                AskWorkflowEditorWindowController.shared.showNew(.assistant)
                            }),
                            .separator
                           ] + AskWorkflowTemplate.allCases.map { template in
                            .action(template.title, { create(template) })
                           })
        .fixedSize()
    }

    private var maintenanceMenu: some View {
        SettingsActionMenu(title: L("ask.workflow.manage"), identifier: "ask.workflow.manage", items: [
            .action(L("ask.workflow.editor.openWindow"), { AskWorkflowEditorWindowController.shared.show() }),
            .separator,
            .action(L("ask.workflow.revealFolder"), { store.revealRoot() }),
            .action(L("ask.workflow.reload"), { store.reload() })
        ])
        .fixedSize()
    }

    private func row(_ workflow: AskWorkflow, summary: AskWorkflowSummary) -> some View {
        AskWorkflowSettingsRow(symbol: workflow.symbol, summary: summary,
                               edit: { AskWorkflowEditorWindowController.shared.show(workflowID: workflow.id) },
                               review: summary.needsTrust ? { reviewing = workflow } : nil,
                               fix: repairAction(workflow), viewLastRun: {
                                   if let entry = log.last(for: workflow.id) {
                                       runDetails = AskWorkflowRunDetails(title: summary.title, entry: entry)
                                   }
                               }, controls: {
                                   Toggle("", isOn: Binding(get: { workflow.status == .ready },
                                                            set: { store.setEnabled(workflow.id, $0) }))
                                       .labelsHidden().toggleStyle(.switch).controlSize(.small)
                                       .disabled(summary.showsStatus)
                                       .help(summary.needsTrust ? L("ask.workflow.review") : summary.status)
                                       .accessibilityLabel(L("ask.settings.keywords.enabled"))
                                       .accessibilityIdentifier("ask.workflow.enabled." + workflow.id)
                               })
                               .contextMenu {
                                   Button(L("ask.workflow.editor.openInEditor")) {
                                       AskWorkflowEditorWindowController.shared.show(workflowID: workflow.id)
                                   }
                                   Button(L("ask.workflow.openEditor")) { open(workflow) }
                                   Button(L("ask.workflow.reveal")) {
                                       NSWorkspace.shared.activateFileViewerSelecting([workflow.folder])
                                   }
                                   Divider()
                                   Button(L("ask.workflow.delete"), role: .destructive) { deleting = workflow }
                               }
    }

    private func repairAction(_ workflow: AskWorkflow) -> (() -> Void)? {
        guard case let .invalid(problems) = workflow.status else { return nil }
        return {
            let line = AskWorkflowDraft.load(folder: workflow.folder).line(for: problems.first?.field ?? "")
            AskWorkflowEditorWindowController.shared.show(
                workflowID: workflow.id, path: AskWorkflowManifest.fileName, line: line
            )
        }
    }

    private func create(_ template: AskWorkflowTemplate) {
        do {
            let created = try store.create(
                template,
                takenKeywords: settings.effectiveAskLauncherKeywords(reserving: store.workflows)
            )
            failure = nil
            AskWorkflowEditorWindowController.shared.show(workflowID: created.id)
        } catch {
            failure = error.localizedDescription
        }
    }

    /// Opens the script (or the manifest) in the app the user edits it with.
    private func open(_ workflow: AskWorkflow) {
        let script = workflow.manifest?.command.script
            .flatMap { AskWorkflowManifest.scriptURL($0, in: workflow.folder) }
        let file = script ?? workflow.folder.appendingPathComponent(AskWorkflowManifest.fileName)
        // Scripts are executable: open them in the text editor, never in whatever would run them.
        let editor = NSWorkspace.shared.urlForApplication(toOpen: UTType.plainText)
        if let editor {
            NSWorkspace.shared.open([file, workflow.folder.appendingPathComponent(AskWorkflowManifest.fileName)],
                                    withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([file])
        }
    }

    private func delete(_ workflow: AskWorkflow) {
        do { try store.delete(workflow.id); failure = nil } catch { failure = error.localizedDescription }
    }
}

/// The sheet shown before a workflow may run for the first time, or again after its files changed.
struct AskWorkflowTrustSheet: View {
    let workflow: AskWorkflow
    let summary: AskWorkflowTrustSummary
    var onTrust: () -> Void
    var onReveal: () -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: workflow.symbol).font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white).frame(width: 44, height: 44)
                    .background(AskTheme.accent, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text(L(
                        workflow.status == .modified ? "ask.workflow.trust.modifiedTitle" : "ask.workflow.trust.title",
                        workflow.manifest?.name ?? workflow.id
                    ))
                    .font(.system(size: 15, weight: .semibold))
                    Text(L("ask.workflow.trust.warning")).font(.system(size: 12))
                        .foregroundStyle(StudioTheme.textSecondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(alignment: .leading, spacing: 0) {
                fact("keyboard", L("ask.workflow.trust.keywords"), summary.keywords.joined(separator: "  "))
                fact("play", L("ask.workflow.trust.command"), summary.command, monospaced: true)
                fact("text.quote", L("ask.workflow.trust.selection"), summary.selection)
                if !summary.actions.isEmpty {
                    fact("bolt", L("ask.workflow.trust.actions"), summary.actions.joined(separator: "\n"))
                }
                fact("doc.on.doc", L("ask.workflow.trust.files"), summary.files.joined(separator: " · "))
            }
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(StudioTheme.border))
            ScrollView {
                Text(summary.preview).font(.system(size: 11.5, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled).padding(10)
            }
            .frame(height: 180)
            .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
            .accessibilityLabel(L("ask.workflow.trust.code"))
            HStack {
                Spacer()
                Button(L("ask.workflow.cancel"), action: onCancel).keyboardShortcut(.cancelAction)
                Button(L("ask.workflow.reveal"), action: onReveal)
                Button(L("ask.workflow.trust.confirm"), action: onTrust)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("ask.workflow.trust.confirm")
            }
        }
        .padding(20)
        .frame(width: 600)
    }

    private func fact(_ symbol: String, _ title: String, _ value: String, monospaced: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol).frame(width: 18).foregroundStyle(StudioTheme.textSecondary)
            Text(title).font(.system(size: 12.5)).frame(width: 90, alignment: .leading)
            Text(value).font(.system(size: 12, design: monospaced ? .monospaced : .default))
                .foregroundStyle(StudioTheme.textSecondary).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }
}
