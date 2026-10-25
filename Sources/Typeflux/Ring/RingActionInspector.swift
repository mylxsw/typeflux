import SwiftUI

/// Edits one slice in place. Every change is saved at once; there is no Save button.
struct RingActionInspector: View {
    let action: RingAction
    let index: Int
    let count: Int
    let issue: String?
    let defaultTitle: String
    let targetSummary: String
    var onRename: (String) -> Void = { _ in }
    var onSymbol: (String) -> Void = { _ in }
    /// A new target typed or recorded here; the caller decides whether the name follows it.
    var onRetarget: (RingActionKind) -> Void = { _ in }
    var onReplace: () -> Void = {}
    var onMove: (Int) -> Void = { _ in }
    var onDuplicate: () -> Void = {}
    var onDelete: () -> Void = {}
    var onDone: () -> Void = {}

    @State private var name = ""
    @State private var text = ""
    @FocusState private var nameFocused: Bool

    private var canDuplicate: Bool {
        count < RingConfiguration.maxActions
    }

    var body: some View {
        VStack(spacing: 0) {
            RingInspectorHeader(title: "", closeTitle: L("ring.inspector.done"), onClose: onDone)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    // A bad web address is already flagged under its field.
                    if let issue, action.kind.type != .url {
                        RingInspectorBanner(systemImage: "exclamationmark.triangle", tint: TFColors.warning,
                                            title: issue) {
                            TFButton(title: L("ring.inspector.replace"), size: .small, action: onReplace)
                        }
                    }
                    nameHeader
                    targetBlock
                    iconBlock
                    block {
                        row { RingPositionControls(index: index, count: count, onMove: onMove) }
                    }
                }
                .padding(.horizontal, 12).padding(.bottom, 12)
            }
            TFDivider(inset: 0)
            footer
        }
        .onAppear(perform: load)
        .onChange(of: action.id) { _ in load() }
        .onChange(of: action.title) { title in
            // The name follows a new target or an undo, but a field cleared to the default stays empty.
            let typed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if typed != title, !(typed.isEmpty && title == defaultTitle) {
                name = title
            }
        }
    }

    private func load() {
        name = action.title
        switch action.kind {
        case let .url(url): text = url
        case let .folder(path): text = path
        case let .shortcut(shortcut): text = shortcut
        default: text = ""
        }
    }

    // MARK: - Name

    private var nameHeader: some View {
        HStack(spacing: 12) {
            RingIconTile(action: action, size: 46, dark: true)
            HStack(spacing: 4) {
                TextField(defaultTitle, text: $name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15, weight: .semibold))
                    .focused($nameFocused)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(nameFocused ? TFColors.control : Color.clear))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(nameFocused ? TFColors.accent : Color.clear, lineWidth: 1))
                    .padding(.leading, -6)
                    .onChange(of: name) { value in
                        let limited = String(value.prefix(RingSettingsPresentation.titleLimit))
                        if limited != value {
                            name = limited
                        }
                        let trimmed = limited.trimmingCharacters(in: .whitespacesAndNewlines)
                        onRename(trimmed.isEmpty ? defaultTitle : trimmed)
                    }
                    .onSubmit { nameFocused = false }
                    .accessibilityLabel(L("ring.editor.name"))
                    .accessibilityIdentifier("ring.inspector.name")
                if action.title != defaultTitle, issue == nil {
                    TFButton(title: L("ring.inspector.resetName", defaultTitle), systemImage: "arrow.uturn.backward",
                             kind: .plain, size: .small, iconOnly: true) { name = defaultTitle }
                }
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Target

    private var targetBlock: some View {
        block {
            row {
                TFIconTile(systemImage: action.kind.type.symbol, tint: action.kind.type.tint, size: 26, style: .filled)
                VStack(alignment: .leading, spacing: 1) {
                    Text(action.kind.type.title).font(.system(size: 12.5)).foregroundStyle(TFColors.textPrimary)
                    // Only a keyword needs naming here; other targets are the name or the field below.
                    if case .keyword = action.kind {
                        Text(targetSummary).font(.system(size: 11)).foregroundStyle(TFColors.textSecondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 6)
                TFButton(title: L("ring.inspector.replace"), size: .small, action: onReplace)
                    .accessibilityIdentifier("ring.inspector.replace")
            }
            parameterRow
        }
    }

    @ViewBuilder private var parameterRow: some View {
        switch action.kind {
        case .url:
            let invalid = RingSettingsPresentation.webURL(text) == nil
            divider
            row {
                VStack(alignment: .leading, spacing: 4) {
                    TextField("https://", text: $text)
                        .textFieldStyle(TFTextFieldStyle(monospaced: true, isError: invalid))
                        .onChange(of: text) { value in
                            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                            if RingSettingsPresentation.webURL(trimmed) != nil {
                                onRetarget(.url(trimmed))
                            }
                        }
                        .accessibilityIdentifier("ring.inspector.url")
                    if invalid {
                        TFFieldMessage(text: L("ring.editor.urlInvalid"))
                    }
                }
            }
        case .folder:
            divider
            row {
                TextField("~/Downloads", text: $text)
                    .textFieldStyle(TFTextFieldStyle(monospaced: true))
                    .onSubmit(commitText)
                    .accessibilityIdentifier("ring.inspector.folder")
                TFButton(title: L("ring.editor.chooseFolder"), size: .small) {
                    if let path = RingFolderPicker.choose() {
                        text = path
                        commitText()
                    }
                }
            }
        case .shortcut:
            divider
            row {
                TextField(L("ring.editor.shortcutPlaceholder"), text: $text)
                    .textFieldStyle(TFTextFieldStyle())
                    .onSubmit(commitText)
                    .accessibilityIdentifier("ring.inspector.shortcut")
            }
        case let .keys(binding):
            divider
            row {
                RingKeysField(binding: binding) { onRetarget(.keys($0)) }
                    .id(action.id)
            }
        default:
            EmptyView()
        }
    }

    /// Folder paths and shortcut names are taken when Return is pressed or a folder is chosen,
    /// so a half-typed path never becomes the target.
    private func commitText() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return load() }
        switch action.kind {
        case .folder: onRetarget(.folder(path: trimmed))
        case .shortcut: onRetarget(.shortcut(name: trimmed))
        default: break
        }
    }

    // MARK: - Icon

    /// Apps always draw their own icon, so they have no icon choice.
    @ViewBuilder private var iconBlock: some View {
        if action.kind.type != .app {
            block {
                RingSymbolGrid(symbols: symbolChoices(including: RingActionLibrary.defaultSymbol(for: action.kind)),
                               selected: action.symbol, onPick: onSymbol)
                    .padding(6)
            }
        }
    }

    private func symbolChoices(including defaultSymbol: String) -> [String] {
        var choices = RingSettingsPresentation.symbolChoices
        for symbol in [defaultSymbol, action.symbol] where !choices.contains(symbol) {
            choices.insert(symbol, at: 0)
        }
        return choices
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            TFButton(title: L("ring.action.duplicate"), systemImage: "plus.square.on.square", size: .small,
                     action: onDuplicate)
                .disabled(!canDuplicate)
                .help(canDuplicate ? "" : L("ring.actions.full", RingConfiguration.maxActions))
                .accessibilityIdentifier("ring.inspector.duplicate")
            Spacer()
            TFButton(title: L("common.delete"), systemImage: "trash", kind: .plain, destructive: true, size: .small,
                     action: onDelete)
                .accessibilityIdentifier("ring.inspector.delete")
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }

    // MARK: - Layout helpers

    private var divider: some View {
        TFDivider(inset: 0)
    }

    private func block(@ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 0) { content() }
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(TFColors.control.opacity(0.45)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(TFColors.border, lineWidth: TFMetrics.borderWidth))
    }

    private func row(@ViewBuilder _ content: () -> some View) -> some View {
        HStack(spacing: 10) { content() }
            .padding(.horizontal, 10).frame(minHeight: 44)
    }
}

/// Where a slice sits on the ring, as dots around a circle.
struct RingDirectionDots: View {
    let index: Int
    let count: Int

    var body: some View {
        GeometryReader { proxy in
            let size = min(proxy.size.width, proxy.size.height)
            let geometry = RingPreviewGeometry(size: size, count: count)
            ZStack {
                Circle().strokeBorder(TFColors.textTertiary.opacity(0.6), lineWidth: 1)
                    .frame(width: size * 0.24, height: size * 0.24)
                ForEach(0 ..< max(count, 0), id: \.self) { slot in
                    Circle().fill(slot == index ? TFColors.accent : TFColors.textTertiary.opacity(0.5))
                        .frame(width: slot == index ? 6.5 : 4, height: slot == index ? 6.5 : 4)
                        .position(geometry.point(at: size * 0.36, angle: geometry.angle(of: slot)))
                }
            }
            .frame(width: size, height: size)
        }
        .accessibilityHidden(true)
    }
}

/// The icons a slice can use, nine to a row.
struct RingSymbolGrid: View {
    let symbols: [String]
    let selected: String
    let onPick: (String) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 9), spacing: 2) {
                    ForEach(symbols, id: \.self) { symbol in
                        Button { onPick(symbol) } label: {
                            Image(systemName: symbol).font(.system(size: 13, weight: .medium))
                                .frame(maxWidth: .infinity).frame(height: 28)
                                .foregroundStyle(symbol == selected ? Color.white : TFColors.textPrimary)
                                .background(RoundedRectangle(
                                    cornerRadius: TFMetrics.itemCornerRadius,
                                    style: .continuous
                                )
                                .fill(symbol == selected ? TFColors.accent : Color.clear))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .id(symbol)
                        .help(symbol)
                        .accessibilityLabel(symbol)
                        .accessibilityAddTraits(symbol == selected ? .isSelected : [])
                    }
                }
            }
            .frame(height: 178)
            .onAppear { proxy.scrollTo(selected, anchor: .center) }
            .onChange(of: selected) { symbol in
                proxy.scrollTo(symbol, anchor: .center)
            }
        }
    }
}

/// Shows a key combination and records a new one when clicked.
struct RingKeysField: View {
    let binding: HotkeyBinding
    let onRecord: (HotkeyBinding) -> Void
    @StateObject private var recorder = HotkeyRecorder()

    var body: some View {
        Button {
            if recorder.isRecording {
                recorder.stop()
            } else {
                recorder.start(onRecorded: onRecord)
            }
        } label: {
            HStack(spacing: 6) {
                HotkeyKeysView(binding: recorder.isRecording ? nil : binding, isRecording: recorder.isRecording)
                Spacer(minLength: 6)
            }
            .padding(.horizontal, 6).frame(height: 32)
            .background(RoundedRectangle(cornerRadius: TFMetrics.fieldCornerRadius, style: .continuous)
                .fill(TFColors.control))
            .overlay(RoundedRectangle(cornerRadius: TFMetrics.fieldCornerRadius, style: .continuous)
                .strokeBorder(recorder.isRecording ? TFColors.accent : TFColors.border, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onDisappear { recorder.stop() }
        .accessibilityLabel(L("ring.editor.record"))
        .accessibilityIdentifier("ring.inspector.keys")
    }
}

/// Where a slice sits and the buttons that turn it around the ring.
struct RingPositionControls: View {
    let index: Int
    let count: Int
    let onMove: (Int) -> Void

    var body: some View {
        RingDirectionDots(index: index, count: count).frame(width: 30, height: 30)
            .accessibilityElement()
            .accessibilityLabel(L("ring.inspector.positionValue", index + 1,
                                  RingSettingsPresentation.direction(of: index, count: count)))
        Spacer(minLength: 6)
        TFButton(title: L("ring.inspector.moveCounterClockwise"), systemImage: "arrow.counterclockwise",
                 size: .small, iconOnly: true) { onMove(-1) }
            .disabled(count < 2)
            .accessibilityIdentifier("ring.inspector.moveCounterClockwise")
        TFButton(title: L("ring.inspector.moveClockwise"), systemImage: "arrow.clockwise", size: .small,
                 iconOnly: true) { onMove(1) }
            .disabled(count < 2)
            .accessibilityIdentifier("ring.inspector.moveClockwise")
    }
}
