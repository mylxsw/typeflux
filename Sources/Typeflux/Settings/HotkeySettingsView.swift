import SwiftUI

/// Settings → Shortcuts: native grouped rows for global and keyword shortcuts.
struct HotkeySettingsView: View {
    @ObservedObject var viewModel: StudioViewModel
    @StateObject private var model: HotkeySettingsModel
    @StateObject private var recorder = HotkeyRecorder()
    @State private var recordingTarget: HotkeyTarget?
    @State private var editing: KeywordHotkeyDraftItem?
    @State private var confirmationTitle = ""
    @State private var confirmationAction: (() -> Void)?
    var compact = false

    init(viewModel: StudioViewModel, settingsStore: SettingsStore, compact: Bool = false) {
        self.compact = compact
        self.viewModel = viewModel
        _model = StateObject(wrappedValue: HotkeySettingsModel(settingsStore: settingsStore, workflows: .shared))
    }

    var body: some View {
        TypefluxForm {
            ForEach(HotkeyGroup.allCases) { group in
                let rows = model.rows.filter { $0.group == group }
                if !rows.isEmpty || group == .keywords {
                    TypefluxFormSection(group.title) {
                        if group == .keywords {
                            TypefluxButton(L("hotkeys.keyword.add")) { add(nil) }
                                .accessibilityIdentifier("hotkeys.keyword.add")
                            if rows.isEmpty { keywordEmptyState }
                        }
                        ForEach(rows) { row in rowView(row) }
                    }
                }
            }
        }
        .onAppear(perform: model.reload)
        .onDisappear(perform: stopRecording)
        .sheet(item: $editing) { item in
            KeywordHotkeyEditorSheet(model: model, draft: item.draft) { editing = nil }
        }
        .alert(confirmationTitle, isPresented: Binding(
            get: { confirmationAction != nil }, set: { if !$0 { confirmationAction = nil } }
        )) {
            Button(L("common.cancel"), role: .cancel) { confirmationAction = nil }
            Button(confirmationTitle, role: .destructive) {
                let action = confirmationAction
                confirmationAction = nil
                stopRecording()
                action?()
            }
        }
    }

    private func rowView(_ row: HotkeyRow) -> some View {
        TypefluxSettingsRow(row.title, description: row.keywordName) {
            HStack {
                if let status = row.status, status != .disabled, status != .unset,
                   let message = HotkeySettingsPresentation.statusMessage(status) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(TypefluxColor.warning.color).help(message).accessibilityLabel(message)
                }
                if case let .keyword(id) = row.target {
                    TypefluxIconButton(L("hotkeys.menu.edit"), systemImage: "pencil") { edit(id) }
                        .accessibilityIdentifier("hotkeys.keyword.edit." + id.uuidString)
                }
                TypefluxButton(kind: .borderless) { toggleRecording(row) } label: {
                    HotkeyKeysView(binding: row.binding, isRecording: recordingTarget == row.target)
                }
                .help(recordingHelp(for: row))
                .accessibilityLabel(L("hotkeys.recordAccessibility", row.title))
                .accessibilityValue(recordingTarget == row.target
                    ? L("hotkeys.recording") : row.binding.map(HotkeyFormat.display) ?? L("settings.shortcuts.none"))
                .accessibilityIdentifier("hotkeys.binding." + identifier(row.target))
                if case let .keyword(id) = row.target {
                    TypefluxSwitch(L("ask.settings.keywords.enabled") + " " + row.title, isOn: Binding(
                        get: { model.keywordHotkey(id)?.enabled ?? false },
                        set: { model.setEnabled($0, forKeywordHotkey: id) }
                    ), labelsHidden: true)
                    .accessibilityIdentifier("hotkeys.enabled." + id.uuidString)
                }
                menu(for: row)
            }
        }
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
        TypefluxMenu(borderless: true) {
            Button(L("hotkeys.menu.record")) { startRecording(row) }
            if case let .keyword(id) = row.target {
                Button(L("hotkeys.menu.edit")) { edit(id) }
                Button(L("hotkeys.menu.duplicate")) {
                    stopRecording()
                    if let copy = model.duplicate(id) {
                        model.save(copy)
                        editing = KeywordHotkeyDraftItem(draft: KeywordHotkeyDraft(editing: copy))
                    }
                }
                Divider()
            }
            if let defaultBinding = row.defaultBinding {
                Button(L("hotkeys.menu.reset"), role: .destructive) {
                    confirm(L("hotkeys.menu.reset")) { apply(defaultBinding, to: row.target) }
                }.disabled(row.isDefault)
            }
            Button(L("settings.shortcuts.unset"), role: .destructive) {
                confirm(L("settings.shortcuts.unset")) { unset(row.target) }
            }.disabled(row.binding == nil)
            if case let .keyword(id) = row.target {
                Button(L("hotkeys.keyword.delete"), role: .destructive) {
                    confirm(L("hotkeys.keyword.delete")) { model.delete(id) }
                }
            }
        } label: {
            Label(L("hotkeys.menu.more"), systemImage: "ellipsis").labelStyle(.iconOnly)
        }
        .fixedSize().accessibilityLabel(L("hotkeys.menu.more"))
    }

    private func confirm(_ title: String, action: @escaping () -> Void) {
        confirmationTitle = title
        confirmationAction = action
    }

    private var keywordEmptyState: some View {
        VStack(alignment: .leading) {
            Text(L("hotkeys.keyword.empty")).font(.subheadline).foregroundStyle(TypefluxColor.secondaryLabel.color)
            ForEach(HotkeySettingsPresentation.templates(in: model.options)) { option in
                TypefluxButton(kind: .borderless) { add(option) } label: {
                    Label(option.keyword.keyword + " · " + option.name, systemImage: "plus")
                }
                .help(L("hotkeys.recordAccessibility", option.name))
                .accessibilityLabel(L("hotkeys.recordAccessibility", option.name))
                .accessibilityIdentifier("hotkeys.keyword.template." + option.keyword.keyword)
            }
        }
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
