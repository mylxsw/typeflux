import SwiftUI

/// Settings → Ring: the shortcut, the slices and the look of the ring.
struct RingSettingsView: View {
    @StateObject private var model: RingSettingsModel
    @StateObject private var shortcuts: HotkeySettingsModel
    @StateObject private var recorder = HotkeyRecorder()
    @ObservedObject private var practice: RingPractice
    @State private var isRecording = false
    @State private var hotkeyNotice: String?
    @State private var editing: RingActionDraft?
    @State private var pendingDeletion: RingAction?
    @State private var confirmingReset = false
    @State private var highlighted: UUID?
    @State private var centerTitle = ""

    init(settingsStore: SettingsStore, practice: RingPractice = .shared) {
        _model = StateObject(wrappedValue: RingSettingsModel(settingsStore: settingsStore))
        _shortcuts = StateObject(wrappedValue: HotkeySettingsModel(settingsStore: settingsStore, workflows: .shared))
        self.practice = practice
    }

    private var configuration: RingConfiguration {
        model.configuration
    }

    var body: some View {
        VStack(alignment: .leading, spacing: TFMetrics.sectionSpacing) {
            triggerSection
            actionsSection
            appearanceSection
        }
        .disabled(!configuration.enabled)
        .opacity(configuration.enabled ? 1 : TFMetrics.disabledOpacity)
        .onAppear { centerTitle = configuration.centerTitle }
        .onDisappear {
            recorder.stop()
            isRecording = false
            practice.stop()
        }
        .sheet(item: $editing) { draft in
            RingActionEditorSheet(draft: draft, keywords: shortcuts.options, onSave: { action in
                model.save(action)
                editing = nil
            }, onDelete: {
                model.delete(draft.id)
                editing = nil
            }, onCancel: { editing = nil })
        }
        .alert(L("ring.delete.title", pendingDeletion?.title ?? ""), isPresented: Binding(
            get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }
        )) {
            Button(L("common.cancel"), role: .cancel) { pendingDeletion = nil }
            Button(L("common.delete"), role: .destructive) {
                if let id = pendingDeletion?.id { model.delete(id) }
                pendingDeletion = nil
            }
        } message: { Text(L("ring.delete.message")) }
        .alert(L("ring.reset.title"), isPresented: $confirmingReset) {
            Button(L("common.cancel"), role: .cancel) {}
            Button(L("ring.reset.confirm"), role: .destructive) { model.resetActions() }
        } message: { Text(L("ring.reset.message")) }
    }

    // MARK: - Shortcut and practice

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
                TFDivider.formWithIcon
                TFFormRow(title: L("ring.practice.title"), detail: L("ring.practice.detail"),
                          valueText: practice.isActive ? (practice.lastResult ?? L("ring.practice.waiting")) : nil,
                          icon: "scope") {
                    TFButton(title: L(practice.isActive ? "ring.practice.stop" : "ring.practice.start")) {
                        if practice.isActive { practice.stop() } else { practice.start() }
                    }
                    .accessibilityIdentifier("ring.practice")
                }
            }
            if let hotkeyNotice {
                TFFieldMessage(text: hotkeyNotice, tone: .warning).padding(.horizontal, 4)
            }
        }
    }

    private func toggleRecording() {
        if isRecording { return stopRecording() }
        isRecording = true
        hotkeyNotice = nil
        recorder.start { binding in
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
        TFFormSection(title: L("ring.actions.title"), count: configuration.actions.count) {
            TFButton(title: L("ring.actions.reset"), kind: .plain) { confirmingReset = true }
                .accessibilityIdentifier("ring.actions.reset")
        } content: {
            HStack(alignment: .center, spacing: 0) {
                RingPreviewView(actions: configuration.actions, style: configuration.style,
                                centerTitle: configuration.centerTitle, highlighted: $highlighted) { id in
                    if let action = configuration.actions.first(where: { $0.id == id }) {
                        editing = RingActionDraft(editing: action)
                    }
                }
                .frame(width: 280, height: 280)
                .padding(10)
                Rectangle().fill(TFColors.border).frame(width: TFMetrics.borderWidth)
                VStack(spacing: 0) {
                    actionList
                    Spacer(minLength: 0)
                    TFDivider(inset: 0)
                    TFActionRow(systemImage: "plus", title: L("ring.actions.add")) { editing = .new() }
                        .disabled(!configuration.canAddAction)
                        .opacity(configuration.canAddAction ? 1 : TFMetrics.disabledOpacity)
                        .help(configuration.canAddAction ? "" : L("ring.actions.full", RingConfiguration.maxActions))
                        .accessibilityIdentifier("ring.actions.add")
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    @ViewBuilder private var actionList: some View {
        if configuration.actions.isEmpty {
            Text(L("ring.actions.empty"))
                .font(.system(size: 12.5)).foregroundStyle(TFColors.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity).padding(.vertical, 28).padding(.horizontal, 20)
        } else {
            ForEach(Array(configuration.actions.enumerated()), id: \.element.id) { index, action in
                if index > 0 { TFDivider() }
                RingActionRow(
                    action: action,
                    detail: RingSettingsPresentation.detail(of: action, keywordName: keywordName),
                    isHighlighted: highlighted == action.id,
                    menu: menu(for: action, at: index),
                    onHover: { highlighted = $0 ? action.id : (highlighted == action.id ? nil : highlighted) },
                    onEdit: { editing = RingActionDraft(editing: action) }
                )
                .draggable(action.id.uuidString)
                .dropDestination(for: String.self) { items, _ in
                    guard let id = items.first.flatMap(UUID.init(uuidString:)) else { return false }
                    model.move(id, to: index)
                    return true
                }
            }
        }
    }

    private func keywordName(_ keyword: String, _ pluginID: String) -> String? {
        shortcuts.options.first { $0.keyword.pluginID == pluginID && $0.keyword.contains(keyword) }?.name
    }

    private func menu(for action: RingAction, at index: Int) -> [TFMenuAction] {
        let count = configuration.actions.count
        return [
            .action(L("common.edit"), systemImage: "pencil") { editing = RingActionDraft(editing: action) },
            .action(L("ring.action.duplicate"), systemImage: "plus.square.on.square",
                    isEnabled: configuration.canAddAction) { model.duplicate(action.id) },
            .separator,
            .action(L("ring.action.moveUp"), systemImage: "arrow.up", isEnabled: index > 0) {
                model.move(action.id, by: -1)
            },
            .action(L("ring.action.moveDown"), systemImage: "arrow.down", isEnabled: index < count - 1) {
                model.move(action.id, by: 1)
            },
            .separator,
            .action(L("common.delete"), systemImage: "trash", destructive: true) { pendingDeletion = action }
        ]
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
                        if limited != value { centerTitle = limited }
                        model.setCenterTitle(limited)
                    }
                    .accessibilityIdentifier("ring.centerTitle")
            }
        }
    }
}

/// The ring's on/off switch, in the page header next to the title.
struct RingEnabledSwitch: View {
    @StateObject private var model: RingSettingsModel

    init(settingsStore: SettingsStore) {
        _model = StateObject(wrappedValue: RingSettingsModel(settingsStore: settingsStore))
    }

    var body: some View {
        TFSwitch(title: L("ring.enabled"), isOn: Binding(get: { model.configuration.enabled }, set: model.setEnabled))
            .help(L("ring.enabled"))
            .accessibilityIdentifier("ring.enabled")
    }
}

/// A slice in the list. The description sits behind the hover "?" like every settings row.
struct RingActionRow: View {
    let action: RingAction
    let detail: String
    let isHighlighted: Bool
    let menu: [TFMenuAction]
    var onHover: (Bool) -> Void = { _ in }
    let onEdit: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            if let image = RingActionIcon.appIcon(for: action) {
                Image(nsImage: image).resizable().interpolation(.high)
                    .frame(width: TFMetrics.iconTileSize, height: TFMetrics.iconTileSize)
            } else {
                TFIconTile(systemImage: action.symbol, style: .neutral)
            }
            HStack(spacing: 6) {
                Text(action.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(TFColors.textPrimary)
                    .lineLimit(1)
                SettingsDescriptionHint(detail: detail, visible: hovering)
            }
            Spacer(minLength: 8)
            TFMenuButton(title: L("ring.action.more"), systemImage: "ellipsis", kind: .plain, size: .small,
                         iconOnly: true, actions: menu, identifier: "ring.action.more." + action.id.uuidString)
                .opacity(hovering ? 1 : 0)
        }
        .padding(.horizontal, TFMetrics.rowHorizontalPadding)
        .frame(minHeight: 44)
        .background(isHighlighted ? TFColors.selection : (hovering ? TFColors.hoverOverlay : Color.clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0; onHover($0) }
        .onTapGesture(perform: onEdit)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(action.title)
        .accessibilityHint(detail)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: L("common.edit"), onEdit)
    }
}
