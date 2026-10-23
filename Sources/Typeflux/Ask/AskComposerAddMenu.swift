import AppKit
import SwiftUI

/// One switch in the composer's "+" menu: something that rides along with the
/// question. The toolbar no longer shows these states; the menu is where they live.
struct AskAddMenuSwitch: Identifiable {
    var kind: AskContextItem.Kind
    var symbol: String
    var title: String
    var detail: String
    var isOn: Bool
    /// False while the switch cannot act, e.g. a screenshot the system does not allow.
    var enabled = true
    /// Warns instead of describing, e.g. a screenshot that failed.
    var warning = false
    /// The selected text, quoted under its switch while it is included.
    var preview: String?
    /// The captured screen, shown beside its switch so it can be checked before sending.
    var thumbnail: NSImage?
    var action: () -> Void

    var id: String { kind.rawValue }

    /// Builds the menu's switches from the composer's context items, in the order the
    /// menu lists them: screenshot, memory, selection. Source information is not a switch.
    static func make(items: [AskContextItem], selectionText: String?, screenshot: NSImage? = nil,
                     actions: (AskContextItem.Kind) -> (() -> Void)?) -> [AskAddMenuSwitch] {
        let order: [AskContextItem.Kind] = [.screenshot, .memory, .selection]
        return order.compactMap { kind in
            guard let item = items.first(where: { $0.kind == kind }) else { return nil }
            let action = actions(kind)
            switch kind {
            case .screenshot:
                return AskAddMenuSwitch(
                    kind: kind, symbol: "camera.viewfinder", title: L("ask.add.screenshot"),
                    // A failed capture is still included: its switch stays on, so turning it
                    // off is an explicit removal rather than a retry.
                    detail: screenshotDetail(item), isOn: item.style == .active || item.style == .warning,
                    enabled: action != nil, warning: item.style == .warning,
                    thumbnail: item.style == .warning || item.style == .unavailable ? nil : screenshot,
                    action: action ?? {})
            case .memory:
                return AskAddMenuSwitch(
                    kind: kind, symbol: "brain", title: L("ask.memory"),
                    detail: item.detail ?? L("ask.memory.help"), isOn: item.style == .active,
                    enabled: action != nil, action: action ?? {})
            case .selection:
                let lines = selectionText.map(AskPresentation.lineCount) ?? 0
                let detail = item.sourceAppName.map { L("ask.add.selection.detail", $0, lines) }
                    ?? L("ask.selection.lines", lines)
                return AskAddMenuSwitch(
                    kind: kind, symbol: "text.quote", title: L("ask.selection"), detail: detail,
                    isOn: item.style == .active, enabled: action != nil,
                    preview: selectionText.map(AskContextChips.selectionPreview),
                    action: action ?? {})
            case .source:
                return nil
            }
        }
    }

    private static func screenshotDetail(_ item: AskContextItem) -> String {
        switch item.style {
        case .active: L("ask.context.screen.scope")
        case .neutral: L("ask.add.screenshot.offDetail")
        case .unavailable, .warning: item.detail ?? item.title
        }
    }
}

/// What the "+" menu offers besides files: the switches, where a new conversation
/// is kept, and the source information to bring back after it was removed.
struct AskAddMenuContext {
    var switches: [AskAddMenuSwitch] = []
    /// Set while the conversation has not started and can still choose where it is kept.
    var storage: AskLocalModeStatus?
    var chooseStorage: (AskStorageKind) -> Void = { _ in }
    /// The app whose information was removed from this question, to offer it again.
    var sourceToRestore: String?
    var restoreSource: () -> Void = {}
}

/// The "+" menu: add files, then what rides along with this question, then where a
/// new conversation is kept. Rows keep their titles and controls; failures still show their reason.
struct AskComposerAddMenu: View {
    static let width: CGFloat = 340

    let context: AskAddMenuContext
    var pickFiles: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            AskAddMenuRow(symbol: "paperclip", title: L("ask.add.files"), detail: nil,
                          action: pickFiles) {
                Text(verbatim: "⌘U").font(.system(size: 11.5)).foregroundStyle(StudioTheme.textTertiary)
            }
            .accessibilityIdentifier("ask.add.files")
            if !context.switches.isEmpty || context.sourceToRestore != nil {
                separator
                header(L("ask.add.context"))
                ForEach(context.switches) { item in switchRow(item) }
                if let app = context.sourceToRestore {
                    AskAddMenuRow(symbol: "app", title: L("ask.context.restore.source", app), detail: nil,
                                  action: context.restoreSource) { EmptyView() }
                        .accessibilityIdentifier("ask.context.restore.source")
                }
            }
            if let storage = context.storage, !storage.choices.isEmpty {
                separator
                header(L("ask.storage.card.title"))
                AskStorageSegments(choices: storage.choices, selection: storage.kind, choose: context.chooseStorage)
                    .padding(.horizontal, 10)
            }
        }
        .padding(.vertical, 6)
        .frame(width: Self.width, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ask.add.menu")
    }

    private var separator: some View {
        Rectangle().fill(AskTheme.separator).frame(height: 0.5).padding(.horizontal, 10).padding(.vertical, 6)
    }

    private func header(_ text: String) -> some View {
        Text(text).font(.system(size: 11, weight: .semibold)).foregroundStyle(StudioTheme.textTertiary)
            .padding(.horizontal, 12).padding(.top, 2).padding(.bottom, 4)
    }

    @ViewBuilder private func switchRow(_ item: AskAddMenuSwitch) -> some View {
        AskAddMenuRow(symbol: item.symbol, title: item.title, detail: item.warning || !item.enabled ? item.detail : nil, active: item.isOn,
                      warning: item.warning, enabled: item.enabled, action: item.action) {
            HStack(spacing: 10) {
                if let thumbnail = item.thumbnail {
                    Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fill)
                        .frame(width: 40, height: 26)
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(AskTheme.border, lineWidth: 0.5))
                        .opacity(item.isOn ? 1 : 0.5)
                        .accessibilityIdentifier("ask.add.screenshot.thumbnail")
                }
                AskMenuSwitch(isOn: item.isOn).opacity(item.enabled ? 1 : 0)
            }
        }
        .accessibilityValue(L(item.isOn ? "ask.context.selection.enabled" : "ask.context.selection.disabled"))
        .accessibilityIdentifier("ask.add." + item.kind.rawValue)
        if item.isOn, let preview = item.preview {
            Text(verbatim: "“" + preview + "”")
                .font(.system(size: 11.5))
                .foregroundStyle(StudioTheme.textSecondary)
                .lineLimit(2)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AskTheme.hoverFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(alignment: .leading) {
                    Rectangle().fill(AskTheme.accent.opacity(0.6)).frame(width: 2)
                }
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .padding(.leading, 52).padding(.trailing, 12).padding(.bottom, 4)
        }
    }
}

/// A "+" menu row: an icon in a rounded tile, a title with one line of detail and
/// a trailing accessory such as a shortcut or a switch.
struct AskAddMenuRow<Accessory: View>: View {
    var symbol: String
    var title: String
    var detail: String?
    var active = false
    var warning = false
    var enabled = true
    var action: () -> Void
    @ViewBuilder var accessory: () -> Accessory
    @State private var hovering = false
    @Environment(\.interfaceStyle) private var style

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(warning ? StudioTheme.warning : active ? AskTheme.accent : StudioTheme.textPrimary)
                    .frame(width: 30, height: 30)
                    .background(active ? AskTheme.switchOnFill : AskTheme.hoverFill,
                                in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13)).foregroundStyle(StudioTheme.textPrimary).lineLimit(1)
                    if let detail, !detail.isEmpty {
                        Text(detail).font(.system(size: 11))
                            .foregroundStyle(warning ? StudioTheme.warning : StudioTheme.textSecondary)
                            .lineLimit(1).truncationMode(.tail)
                    }
                }
                Spacer(minLength: 8)
                accessory()
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(hovering && enabled ? AskTheme.hoverFill : .clear,
                        in: RoundedRectangle(cornerRadius: style.ask.menuRowCorner, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.55)
        .onHover { hovering = $0 }
        .padding(.horizontal, 4)
    }
}

/// A small switch drawn like the system one; the row around it is the button.
struct AskMenuSwitch: View {
    var isOn: Bool

    var body: some View {
        Capsule(style: .continuous)
            .fill(isOn ? AskTheme.accent : AskTheme.pressFill)
            .frame(width: 30, height: 18)
            .overlay(alignment: isOn ? .trailing : .leading) {
                Circle().fill(Color.white).frame(width: 14, height: 14)
                    .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
                    .padding(2)
            }
            .animation(.easeOut(duration: 0.15), value: isOn)
            .accessibilityHidden(true)
    }
}

/// Where a new conversation is kept, as one segmented control.
struct AskStorageSegments: View {
    let choices: [AskStorageKind]
    let selection: AskStorageKind
    var choose: (AskStorageKind) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(choices, id: \.self) { kind in
                let chosen = kind == selection
                Button { choose(kind) } label: {
                    HStack(spacing: 5) {
                        Image(systemName: kind.symbol).font(.system(size: 11, weight: .medium))
                        Text(L(kind.titleKey)).font(.system(size: 12, weight: chosen ? .semibold : .regular))
                            .lineLimit(1)
                    }
                    .foregroundStyle(chosen ? AskLocalModeCard.tint(kind) : StudioTheme.textSecondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 26)
                    .background {
                        if chosen {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(AskTheme.controlSurface)
                                .shadow(color: .black.opacity(0.18), radius: 1.5, y: 1)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(chosen ? .isSelected : [])
                .accessibilityValue(chosen ? L("ask.mode.current") : "")
                .accessibilityIdentifier("ask.add.storage." + String(describing: kind))
            }
        }
        .padding(2)
        .background(AskTheme.hoverFill, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("ask.storage.card.title"))
    }
}
