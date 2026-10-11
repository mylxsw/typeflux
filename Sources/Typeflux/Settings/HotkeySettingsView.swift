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
        VStack(alignment: .leading, spacing: StudioTheme.Spacing.cardGroup) {
            StudioHeroHeader(eyebrow: StudioSection.hotkeys.eyebrow, title: StudioSection.hotkeys.heading)
            ForEach(HotkeyGroup.allCases) { group in
                let rows = model.rows.filter { $0.group == group }
                if !rows.isEmpty || group == .keywords {
                    VStack(alignment: .leading, spacing: 8) {
                        sectionHeader(group, count: rows.count)
                        ModelSurface {
                            VStack(alignment: .leading, spacing: 0) {
                                if rows.isEmpty {
                                    keywordEmptyState
                                }
                                if !rows.isEmpty {
                                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                                        if index > 0 { ModelRowDivider(leading: group == .keywords ? 14 : 40) }
                                        rowView(row)
                                    }
                                }
                            }
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

    // MARK: - Header and tables

    private func sectionHeader(_ group: HotkeyGroup, count: Int) -> some View {
        HStack(spacing: 8) {
            SettingsListSectionLabel(title: group.title, count: count)
            Spacer(minLength: 8)
            if group == .keywords {
                Button { add(nil) } label: {
                    Label(L("hotkeys.keyword.add"), systemImage: "plus")
                }
                .buttonStyle(ModelActionStyle())
                .fixedSize()
                .accessibilityIdentifier("hotkeys.keyword.add")
            }
        }
    }

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
                    Toggle("", isOn: Binding(
                        get: { model.keywordHotkey(id)?.enabled ?? false },
                        set: { model.setEnabled($0, forKeywordHotkey: id) }
                    ))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    .accessibilityLabel(L("ask.settings.keywords.enabled") + " " + row.title)
                    .help(L("ask.settings.keywords.enabled"))
                    .accessibilityIdentifier("hotkeys.enabled." + id.uuidString)
                } else {
                    Color.clear.frame(height: 1)
                }
            }
            .frame(width: enabledColumnWidth)
            menu(for: row).frame(width: 24)
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
        Menu {
            Button(L("hotkeys.menu.record")) { startRecording(row) }
            if case let .keyword(id) = row.target {
                Button(L("hotkeys.menu.edit")) {
                    edit(id)
                }
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
        VStack(alignment: .leading, spacing: 12) {
            Text(L("hotkeys.keyword.empty")).font(.system(size: 13)).foregroundStyle(StudioTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 8)], spacing: 8) {
                ForEach(HotkeySettingsPresentation.templates(in: model.options)) { option in
                    Button { add(option) } label: {
                        HStack(spacing: 8) {
                            KeywordHotkeyBadge(keyword: option.keyword.keyword)
                            Text(option.name).font(.system(size: 13, weight: .medium))
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            Image(systemName: "plus").font(.system(size: 12, weight: .medium))
                                .foregroundStyle(StudioTheme.textSecondary)
                        }
                        .foregroundStyle(StudioTheme.textPrimary)
                        .padding(.horizontal, 10).frame(height: 32)
                        .background(ModelVisualStyle.control,
                                    in: RoundedRectangle(cornerRadius: ModelVisualStyle.controlCornerRadius))
                        .overlay(RoundedRectangle(cornerRadius: ModelVisualStyle.controlCornerRadius)
                            .strokeBorder(ModelVisualStyle.border))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(L("hotkeys.recordAccessibility", option.name))
                    .accessibilityLabel(L("hotkeys.recordAccessibility", option.name))
                    .accessibilityIdentifier("hotkeys.keyword.template." + option.keyword.keyword)
                }
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
    @Environment(\.colorScheme) private var colorScheme

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

    private var capFill: Color { colorScheme == .dark ? ModelVisualStyle.control : StudioTheme.cardFill }

    private func cap(_ text: String, highlighted: Bool = false) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(highlighted ? ModelVisualStyle.accent : StudioTheme.textPrimary)
            .padding(.horizontal, 8).frame(minWidth: 26, minHeight: 24)
            .background(highlighted ? ModelVisualStyle.accent.opacity(0.12) : capFill,
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(highlighted ? ModelVisualStyle.accent.opacity(0.5) : ModelVisualStyle.border))
            // Light keycaps are white and stand on a 1pt bottom edge.
            .shadow(color: colorScheme == .dark || highlighted ? .clear : Color.black.opacity(0.10), radius: 0, x: 0, y: 1)
    }
}
