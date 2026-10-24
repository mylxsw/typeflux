import AppKit
import SwiftUI

/// Settings → Ring: the shortcut, the slices and the look of the ring. The slices are edited on
/// the ring itself (`RingStudioCanvas`) with an inspector beside it; every change is saved at once.
struct RingSettingsView: View {
    static let studioHeight: CGFloat = 520

    @StateObject private var model: RingSettingsModel
    @StateObject private var shortcuts: HotkeySettingsModel
    @StateObject private var recorder = HotkeyRecorder()
    @State private var isRecording = false
    @State private var hotkeyNotice: String?
    @StateObject private var studio: RingStudioController
    @State private var centerTitle = ""
    @State private var apps: [RingLibraryApp] = []
    @State private var appsState = LoadState.idle
    @State private var shortcutNames: [String] = []
    @State private var shortcutsState = LoadState.idle

    private enum LoadState { case idle, loading, loaded }

    init(settingsStore: SettingsStore) {
        let model = RingSettingsModel(settingsStore: settingsStore)
        _model = StateObject(wrappedValue: model)
        _studio = StateObject(wrappedValue: RingStudioController(model: model))
        _shortcuts = StateObject(wrappedValue: HotkeySettingsModel(settingsStore: settingsStore, workflows: .shared))
    }

    private var configuration: RingConfiguration {
        model.configuration
    }

    private var actions: [RingAction] {
        configuration.actions
    }

    var body: some View {
        VStack(alignment: .leading, spacing: TFMetrics.sectionSpacing) {
            triggerSection
            actionsSection
            appearanceSection
        }
        .onAppear { centerTitle = configuration.centerTitle }
        .onDisappear {
            recorder.stop()
            isRecording = false
        }
    }

    // MARK: - Shortcut

    private var triggerSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            TFFormSection {
                TFFormRow(title: L("ring.hotkey.title"), detail: L("ring.hotkey.detail"), icon: "keyboard") {
                    Button(action: toggleRecording) {
                        HotkeyKeysView(binding: shortcuts.row(for: .action(.ring))?.binding, isRecording: isRecording)
                            .frame(width: 170, alignment: .trailing)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L("hotkeys.recordAccessibility", L("ring.title")))
                    .accessibilityIdentifier("ring.hotkey")
                    TFButton(title: L("settings.shortcuts.unset"), systemImage: "xmark", kind: .plain, size: .small,
                             iconOnly: true) {
                        stopRecording()
                        shortcuts.unsetHotkey(for: .ring)
                    }
                    .disabled(shortcuts.row(for: .action(.ring))?.binding == nil)
                }
            }
            if let hotkeyNotice {
                TFFieldMessage(text: hotkeyNotice, tone: .warning).padding(.horizontal, 4)
            }
        }
    }

    private func toggleRecording() {
        if isRecording {
            return stopRecording()
        }
        isRecording = true
        hotkeyNotice = nil
        recorder.start(supportsAuxiliaryBindings: true) { binding in
            isRecording = false
            hotkeyNotice = shortcuts.setHotkey(binding, for: .ring)
            let usedByMacOS = HotkeyConflictChecker.isCommonSystemShortcut(binding)
                || SystemSymbolicHotkeys.current.contains(binding)
            if hotkeyNotice == nil, usedByMacOS {
                hotkeyNotice = L("hotkeys.conflict.system")
            }
        }
    }

    private func stopRecording() {
        guard isRecording else { return }
        recorder.stop()
        isRecording = false
    }

    // MARK: - Actions

    private var actionsSection: some View {
        TFFormSection(title: L("ring.actions.title"), count: actions.count) {
            TFButton(title: L("ring.actions.reset"), systemImage: "arrow.counterclockwise", kind: .plain,
                     size: .small) { studio.resetActions() }
                .disabled(actions == RingConfiguration.defaultActions())
                .accessibilityIdentifier("ring.actions.reset")
        } content: {
            HStack(spacing: 0) {
                canvas.frame(width: RingStudioCanvas.size + 20)
                    // Over the canvas hint, so it never covers the inspector's buttons.
                    .overlay(alignment: .bottom) { undoBar }
                    .animation(.easeOut(duration: 0.18), value: model.lastChange)
                Rectangle().fill(TFColors.border).frame(width: TFMetrics.borderWidth)
                inspectorPanel.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(height: Self.studioHeight)
        }
    }

    @ViewBuilder private var undoBar: some View {
        if let message = model.lastChange {
            TFUndoBar(message: message, onUndo: { studio.undo() }, onDismiss: { model.dismissLastChange() })
                .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
                .padding(.horizontal, 12).padding(.bottom, 10)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .accessibilityIdentifier("ring.undo")
        }
    }

    private var canvas: some View {
        RingStudioCanvas(
            slots: studio.slots,
            selectedIndex: studio.selectedIndex,
            mode: studio.canvasMode,
            style: configuration.style,
            centerTitle: configuration.centerTitle,
            actionCount: actions.count,
            insertionIndexes: studio.insertionIndexes,
            issues: Set(issues.keys),
            drag: $studio.drag,
            isTrying: $studio.isTrying,
            onInsert: { studio.show(.library(.insert(index: $0))) },
            onSelect: { studio.show(.edit($0)) },
            onMove: { studio.move($0, to: $1) },
            onBackground: { studio.clickBackground() },
            onKey: { studio.handle($0) }
        )
    }

    @ViewBuilder private var inspectorPanel: some View {
        switch studio.state {
        case .overview:
            RingInspectorOverview(actions: actions, issues: issues, detail: targetSummary(of:),
                                  onSelect: { studio.show(.edit($0)) },
                                  onMove: { model.move($0, to: $1) },
                                  onAdd: { studio.show(.library(.insert(index: actions.count))) })
        case let .library(target):
            RingLibraryPanel(target: target, actions: actions, library: library,
                             isLoadingApps: appsState == .loading, preview: $studio.preview,
                             onPick: { studio.pick($0, keywordName: keywordName) },
                             onClose: { studio.cancelLibrary() },
                             onOpenType: { type in
                                 if type == .app {
                                     loadApps()
                                 }
                                 if type == .shortcut {
                                     loadShortcuts()
                                 }
                             })
                             .id(target)
                             .task {
                                 loadShortcuts()
                                 loadApps()
                             }
        case let .edit(id):
            if let index = actions.firstIndex(where: { $0.id == id }) {
                let action = actions[index]
                RingActionInspector(
                    action: action, index: index, count: actions.count, issue: issues[id],
                    defaultTitle: RingActionLibrary.defaultTitle(for: action.kind, keywordName: keywordName),
                    targetSummary: targetSummary(of: action),
                    onRename: { title in model.edit(id) { $0.title = title } },
                    onSymbol: { symbol in model.edit(id) { $0.symbol = symbol } },
                    onRetarget: { studio.retarget(id, to: $0, keywordName: keywordName) },
                    onReplace: { studio.show(.library(.replace(id))) },
                    onMove: { model.move(id, by: $0) },
                    onDuplicate: { studio.duplicate(id) },
                    onDelete: { studio.delete(id) },
                    onDone: { studio.show(.overview) }
                )
            }
        }
    }

    // MARK: - Library data

    private var library: RingActionLibrary {
        RingActionLibrary(keywords: shortcuts.options, apps: apps, shortcuts: shortcutNames)
    }

    private func loadApps() {
        guard appsState == .idle else { return }
        appsState = .loading
        Task {
            let found = await PersonaAppDiscovery.discoverPersonaAppCandidates(scope: .all)
            var seen = Set<String>()
            apps = found.compactMap { app in
                guard let bundle = app.bundleIdentifier, seen.insert(bundle).inserted else { return nil }
                return RingLibraryApp(name: app.displayName, bundleIdentifier: bundle)
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            appsState = .loaded
        }
    }

    private func loadShortcuts() {
        guard shortcutsState == .idle else { return }
        shortcutsState = .loading
        Task {
            shortcutNames = await RingShortcutsDiscovery.load()
            shortcutsState = .loaded
        }
    }

    // MARK: - Text

    private func keywordName(_ keyword: String, _ pluginID: String) -> String? {
        shortcuts.options.first { $0.keyword.pluginID == pluginID && $0.keyword.contains(keyword) }?.name
    }

    private func targetSummary(of action: RingAction) -> String {
        RingSettingsPresentation.summary(of: action, keywordName: keywordName)
    }

    /// Slices that cannot run any more, with the reason.
    private var issues: [UUID: String] {
        var result: [UUID: String] = [:]
        for action in actions {
            result[action.id] = RingSettingsPresentation.issue(
                of: action,
                keywordExists: { keyword, pluginID in keywordName(keyword, pluginID) != nil },
                appExists: { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil },
                folderExists: { path in
                    var isDirectory: ObjCBool = false
                    return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
                        && isDirectory.boolValue
                }
            )
        }
        return result
    }

    // MARK: - Appearance

    private var appearanceSection: some View {
        TFFormSection(title: L("ring.appearance.title")) {
            TFFormRow(title: L("ring.style.title"), detail: L("ring.style.detail"), icon: "paintpalette",
                      controlWidth: .wide) {
                TFSegmentedControl(options: RingStyle.allCases.map { TFOption($0, $0.title) },
                                   selection: Binding(get: { configuration.style }, set: model.setStyle),
                                   fillsWidth: true, identifier: { "ring.style." + $0.rawValue })
            }
            TFDivider.formWithIcon
            TFFormRow(title: L("ring.centerTitle.title"), detail: L("ring.centerTitle.detail"), icon: "textformat",
                      controlWidth: .standard) {
                TextField(RingConfiguration.defaultCenterTitle, text: $centerTitle)
                    .textFieldStyle(TFTextFieldStyle())
                    .onChange(of: centerTitle) { value in
                        let limited = String(value.prefix(RingConfiguration.centerTitleLimit))
                        if limited != value {
                            centerTitle = limited
                        }
                        model.setCenterTitle(limited)
                    }
                    .accessibilityIdentifier("ring.centerTitle")
            }
        }
    }
}
