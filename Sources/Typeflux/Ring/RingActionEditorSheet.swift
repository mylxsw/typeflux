import AppKit
import SwiftUI

/// One entry of a target picker in the editor.
struct RingTargetChoice {
    let kind: RingActionKind
    let title: String
    let subtitle: String?
    let symbol: String?
}

/// Adds or edits one slice. Laid out like the keyword shortcut sheet: labels on the left,
/// [Cancel] [Add] on the right, Delete on the left when editing.
struct RingActionEditorSheet: View {
    @State var draft: RingActionDraft
    let keywords: [KeywordHotkeyOption]
    let onSave: (RingAction) -> Void
    let onDelete: () -> Void
    let onCancel: () -> Void
    @StateObject private var recorder = HotkeyRecorder()
    @State private var apps: [PersonaAppCandidate] = []
    @State private var loadingApps = false
    @State private var confirmingDelete = false
    @State private var choosingSymbol = false
    @State private var urlTouched = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L(draft.isNew ? "ring.editor.addTitle" : "ring.editor.editTitle"))
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(StudioTheme.textPrimary)
                .padding(.horizontal, 22).padding(.top, 20).padding(.bottom, 18)
            VStack(alignment: .leading, spacing: 14) {
                field(L("ring.editor.type")) {
                    TFPopUpButton(title: L("ring.editor.type"),
                                  options: RingActionType.allCases.map {
                                      TFOption($0, $0.title, systemImage: $0.symbol)
                                  },
                                  selection: Binding(get: { draft.type }, set: { setType($0) }), width: 348,
                                  identifier: "ring.editor.type")
                }
                field(draft.type.targetLabel) { target }
                field(L("ring.editor.name")) {
                    TextField(L("ring.editor.namePlaceholder"), text: $draft.title)
                        .textFieldStyle(TFTextFieldStyle())
                        .accessibilityIdentifier("ring.editor.name")
                }
                field(L("ring.editor.icon")) { iconPicker }
            }
            .padding(.horizontal, 22)
            footer.padding(.horizontal, 22).padding(.top, 18).padding(.bottom, 20)
        }
        .frame(width: 480)
        .background(ModelVisualStyle.canvas)
        .task(id: draft.type) { await loadAppsIfNeeded() }
        .onDisappear { recorder.stop() }
        .alert(L("ring.delete.title", draft.title), isPresented: $confirmingDelete) {
            Button(L("common.cancel"), role: .cancel) {}
            Button(L("common.delete"), role: .destructive, action: onDelete)
        } message: { Text(L("ring.delete.message")) }
    }

    // MARK: - Target

    @ViewBuilder private var target: some View {
        switch draft.type {
        case .feature:
            picker(RingFeature.allCases.map {
                RingTargetChoice(kind: .feature($0), title: $0.title, subtitle: $0.detail, symbol: $0.symbol)
            })
        case .keyword:
            picker(keywords.map { option in
                RingTargetChoice(kind: .keyword(keyword: option.keyword.keyword, pluginID: option.keyword.pluginID),
                                 title: option.name, subtitle: option.keyword.keyword, symbol: nil)
            }, searchable: keywords.count > 12)
        case .app:
            if loadingApps && apps.isEmpty {
                Text(L("ring.editor.loadingApps")).font(.system(size: 12.5)).foregroundStyle(TFColors.textSecondary)
                    .frame(height: 30)
            } else {
                picker(apps.compactMap { app in
                    app.bundleIdentifier.map {
                        RingTargetChoice(kind: .app(bundleIdentifier: $0, name: app.displayName),
                                         title: app.displayName, subtitle: $0, symbol: nil)
                    }
                }, searchable: true)
            }
        case .keys:
            keysRecorder
        case .system:
            picker(RingSystemAction.allCases.map {
                RingTargetChoice(kind: .system($0), title: $0.title, subtitle: $0.detail, symbol: $0.symbol)
            })
        case .shortcut:
            textTarget(placeholder: L("ring.editor.shortcutPlaceholder"))
        case .url:
            VStack(alignment: .leading, spacing: 5) {
                TextField("https://", text: Binding(get: { draft.text }, set: { draft.setText($0) }),
                          onEditingChanged: { editing in if !editing { urlTouched = true } })
                    .textFieldStyle(TFTextFieldStyle(monospaced: true, isError: urlTouched && draft.hasInvalidURL))
                    .accessibilityIdentifier("ring.editor.url")
                if urlTouched && draft.hasInvalidURL {
                    TFFieldMessage(text: L("ring.editor.urlInvalid"))
                }
            }
        case .folder:
            HStack(spacing: TFMetrics.toolbarSpacing) {
                textTarget(placeholder: "~/Downloads")
                TFButton(title: L("ring.editor.chooseFolder")) { chooseFolder() }
            }
        }
    }

    /// Choices are keyed by `RingActionKind.pickerKey`; a choice without a symbol keeps the current one.
    private func picker(_ choices: [RingTargetChoice], searchable: Bool? = nil) -> some View {
        TFRichPicker(title: L("ring.editor.choose"),
                     sections: [TFRichSection(options: choices.map {
                         TFRichOption(Optional($0.kind.pickerKey), $0.title, subtitle: $0.subtitle,
                                      systemImage: $0.symbol)
                     })],
                     selection: Binding(get: { draft.kind?.pickerKey }, set: { key in
                         guard let choice = choices.first(where: { $0.kind.pickerKey == key }) else { return }
                         draft.choose(choice.kind, title: choice.title, symbol: choice.symbol)
                     }), width: 348, searchable: searchable, identifier: "ring.editor.target")
    }

    private func textTarget(placeholder: String) -> some View {
        TextField(placeholder, text: Binding(get: { draft.text }, set: { draft.setText($0) }))
            .textFieldStyle(TFTextFieldStyle())
            .accessibilityIdentifier("ring.editor.text")
    }

    private var keysRecorder: some View {
        Button {
            if recorder.isRecording { recorder.stop(); return }
            recorder.start { binding in
                draft.choose(.keys(binding), title: L("ring.editor.keysTitle", HotkeyFormat.display(binding)),
                             symbol: "keyboard")
            }
        } label: {
            HStack(spacing: 6) {
                if case let .keys(binding) = draft.kind, !recorder.isRecording {
                    HotkeyKeysView(binding: binding)
                } else {
                    HotkeyKeysView(binding: nil, isRecording: recorder.isRecording)
                }
                Spacer(minLength: 8)
                Text(L(draft.kind == nil ? "ring.editor.record" : "ring.editor.rerecord"))
                    .font(.system(size: 11.5)).foregroundStyle(TFColors.textTertiary)
            }
            .padding(.horizontal, 6)
            .frame(height: 34)
            .background(RoundedRectangle(cornerRadius: TFMetrics.fieldCornerRadius, style: .continuous)
                .fill(TFColors.control))
            .overlay(RoundedRectangle(cornerRadius: TFMetrics.fieldCornerRadius, style: .continuous)
                .strokeBorder(recorder.isRecording ? TFColors.accent : TFColors.border, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L("ring.editor.record"))
        .accessibilityIdentifier("ring.editor.keys")
    }

    // MARK: - Icon

    @ViewBuilder private var iconPicker: some View {
        if case .app = draft.kind {
            Text(L("ring.editor.useAppIcon")).font(.system(size: 12.5)).foregroundStyle(TFColors.textSecondary)
                .frame(height: 30)
        } else {
            Button { choosingSymbol.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: draft.symbol).font(.system(size: 13, weight: .medium))
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).opacity(0.75)
                }
            }
            .buttonStyle(TFButtonStyle(kind: .secondary))
            .accessibilityLabel(L("ring.editor.icon"))
            .accessibilityIdentifier("ring.editor.icon")
            .popover(isPresented: $choosingSymbol, arrowEdge: .bottom) {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(30), spacing: 4), count: 8), spacing: 4) {
                    ForEach(RingSettingsPresentation.symbolChoices, id: \.self) { symbol in
                        Button {
                            draft.symbol = symbol
                            choosingSymbol = false
                        } label: {
                            Image(systemName: symbol).font(.system(size: 13, weight: .medium))
                                .frame(width: 30, height: 30)
                                .foregroundStyle(symbol == draft.symbol ? Color.white : TFColors.textPrimary)
                                .background(
                                    RoundedRectangle(cornerRadius: TFMetrics.itemCornerRadius, style: .continuous)
                                        .fill(symbol == draft.symbol ? TFColors.accent : Color.clear)
                                )
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(symbol)
                    }
                }
                .padding(8)
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: TFMetrics.toolbarSpacing) {
            if !draft.isNew {
                TFButton(title: L("common.delete"), kind: .plain, destructive: true) { confirmingDelete = true }
                    .accessibilityIdentifier("ring.editor.delete")
            }
            Spacer()
            TFButton(title: L("common.cancel"), action: onCancel)
                .keyboardShortcut(.cancelAction)
            TFButton(title: L(draft.isNew ? "ring.editor.add" : "common.save"), kind: .primary) {
                if let action = draft.action { onSave(action) }
            }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!draft.canSave || recorder.isRecording)
            .accessibilityIdentifier("ring.editor.save")
        }
    }

    private func field(_ label: String, @ViewBuilder content: () -> some View) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).font(.system(size: 12.5)).foregroundStyle(StudioTheme.textSecondary)
                .frame(width: 76, alignment: .leading)
            VStack(alignment: .leading, spacing: 5) { content() }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Helpers

    private func setType(_ type: RingActionType) {
        recorder.stop()
        urlTouched = false
        draft.setType(type)
    }

    private func loadAppsIfNeeded() async {
        guard draft.type == .app, apps.isEmpty, !loadingApps else { return }
        loadingApps = true
        let found = await PersonaAppDiscovery.discoverPersonaAppCandidates(scope: .all)
        apps = found.filter { $0.bundleIdentifier != nil }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        loadingApps = false
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        draft.setText((url.path as NSString).abbreviatingWithTildeInPath)
    }
}
