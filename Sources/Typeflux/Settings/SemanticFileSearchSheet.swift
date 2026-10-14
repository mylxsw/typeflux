import AppKit
import SwiftUI

/// Owns the presented state so the first opening always uses its explicit mode.
struct SemanticFileSearchSheet: View {
    @ObservedObject var service: SemanticFileSearchService
    let pickFolders: () -> [String]?
    let onClose: () -> Void
    @State private var setup: Bool
    @State private var roots: [String]
    @State private var invalidRoot = false
    @State private var deletion: Deletion?
    enum Deletion: String, Identifiable {
        case index, model
        var id: String { rawValue }
    }

    init(service: SemanticFileSearchService, setup: Bool,
         pickFolders: @escaping () -> [String]? = { LauncherSearchSettingsView.pickFolders(allowApps: false) },
         onClose: @escaping () -> Void) {
        self.service = service; self.pickFolders = pickFolders; self.onClose = onClose
        _setup = State(initialValue: setup)
        _roots = State(initialValue: service.preferences.roots)
    }

    private var phaseText: String { SemanticFileSearchSettingsView.phaseText(service) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                AgentPaneHeader(
                    symbol: "sparkle.magnifyingglass",
                    title: L(self.setup ? "semantic.setup" : "semantic.manage")
                )
                Spacer()
                Button { self.onClose() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).accessibilityLabel(L(self.setup ? "semantic.cancel" : "semantic.close"))
            }
            Text(L("semantic.intro")).font(.system(size: 13)).foregroundStyle(StudioTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    AgentSettingsSection(title: L("semantic.folders"), footnote: L("semantic.folders.help")) {
                        if self.roots.isEmpty {
                            AgentSettingsEmptyRow(text: L("semantic.folders.empty"))
                        }
                        ForEach(self.roots, id: \.self) { root in
                            AgentSettingsRow(icon: "folder", title: AskFileLabels.folder(root), subtitle: root) {
                                AgentSettingsIconButton(systemImage: "minus", help: L("ask.remove")) {
                                    self.roots.removeAll { $0 == root }
                                    if !self.setup {
                                        self.service.setRoots(self.roots)
                                    }
                                }
                            }
                            ModelRowDivider(leading: 66)
                        }
                        AgentSettingsActionRow(icon: "plus", title: L("launcher.search.add"), action: self.addFolders)
                    }
                    if self.invalidRoot {
                        Text(L("semantic.scopeError")).font(.system(size: 12)).foregroundStyle(.orange)
                    }
                    AgentSettingsSection(title: L("semantic.model"), footnote: L("semantic.model.help")) {
                        AgentSettingsRow(
                            icon: "internaldrive",
                            title: "EmbeddingGemma 2",
                            subtitle: "Q8_0 · 310 MB · 768D"
                        ) {
                            Text(L(self.service.modelReady ? "semantic.installed" : "semantic.downloadRequired"))
                                .font(.system(size: 12)).foregroundStyle(StudioTheme.textSecondary)
                        }
                        if !self.setup {
                            ModelRowDivider(leading: 66)
                            VStack(alignment: .leading, spacing: 12) {
                                Text(self.phaseText).font(.system(size: 13, weight: .medium))
                                if case let .downloading(progress) = service.phase {
                                    ProgressView(value: progress)
                                    Button(L("semantic.cancelDownload")) { self.service.cancelDownload() }
                                }
                                HStack(spacing: 10) {
                                    Text(L(
                                        "semantic.statistics",
                                        self.service.files,
                                        self.service.chunks,
                                        self.service.skipped
                                    ))
                                    .font(.system(size: 12)).foregroundStyle(StudioTheme.textSecondary)
                                    Spacer()
                                    if self.service.phase == .modelRequired || self.service.phase == .failed {
                                        Button(L("semantic.retry")) {
                                            if self.service.modelReady {
                                                self.service.start(force: true)
                                            } else {
                                                self.service.downloadModel()
                                            }
                                        }
                                    } else if self.service.phase == .paused {
                                        Button(L("semantic.resume")) { self.service.pause(false) }
                                    } else if self.service.phase == .indexing || self.service.phase == .ready {
                                        Button(L("semantic.pause")) { self.service.pause(true) }
                                    }
                                }
                            }.padding(18)
                        }
                    }
                    if !self.service.blocked.isEmpty {
                        AgentSettingsSection(title: L("launcher.search.permission")) {
                            AgentSettingsRow(icon: "lock.shield", title: L("semantic.permission"),
                                             subtitle: self.service.blocked.map { AskFileLabels.folder($0) }
                                                 .joined(separator: ", ")) {
                                Button(L("launcher.search.fda.open")) {
                                    NSWorkspace.shared.open(AskFullDiskAccess.settingsURL)
                                }
                            }
                        }
                    }
                    if self.service.limited {
                        Text(L("semantic.limit")).font(.system(size: 12)).foregroundStyle(.orange)
                    }
                    if !self.setup {
                        AgentSettingsSection(title: L("semantic.storage"), footnote: L("semantic.storage.help")) {
                            HStack(spacing: 12) {
                                Button(L("semantic.rebuild")) { Task { await self.service.rebuild() } }
                                Button(L("semantic.clear"), role: .destructive) { self.deletion = .index }
                                Spacer()
                                Button(L("semantic.remove"), role: .destructive) { self.deletion = .model }
                            }.controlSize(.small).padding(18)
                        }
                    }
                    Text(L("semantic.priority")).font(.system(size: 12)).foregroundStyle(StudioTheme.textTertiary)
                }
            }
            HStack {
                Link(L("semantic.about"), destination: URL(string: "https://huggingface.co/google/embeddinggemma-2")!)
                    .font(.system(size: 12))
                Spacer()
                Button(L(self.setup ? "semantic.cancel" : "semantic.close")) { self.onClose() }
                    .keyboardShortcut(.cancelAction)
                if self.setup {
                    Button(L("semantic.enable")) {
                        self.service.setRoots(self.roots)
                        if self.service.setEnabled(true) {
                            self.invalidRoot = false
                            self.setup = false
                            Task {
                                // Preparation verifies an existing model before deciding to download.
                                await self.service.prepareModelIfNeeded()
                            }
                        }
                    }.buttonStyle(.borderedProminent)
                        .disabled(self.roots.isEmpty || !self.service.supported ||
                            !self.service.settings.askQuickFileSearchEnabled)
                }
            }
        }
        .padding(24).frame(width: 620, height: 670).background(StudioTheme.background)
        .alert(L(self.deletion == .model ? "semantic.remove" : "semantic.clear"), isPresented: Binding(
            get: { self.deletion != nil }, set: {
                if !$0 {
                    self.deletion = nil
                }
            }
        ), presenting: self.deletion) { choice in
            Button(L("semantic.cancel"), role: .cancel) {}
            Button(L("semantic.confirm"), role: .destructive) {
                Task { await self.service.clear(removeModel: choice == .model) }
            }
        } message: { _ in Text(L("semantic.deleteWarning")) }
    }

    private func addFolders() {
        guard let selected = self.pickFolders() else { return }
        let names = self.service.settings.askLauncherSearchSettings
        let allowed = SemanticFilePolicy.scope(.init(roots: selected), names: names, fullDiskAccess: true).roots
        self.invalidRoot = allowed.count != Set(selected).count
        self.roots = Array(Set(self.roots + allowed)).sorted()
        if !self.setup {
            self.service.setRoots(self.roots)
        }
    }
}
