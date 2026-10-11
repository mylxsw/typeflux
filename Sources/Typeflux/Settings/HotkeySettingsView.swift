import SwiftUI

/// Settings → Shortcuts: every global shortcut in one place — voice input, the launcher,
/// content tools and keyword shortcuts. The older shortcut cards on the Settings page stay.
struct HotkeySettingsView: View {
    @ObservedObject var viewModel: StudioViewModel
    @StateObject private var model: HotkeySettingsModel
    @StateObject private var recorder = HotkeyRecorder()
    @State private var recordingTarget: HotkeyTarget?
    @State private var query = ""
    @State private var editing: KeywordHotkeyDraftItem?

    init(viewModel: StudioViewModel, settingsStore: SettingsStore) {
        self.viewModel = viewModel
        _model = StateObject(wrappedValue: HotkeySettingsModel(settingsStore: settingsStore, workflows: .shared))
    }

    var body: some View {
        let shown = HotkeySettingsPresentation.filter(model.rows, query: query)
        VStack(alignment: .leading, spacing: 16) {
            toolbar
            if shown.isEmpty, !query.isEmpty {
                ModelSurface { AgentSettingsEmptyRow(text: L("hotkeys.noMatch", query)) }
            }
            ForEach(HotkeyGroup.allCases) { group in
                let rows = shown.filter { $0.group == group }
                if !rows.isEmpty || (group == .keywords && query.isEmpty) {
                    VStack(alignment: .leading, spacing: 8) {
                        ModelSectionLabel(title: group.title, detail: rows.isEmpty ? nil : "\(rows.count)")
                        ModelSurface {
                            VStack(alignment: .leading, spacing: 0) {
                                if rows.isEmpty {
                                    keywordEmptyState
                                }
                                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                                    if index > 0 {
                                        ModelRowDivider(leading: 56)
                                    }
                                    rowView(row)
                                }
                            }
                        }
                    }
                }
            }
            Text(L("hotkeys.footnote")).font(.system(size: 12)).foregroundStyle(StudioTheme.textTertiary)
                .padding(.horizontal, 4)
        }
        .onAppear(perform: model.reload)
        .onDisappear(perform: stopRecording)
        .sheet(item: $editing) { item in
            KeywordHotkeyEditorSheet(model: model, draft: item.draft) { editing = nil }
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 8) {
            SettingsSearchBox(placeholder: L("hotkeys.search"), text: $query, width: nil)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("hotkeys.search")
            Button { add(nil) } label: {
                Label(L("hotkeys.keyword.add"), systemImage: "plus")
            }
            .buttonStyle(ModelActionStyle(primary: true))
            .fixedSize()
            .accessibilityIdentifier("hotkeys.keyword.add")
        }
    }

    // MARK: - Rows

    private func rowView(_ row: HotkeyRow) -> some View {
        AgentSettingsRow(icon: row.icon, title: row.title, subtitle: subtitle(of: row)) {
            HStack(spacing: 10) {
                if let status = row.status, let message = HotkeySettingsPresentation.statusMessage(status),
                   status != .unset {
                    Text(message).font(.system(size: 11.5)).foregroundStyle(StudioTheme.warning).lineLimit(1)
                }
                Button { toggleRecording(row) } label: {
                    HotkeyKeysView(binding: row.binding, isRecording: recordingTarget == row.target)
                }
                .buttonStyle(.plain)
                .help(L("hotkeys.recordHelp"))
                .accessibilityLabel(L("hotkeys.recordAccessibility", row.title))
                if case let .keyword(id) = row.target {
                    Toggle("", isOn: Binding(
                        get: { model.keywordHotkey(id)?.enabled ?? false },
                        set: { model.setEnabled($0, forKeywordHotkey: id) }
                    ))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    .accessibilityLabel(L("ask.settings.keywords.enabled"))
                }
                menu(for: row)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if case let .keyword(id) = row.target, let hotkey = model.keywordHotkey(id) {
                editing = KeywordHotkeyDraftItem(draft: KeywordHotkeyDraft(editing: hotkey))
            }
        }
    }

    private func subtitle(of row: HotkeyRow) -> String {
        guard recordingTarget == row.target else { return row.subtitle }
        if case .builtIn = row.target {
            return L("settings.shortcuts.recordingGeneric")
        }
        return L("hotkeys.recording.hint")
    }

    private func menu(for row: HotkeyRow) -> some View {
        Menu {
            Button(L("hotkeys.menu.record")) { startRecording(row) }
            if case let .keyword(id) = row.target {
                Button(L("hotkeys.menu.edit")) {
                    if let hotkey = model.keywordHotkey(id) {
                        editing = KeywordHotkeyDraftItem(draft: KeywordHotkeyDraft(editing: hotkey))
                    }
                }
                Button(L("hotkeys.menu.duplicate")) {
                    if let copy = model.duplicate(id) {
                        model.save(copy)
                        editing = KeywordHotkeyDraftItem(draft: KeywordHotkeyDraft(editing: copy))
                    }
                }
                Divider()
            }
            if let defaultBinding = row.defaultBinding {
                Button(L("hotkeys.menu.reset")) { apply(defaultBinding, to: row.target) }
                    .disabled(row.isDefault)
            }
            Button(L("settings.shortcuts.unset")) { unset(row.target) }
                .disabled(row.binding == nil)
            if case let .keyword(id) = row.target {
                Button(L("hotkeys.keyword.delete"), role: .destructive) { model.delete(id) }
            }
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 13, weight: .semibold))
                .foregroundStyle(StudioTheme.textSecondary).frame(width: 24, height: 24)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .accessibilityLabel(L("hotkeys.menu.more"))
    }

    private var keywordEmptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("hotkeys.keyword.empty")).font(.system(size: 13)).foregroundStyle(StudioTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                ForEach(HotkeySettingsPresentation.templates(in: model.options)) { option in
                    Button { add(option) } label: {
                        Label("\(option.keyword.keyword) · \(option.name)", systemImage: "plus")
                    }
                    .buttonStyle(ModelActionStyle())
                }
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 16)
    }

    // MARK: - Actions

    private func add(_ option: KeywordHotkeyOption?) {
        stopRecording()
        editing = KeywordHotkeyDraftItem(draft: KeywordHotkeyDraft(adding: option))
    }

    private func toggleRecording(_ row: HotkeyRow) {
        if recordingTarget == row.target {
            stopRecording()
        } else {
            startRecording(row)
        }
    }

    private func startRecording(_ row: HotkeyRow) {
        recordingTarget = row.target
        let supportsAuxiliary = row.target == .builtIn(.auxiliary)
        recorder.start(supportsAuxiliaryBindings: supportsAuxiliary) { binding in
            recordingTarget = nil
            apply(binding, to: row.target)
        }
    }

    private func stopRecording() {
        recorder.stop()
        recordingTarget = nil
    }

    private func apply(_ binding: HotkeyBinding, to target: HotkeyTarget) {
        switch target {
        case let .builtIn(builtIn):
            switch builtIn {
            case .activation: viewModel.setActivationHotkey(binding)
            case .auxiliary: viewModel.setAuxiliaryHotkey(binding)
            case .persona: viewModel.setPersonaHotkey(binding)
            case .ask: viewModel.setAskHotkey(binding)
            case .history: viewModel.setHistoryHotkey(binding)
            case .screenshot: viewModel.setScreenshotHotkey(binding)
            }
        case let .action(action):
            report(model.setHotkey(binding, for: action), binding: binding)
        case let .keyword(id):
            report(model.setBinding(binding, forKeywordHotkey: id), binding: binding)
        }
    }

    private func report(_ problem: String?, binding: HotkeyBinding) {
        if let problem {
            viewModel.showToast(problem)
        } else if HotkeyConflictChecker.isCommonSystemShortcut(binding) {
            viewModel.showToast(L("hotkeys.conflict.system"))
        } else {
            viewModel.showToast(L("hotkeys.updated", HotkeyFormat.display(binding)))
        }
    }

    private func unset(_ target: HotkeyTarget) {
        switch target {
        case let .builtIn(builtIn):
            switch builtIn {
            case .activation: viewModel.unsetActivationHotkey()
            case .auxiliary: viewModel.unsetAuxiliaryHotkey()
            case .persona: viewModel.unsetPersonaHotkey()
            case .ask: viewModel.unsetAskHotkey()
            case .history: viewModel.unsetHistoryHotkey()
            case .screenshot: viewModel.unsetScreenshotHotkey()
            }
        case let .action(action):
            model.unsetHotkey(for: action)
        case let .keyword(id):
            model.unsetBinding(forKeywordHotkey: id)
        }
    }
}

/// A keyword shortcut sheet to present: a fresh id each time, so reopening shows saved values.
struct KeywordHotkeyDraftItem: Identifiable {
    let id = UUID()
    var draft: KeywordHotkeyDraft
}

/// The keys of a shortcut as keycaps, "Not set", or a recording prompt.
struct HotkeyKeysView: View {
    let binding: HotkeyBinding?
    var isRecording = false

    var body: some View {
        HStack(spacing: 4) {
            if isRecording {
                cap(L("hotkeys.recording"), highlighted: true)
            } else if let binding {
                ForEach(Array(HotkeyFormat.components(binding).enumerated()), id: \.offset) { _, key in
                    cap(key)
                }
                if let count = HotkeyFormat.pressCount(binding) {
                    Text("×\(count)").font(.system(size: 11.5, weight: .bold))
                        .foregroundStyle(StudioTheme.textSecondary)
                }
            } else {
                cap(L("settings.shortcuts.none")).opacity(0.55)
            }
        }
    }

    private func cap(_ text: String, highlighted: Bool = false) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(highlighted ? ModelVisualStyle.accent : StudioTheme.textPrimary)
            .padding(.horizontal, 8).frame(minWidth: 26, minHeight: 24)
            .background(highlighted ? ModelVisualStyle.accent.opacity(0.12) : ModelVisualStyle.control,
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(highlighted ? ModelVisualStyle.accent.opacity(0.5) : ModelVisualStyle.border))
    }
}
