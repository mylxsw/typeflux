import SwiftUI

/// A tinted box with an icon and a message: why a pane is empty, a test result, a warning.
struct TFNotice: View {
    enum Tone: CaseIterable { case info, success, warning, danger }

    let text: String
    var tone: Tone = .info

    var color: Color {
        switch tone {
        case .info: TFColors.accent
        case .success: TFColors.success
        case .warning: TFColors.warning
        case .danger: TFColors.danger
        }
    }

    var systemImage: String {
        switch tone {
        case .info: "info.circle"
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle"
        case .danger: "exclamationmark.triangle.fill"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemImage).foregroundStyle(color).accessibilityHidden(true)
            Text(text)
                .foregroundStyle(tone == .info ? TFColors.textSecondary : color)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .font(.system(size: 12.5))
        .padding(.horizontal, 12).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.1),
                    in: RoundedRectangle(cornerRadius: TFMetrics.fieldCornerRadius, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// Confirms a removal and offers to undo it for a few seconds, then dismisses itself.
struct TFUndoBar: View {
    let message: String
    var undoTitle: String = L("component.undo")
    let onUndo: () -> Void
    let onDismiss: () -> Void
    var duration: Duration = .seconds(5)

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle").foregroundStyle(TFColors.textSecondary)
                .accessibilityHidden(true)
            Text(message).font(.system(size: 12.5)).foregroundStyle(TFColors.textPrimary).lineLimit(1)
            Spacer(minLength: 8)
            TFButton(title: undoTitle, size: .small, action: onUndo)
        }
        .padding(.horizontal, 12).frame(height: 40)
        .background(TFColors.card, in: RoundedRectangle(cornerRadius: TFMetrics.fieldCornerRadius + 2,
                                                         style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: TFMetrics.fieldCornerRadius + 2, style: .continuous)
            .strokeBorder(TFColors.border, lineWidth: TFMetrics.borderWidth))
        .task(id: message) {
            try? await Task.sleep(for: duration)
            if !Task.isCancelled { onDismiss() }
        }
    }
}

/// A quiet row inside a card that reveals rarely needed fields below it.
struct TFDisclosureRow: View {
    let title: String
    @Binding var isExpanded: Bool

    var body: some View {
        Button {
            isExpanded.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .animation(.easeOut(duration: 0.15), value: isExpanded)
                Text(title).font(.system(size: 12.5, weight: .medium))
                Spacer(minLength: 0)
            }
            .foregroundStyle(TFColors.textSecondary)
            .padding(.horizontal, 14).frame(height: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(L(isExpanded ? "component.expanded" : "component.collapsed"))
    }
}

/// A secret field (API keys) with a button that shows or hides the value.
struct TFSecureField: View {
    let placeholder: String
    @Binding var text: String
    var monospaced = true
    var showTitle: String = L("models.showKey")
    var hideTitle: String = L("models.hideKey")
    @State private var revealed = false

    var body: some View {
        Group {
            if revealed {
                TextField(placeholder, text: $text)
            } else {
                SecureField(placeholder, text: $text)
            }
        }
        .textFieldStyle(TFTextFieldStyle(monospaced: monospaced))
        .overlay(alignment: .trailing) {
            Button { revealed.toggle() } label: {
                Image(systemName: revealed ? "eye.slash" : "eye")
                    .font(.system(size: 12)).foregroundStyle(TFColors.textSecondary)
                    .frame(width: 26, height: 26).contentShape(Rectangle())
            }
            .buttonStyle(.plain).padding(.trailing, 3)
            .help(revealed ? hideTitle : showTitle)
            .accessibilityLabel(revealed ? hideTitle : showTitle)
        }
    }
}

/// Multi-line text input in the shared field style.
struct TFTextArea: View {
    let label: String
    @Binding var text: String
    var height: CGFloat = 72
    var monospaced = false
    var isFocusedStyle = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: TFMetrics.fieldCornerRadius, style: .continuous)
        TextEditor(text: $text)
            .font(.system(size: monospaced ? 12 : 13, design: monospaced ? .monospaced : .default))
            .scrollContentBackground(.hidden)
            .padding(6)
            .frame(height: height)
            .background(shape.fill(TFColors.control))
            .overlay(shape.strokeBorder(isFocusedStyle ? TFColors.accent.opacity(0.6) : TFColors.border,
                                        lineWidth: isFocusedStyle ? 1 : TFMetrics.borderWidth))
            .accessibilityLabel(label)
    }
}

/// A quiet explanatory line under a card, field or group.
struct TFFootnote: View {
    let text: String

    var body: some View {
        Text(text).font(.system(size: 12)).foregroundStyle(TFColors.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// What an option includes (✓) and gives up (–), e.g. inside a choice card.
struct TFChecklist: View {
    var systemImage: String?
    let items: [(included: Bool, text: String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let systemImage {
                Image(systemName: systemImage).font(.system(size: 15)).foregroundStyle(TFColors.textSecondary)
                    .padding(.bottom, 3).accessibilityHidden(true)
            }
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: item.included ? "checkmark" : "minus")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(item.included ? TFColors.success : TFColors.textTertiary)
                        .frame(width: 12)
                        .accessibilityHidden(true)
                    Text(item.text).font(.system(size: 12)).foregroundStyle(TFColors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

/// A labelled block of read-only text on the control fill, e.g. a transcript in an expanded row.
/// The accessory (copy, play) sits on the right of the label.
struct TFDetailBlock<Accessory: View>: View {
    let title: String
    let content: String
    var emphasize = false
    @ViewBuilder var accessory: Accessory

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: TFMetrics.toolbarSpacing) {
                Text(title).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(TFColors.textTertiary)
                Spacer(minLength: 0)
                accessory.tfControlSize(.small)
            }
            Text(content).font(.system(size: 12.5))
                .foregroundStyle(emphasize ? TFColors.danger : TFColors.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(TFColors.control, in: RoundedRectangle(cornerRadius: TFMetrics.fieldCornerRadius,
                                                            style: .continuous))
    }
}

extension TFDetailBlock where Accessory == EmptyView {
    init(title: String, content: String, emphasize: Bool = false) {
        self.init(title: title, content: content, emphasize: emphasize) { EmptyView() }
    }
}

/// A small card holding one short value, e.g. a vocabulary term, with a remove button on hover.
struct TFTermTile: View {
    let title: String
    var systemImage: String?
    var image: NSImage?
    var removeTitle: String = L("component.remove")
    var onRemove: (() -> Void)?
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: TFMetrics.cardCornerRadius, style: .continuous)
        HStack(spacing: 8) {
            Group {
                if let image {
                    Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
                } else if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 12)).foregroundStyle(TFColors.textTertiary)
                }
            }
            .frame(width: 16, height: 16)
            .accessibilityHidden(true)
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(TFColors.textPrimary).lineLimit(1)
            Spacer(minLength: 6)
            if let onRemove {
                TFButton(title: removeTitle, systemImage: "xmark", kind: .plain, size: .small, iconOnly: true,
                         action: onRemove)
                    .opacity(hovering ? 1 : 0)
                    .allowsHitTesting(hovering)
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 44)
        .background(TFColors.card, in: shape)
        .overlay(shape.strokeBorder(TFColors.border, lineWidth: TFMetrics.borderWidth))
        .contentShape(shape)
        .onHover { hovering = $0 }
    }
}

/// A form line with a fixed label column and a field filling the rest, for connection forms
/// with many text fields (endpoint, key, model). Use `TFFormRow` for settings with a control.
struct TFLabeledField<Field: View>: View {
    let label: String
    var isRequired = false
    var labelWidth: CGFloat = 112
    /// Accessibility identifier of the label column.
    var labelIdentifier: String?
    @ViewBuilder var field: Field

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            HStack(spacing: 2) {
                Text(label).font(.system(size: 13)).foregroundStyle(TFColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if isRequired {
                    Text(verbatim: "*").font(.system(size: 13)).foregroundStyle(TFColors.danger)
                        .accessibilityLabel(L("component.required"))
                }
            }
            .frame(width: labelWidth, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(labelIdentifier ?? "")
            field.frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }
}

/// A text field with a menu of suggested values (endpoints, model names); typing any value still works.
struct TFComboField: View {
    let placeholder: String
    @Binding var text: String
    let suggestions: [String]
    var monospaced = true
    var accessibilityLabel: String?
    var menuTitle: String = L("common.selectSuggestedValue")

    /// Trimmed, non-empty suggestions without case-insensitive duplicates, in their original order.
    static func normalized(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.compactMap { raw in
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, seen.insert(value.lowercased()).inserted else { return nil }
            return value
        }
    }

    var body: some View {
        let options = Self.normalized(suggestions)
        TextField(placeholder, text: $text)
            .textFieldStyle(TFTextFieldStyle(monospaced: monospaced))
            .accessibilityLabel(accessibilityLabel ?? placeholder)
            .overlay(alignment: .trailing) {
                if !options.isEmpty {
                    TFMenuButton(title: menuTitle, systemImage: "chevron.up.chevron.down", kind: .plain, size: .small,
                                 iconOnly: true, actions: options.map { value in .action(value) { text = value } })
                        .padding(.trailing, 3)
                }
            }
    }
}
