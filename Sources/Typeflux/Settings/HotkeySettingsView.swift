import SwiftUI

/// Settings → Shortcuts: compact, aligned tables for global and keyword shortcuts.
struct HotkeySettingsView: View {
    @ObservedObject var viewModel: StudioViewModel
    @StateObject private var model: HotkeySettingsModel
    @StateObject private var recorder = HotkeyRecorder()
    @State private var recordingTarget: HotkeyTarget?
    @State private var editing: KeywordHotkeyDraftItem?
    var compact = false

    init(viewModel: StudioViewModel, settingsStore: SettingsStore, compact: Bool = false) {
        self.compact = compact
        self.viewModel = viewModel
        _model = StateObject(wrappedValue: HotkeySettingsModel(settingsStore: settingsStore, workflows: .shared))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: TFMetrics.sectionSpacing) {
            ForEach(HotkeyGroup.allCases) { group in
                let rows = model.rows.filter { $0.group == group }
                if !rows.isEmpty || group == .keywords {
                    TFFormSection(title: group.title, count: rows.count) {
                        if group == .keywords {
                            TFButton(title: L("hotkeys.keyword.add"), systemImage: "plus") { add(nil) }
                                .accessibilityIdentifier("hotkeys.keyword.add")
                        }
                    } content: {
                        if rows.isEmpty {
                            keywordEmptyState
                        }
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                            if index > 0 { TFDivider(inset: group == .keywords ? TFListGroupInset.form : 40) }
                            rowView(row)
                        }
                    }
                }
            }
        }
        .onAppear(perform: model.reload)
        .onDisappear(perform: stopRecording)
        .sheet(item: $editing) { item in
            KeywordHotkeyEditorSheet(model: model, draft: item.draft) { editing = nil }
        }
    }

    // MARK: - Tables

    private var keyColumnWidth: CGFloat {
        compact ? 180 : 210
    }

    private let enabledColumnWidth: CGFloat = 44

    // MARK: - Rows

    private func rowView(_ row: HotkeyRow) -> some View {
        HStack(spacing: 10) {
            HotkeySettingsName(row: row, edit: edit)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button { toggleRecording(row) } label: {
                HotkeyKeysView(binding: row.binding, isRecording: recordingTarget == row.target)
                    .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(width: keyColumnWidth)
            .help(recordingHelp(for: row))
            .accessibilityLabel(L("hotkeys.recordAccessibility", row.title))
            .accessibilityValue(recordingTarget == row.target
                ? L("hotkeys.recording") : row.binding.map(HotkeyFormat.display) ?? L("settings.shortcuts.none"))
            .accessibilityIdentifier("hotkeys.binding." + identifier(row.target))
            Group {
                if case let .keyword(id) = row.target {
                    TFSwitch(title: L("ask.settings.keywords.enabled") + " " + row.title, isOn: Binding(
                        get: { model.keywordHotkey(id)?.enabled ?? false },
                        set: { model.setEnabled($0, forKeywordHotkey: id) }
                    ))
                    .accessibilityLabel(L("ask.settings.keywords.enabled") + " " + row.title)
                    .help(L("ask.settings.keywords.enabled"))
                    .accessibilityIdentifier("hotkeys.enabled." + id.uuidString)
                } else {
                    Color.clear.frame(height: 1)
                }
            }
            .frame(width: enabledColumnWidth)
            menu(for: row)
        }
        .padding(.horizontal, 14).frame(minHeight: 44)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("hotkeys.row." + identifier(row.target))
    }

    private func recordingHelp(for row: HotkeyRow) -> String {
        guard recordingTarget == row.target else { return L("hotkeys.recordHelp") }
        return L(row.group == .keywords ? "hotkeys.recording.hint" : "settings.shortcuts.recordingGeneric")
    }

    private func identifier(_ target: HotkeyTarget) -> String {
        switch target {
        case let .builtIn(value): "builtIn." + value.rawValue
        case let .action(value): "action." + value.rawValue
        case let .keyword(id): "keyword." + id.uuidString
        }
    }

    private func menu(for row: HotkeyRow) -> some View {
        TFMenuButton(title: L("hotkeys.menu.more"), systemImage: "ellipsis", kind: .plain, size: .small,
                     iconOnly: true, actions: menuActions(for: row))
    }

    private func menuActions(for row: HotkeyRow) -> [TFMenuAction] {
        var actions: [TFMenuAction] = [.action(L("hotkeys.menu.record")) { startRecording(row) }]
        if case let .keyword(id) = row.target {
            actions += [
                .action(L("hotkeys.menu.edit")) { edit(id) },
                .action(L("hotkeys.menu.duplicate")) {
                    stopRecording()
                    if let copy = model.duplicate(id) {
                        model.save(copy)
                        editing = KeywordHotkeyDraftItem(draft: KeywordHotkeyDraft(editing: copy))
                    }
                },
                .separator
            ]
        }
        if let defaultBinding = row.defaultBinding {
            actions.append(.action(L("hotkeys.menu.reset"), isEnabled: !row.isDefault) {
                apply(defaultBinding, to: row.target)
            })
        }
        actions.append(.action(L("settings.shortcuts.unset"), isEnabled: row.binding != nil) { unset(row.target) })
        if case let .keyword(id) = row.target {
            actions.append(.action(L("hotkeys.keyword.delete"), destructive: true) { model.delete(id) })
        }
        return actions
    }

    private var keywordEmptyState: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 8)], spacing: 8) {
            ForEach(HotkeySettingsPresentation.templates(in: model.options)) { option in
                Button { add(option) } label: {
                    HStack(spacing: 8) {
                        KeywordHotkeyBadge(keyword: option.keyword.keyword)
                        Text(option.name).lineLimit(1).layoutPriority(1)
                        Spacer(minLength: 0)
                        Image(systemName: "plus").foregroundStyle(TFColors.textSecondary)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(TFButtonStyle(kind: .secondary))
                .help(L("hotkeys.recordAccessibility", option.name))
                .accessibilityLabel(L("hotkeys.recordAccessibility", option.name))
                .accessibilityIdentifier("hotkeys.keyword.template." + option.keyword.keyword)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 14)
    }

    // MARK: - Actions

    private func edit(_ id: UUID) {
        guard let hotkey = model.keywordHotkey(id) else { return }
        stopRecording()
        editing = KeywordHotkeyDraftItem(draft: KeywordHotkeyDraft(editing: hotkey))
    }

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
                TFKeyCap(text: L("hotkeys.recording"), style: .key, highlighted: true)
            } else if let binding {
                ForEach(Array(HotkeyFormat.components(binding).enumerated()), id: \.offset) { _, key in
                    TFKeyCap(text: key, style: .key)
                }
                if let count = HotkeyFormat.pressCount(binding) {
                    Text("×\(count)").font(.system(size: 11.5, weight: .bold))
                        .foregroundStyle(TFColors.textSecondary)
                }
            } else {
                TFKeyCap(text: L("settings.shortcuts.none"), style: .key).opacity(0.55)
            }
        }
    }
}
