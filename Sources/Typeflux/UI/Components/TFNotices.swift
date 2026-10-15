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
