import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// What settings says about a workflow, kept apart from the view so it can be tested.
struct AskWorkflowSummary: Equatable {
    var title: String
    var runtime: String?
    var subtitle: String
    var keywords: [String]
    var status: String
    var level: AgentCapabilityStatus.Level
    /// The workflow waits for the user to look at it and trust it.
    var needsTrust: Bool

    init(_ workflow: AskWorkflow, conflicts: [AskKeyword] = [], lastRun: AskWorkflowLog.Entry? = nil) {
        title = workflow.manifest?.name ?? workflow.id
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
        var lines: [String] = []
        if case let .invalid(problems) = workflow.status {
            lines += problems.prefix(2).map { "\($0.field): \($0.message)" }
        } else if let description = workflow.manifest?.description, !description.isEmpty {
            lines.append(description)
        }
        let clashing = conflicts.filter { $0.pluginID == AskWorkflowPlugin.idPrefix + workflow.id }.map(\.keyword)
        if !clashing.isEmpty { lines.append(L("ask.workflow.conflicts", clashing.joined(separator: ", "))) }
        if let lastRun {
            lines.append(lastRun.timedOut ? L("ask.workflow.lastRun.timedOut", lastRun.duration)
                : L("ask.workflow.lastRun", Int(lastRun.exitCode), lastRun.duration))
        }
        subtitle = lines.joined(separator: "\n")
    }
}

/// What the trust sheet shows before a workflow may run: what starts it, the
/// command it runs, what it receives, and every file in it.
struct AskWorkflowTrustSummary: Equatable {
    var keywords: [String]
    var command: String
    var selection: String
    var files: [String]
    var preview: String

    static let previewLines = 40

    init(_ workflow: AskWorkflow, fileManager: FileManager = .default) {
        let manifest = workflow.manifest
        keywords = manifest?.keywords.map(\.keyword) ?? []
        if let manifest {
            let program = manifest.command.interpreter ?? manifest.command.runtime.interpreterName
            let target = manifest.command.script ?? L("ask.workflow.trust.inline")
            command = ([program, target].compactMap { $0 } + manifest.argumentTemplate).joined(separator: " ")
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
        let root = workflow.folder.standardizedFileURL.path
        let enumerator = fileManager.enumerator(at: workflow.folder, includingPropertiesForKeys: [.isRegularFileKey])
        var files: [String] = []
        while let url = enumerator?.nextObject() as? URL {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true, url.lastPathComponent != ".DS_Store" {
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
}

/// Settings → Agent → Built-in Tools → launcher workflows: the installed
/// workflows, their state and switches, new ones from templates, and the trust sheet.
struct AskWorkflowSettingsView: View {
    @ObservedObject var store: AskWorkflowStore
    @ObservedObject var log: AskWorkflowLog = .shared
    let settings: SettingsStore

    @State private var reviewing: AskWorkflow?
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if store.workflows.isEmpty {
                AgentSettingsEmptyRow(text: L("ask.workflow.empty"))
                ModelRowDivider(leading: 18)
            }
            let builtIn = settings.effectiveAskLauncherKeywords
            let conflicts = AskWorkflowStore.keywords(of: store.plugins { (nil, nil) }, excluding: builtIn).conflicts
            ForEach(store.workflows) { workflow in
                row(workflow, summary: AskWorkflowSummary(workflow, conflicts: conflicts, lastRun: log.last(for: workflow.id)))
                ModelRowDivider(leading: 66)
            }
            if let failure {
                Text(failure).font(.system(size: 11.5)).foregroundStyle(StudioTheme.warning)
                    .padding(.horizontal, 18).padding(.vertical, 6)
            }
            HStack(spacing: 10) {
                Menu {
                    Button { AskWorkflowEditorWindowController.shared.showNew(.assistant) } label: {
                        Label(L("ask.workflow.editor.new.ai"), systemImage: "sparkles")
                    }
                    Divider()
                    ForEach(AskWorkflowTemplate.allCases) { template in
                        Button(template.title) { create(template) }
                    }
                } label: {
                    Label(L("ask.workflow.new"), systemImage: "plus")
                }
                .menuStyle(.borderlessButton).fixedSize()
                .accessibilityIdentifier("ask.workflow.new")
                Button(L("ask.workflow.editor.openWindow")) { AskWorkflowEditorWindowController.shared.show() }
                    .buttonStyle(.borderless)
                Button(L("ask.workflow.revealFolder")) { store.revealRoot() }
                    .buttonStyle(.borderless)
                Button(L("ask.workflow.reload")) { store.reload() }
                    .buttonStyle(.borderless)
                Spacer()
            }
            .font(.system(size: 12.5))
            .padding(.horizontal, 18).padding(.vertical, 12)
        }
        .onAppear { store.reload() }
        .sheet(item: $reviewing) { workflow in
            AskWorkflowTrustSheet(workflow: workflow, summary: AskWorkflowTrustSummary(workflow),
                                  onTrust: { store.trust(workflow.id); reviewing = nil },
                                  onReveal: { NSWorkspace.shared.activateFileViewerSelecting([workflow.folder]) },
                                  onCancel: { reviewing = nil })
        }
    }

    private func row(_ workflow: AskWorkflow, summary: AskWorkflowSummary) -> some View {
        AgentSettingsRow(icon: workflow.symbol, title: summary.title, subtitle: summary.subtitle,
                         badge: summary.runtime, subtitleLineLimit: 3) {
            HStack(spacing: 8) {
                ForEach(summary.keywords, id: \.self) { keyword in
                    Text(keyword).font(.system(size: 11.5, design: .monospaced))
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(StudioTheme.border))
                }
                AgentStatusBadge(level: summary.level, label: summary.status)
                if summary.needsTrust {
                    Button(L("ask.workflow.review")) { reviewing = workflow }
                        .accessibilityIdentifier("ask.workflow.review")
                }
                if case let .invalid(problems) = workflow.status {
                    // Opens `workflow.json` at the first problem; broken JSON can be fixed there too.
                    Button(L("ask.workflow.editor.fixButton")) {
                        let line = AskWorkflowDraft.load(folder: workflow.folder).line(for: problems.first?.field ?? "")
                        AskWorkflowEditorWindowController.shared.show(
                            workflowID: workflow.id, path: AskWorkflowManifest.fileName, line: line)
                    }
                    .accessibilityIdentifier("ask.workflow.fix")
                } else if !summary.needsTrust {
                    Button(L("ask.workflow.editor.edit")) {
                        AskWorkflowEditorWindowController.shared.show(workflowID: workflow.id)
                    }
                    .accessibilityIdentifier("ask.workflow.edit")
                }
                Menu {
                    Button(L("ask.workflow.editor.openInEditor")) {
                        AskWorkflowEditorWindowController.shared.show(workflowID: workflow.id)
                    }
                    Button(L("ask.workflow.openEditor")) { open(workflow) }
                    Button(L("ask.workflow.reveal")) { NSWorkspace.shared.activateFileViewerSelecting([workflow.folder]) }
                    Divider()
                    Button(L("ask.workflow.delete"), role: .destructive) { delete(workflow) }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel(L("ask.workflow.more"))
                Toggle("", isOn: Binding(get: { store.isEnabled(workflow.id) },
                                         set: { store.setEnabled(workflow.id, $0) }))
                    .labelsHidden().toggleStyle(.switch)
                    .disabled(workflow.manifest == nil)
                    .accessibilityLabel(L("ask.settings.keywords.enabled"))
            }
        }
    }

    private func create(_ template: AskWorkflowTemplate) {
        do {
            let created = try store.create(template, takenKeywords: settings.effectiveAskLauncherKeywords)
            failure = nil
            AskWorkflowEditorWindowController.shared.show(workflowID: created.id)
        } catch {
            failure = error.localizedDescription
        }
    }

    /// Opens the script (or the manifest) in the app the user edits it with.
    private func open(_ workflow: AskWorkflow) {
        let script = workflow.manifest?.command.script.flatMap { AskWorkflowManifest.scriptURL($0, in: workflow.folder) }
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
                    Text(L(workflow.status == .modified ? "ask.workflow.trust.modifiedTitle" : "ask.workflow.trust.title",
                           workflow.manifest?.name ?? workflow.id))
                        .font(.system(size: 15, weight: .semibold))
                    Text(L("ask.workflow.trust.warning")).font(.system(size: 12))
                        .foregroundStyle(StudioTheme.textSecondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(alignment: .leading, spacing: 0) {
                fact("keyboard", L("ask.workflow.trust.keywords"), summary.keywords.joined(separator: "  "))
                fact("play", L("ask.workflow.trust.command"), summary.command, monospaced: true)
                fact("text.quote", L("ask.workflow.trust.selection"), summary.selection)
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
