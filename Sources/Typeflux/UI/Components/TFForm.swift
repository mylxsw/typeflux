import SwiftUI

/// How wide a form row's control column is.
enum TFFormControlWidth: Equatable {
    /// The control keeps its own size (switches, buttons, pickers with their own width).
    case fit
    /// 220pt: equal-width segmented controls and pickers that should line up.
    case standard
    /// 280pt: long values such as URLs or model names.
    case wide

    var width: CGFloat? {
        switch self {
        case .fit: nil
        case .standard: TFMetrics.formControlWidth
        case .wide: TFMetrics.formControlWideWidth
        }
    }
}

/// A form row with a description hint beside its title and a control on the right.
/// When the row is too narrow the control moves below the text.
struct TFFormRow<Control: View>: View {
    let title: String
    var detail: String?
    /// Current values and status remain visible instead of moving into the description hint.
    var valueText: String?
    /// A third, quieter line for technical detail.
    var footnote: String?
    var badge: String?
    /// Colors the badge (e.g. success / warning); nil is the neutral tag.
    var badgeTint: Color?
    /// A status symbol before the title.
    var systemImage: String?
    var imageTint: Color = TFColors.textSecondary
    var controlWidth: TFFormControlWidth = .fit
    @ViewBuilder var control: Control
    @State private var isHovering = false

    /// The text column never asks for more than this before wrapping, so short controls stay beside it.
    static var labelIdealWidth: CGFloat { 220 }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 16) {
                labels.frame(minWidth: 180, idealWidth: Self.labelIdealWidth, maxWidth: .infinity, alignment: .leading)
                sizedControl.fixedSize()
            }
            VStack(alignment: .leading, spacing: 10) {
                labels.frame(maxWidth: .infinity, alignment: .leading)
                sizedControl
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minHeight: TFMetrics.formRowMinHeight)
        .tfControlSize(.regular)
        .accessibilityElement(children: .contain)
        .onHover { isHovering = $0 }
    }

    private var sizedControl: some View {
        HStack(spacing: TFMetrics.toolbarSpacing) { control }
            .frame(width: controlWidth.width, alignment: .trailing)
    }

    private var labels: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 13, weight: .semibold)).foregroundStyle(imageTint)
                        .accessibilityHidden(true)
                }
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(TFColors.textPrimary)
                    .accessibilityHint(detail ?? "")
                if let detail, !detail.isEmpty {
                    SettingsDescriptionHint(detail: detail, visible: isHovering)
                }
                if let badge { TFTag(text: badge, tint: badgeTint) }
            }
            if let valueText, !valueText.isEmpty {
                Text(valueText).font(.system(size: 12)).foregroundStyle(TFColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let footnote, !footnote.isEmpty {
                Text(footnote).font(.system(size: 11)).foregroundStyle(TFColors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A native tooltip target that only appears while its settings row is hovered.
struct SettingsDescriptionHint: View {
    let detail: String
    let visible: Bool

    var body: some View {
        Image(systemName: "questionmark.circle")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(TFColors.textSecondary)
            .frame(width: 16, height: 16)
            .contentShape(Rectangle())
            .opacity(visible ? 1 : 0)
            .help(detail)
            .accessibilityHidden(true)
    }
}

/// A titled group of form rows: a section header and a card. Separate rows with `TFDivider.form`.
struct TFFormSection<Actions: View, Content: View>: View {
    var title: String?
    var count: Int?
    @ViewBuilder var actions: Actions
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                TFSectionHeader(title: title, count: count) { actions }
            }
            TFCard { content }
        }
    }
}

extension TFFormSection where Actions == EmptyView {
    init(title: String? = nil, count: Int? = nil, @ViewBuilder content: () -> Content) {
        self.init(title: title, count: count, actions: { EmptyView() }, content: content)
    }
}

/// A large selectable card with a preview, for choices that are easier to show than to name
/// (e.g. window layouts). Selected cards use the selection fill and a 2pt accent outline.
struct TFChoiceCard<Preview: View>: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    @ViewBuilder var preview: Preview

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: TFMetrics.cardCornerRadius, style: .continuous)
        Button(action: action) {
            VStack(spacing: 10) {
                preview
                HStack(spacing: 6) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected ? TFColors.accent : TFColors.textTertiary)
                    Text(title).foregroundStyle(TFColors.textPrimary).fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: 13, weight: .medium))
            }
            .padding(12)
            .frame(maxWidth: .infinity)
            .background(isSelected ? TFColors.selection : TFColors.card, in: shape)
            .overlay { shape.strokeBorder(isSelected ? TFColors.accent : TFColors.border, lineWidth: isSelected ? 2 : 1) }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityLabel(title)
        // Ignoring the children drops the button's own press action; restore it for VoiceOver.
        .accessibilityAction { action() }
    }
}

/// A mini switch, the size used in rows and forms.
struct TFSwitch: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(title, isOn: $isOn)
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()
    }
}

/// Spec §6: 30pt, 8pt corners, the shared fill and focus ring. Keys, URLs and model IDs
/// are monospaced. An error outlines the field in red; pair it with `TFFieldMessage`.
struct TFTextFieldStyle: TextFieldStyle {
    var monospaced = false
    var isError = false
    @FocusState private var focused: Bool

    // TextFieldStyle requires this underscored protocol method.
    // swiftlint:disable:next identifier_name
    func _body(configuration: TextField<Self._Label>) -> some View {
        let shape = RoundedRectangle(cornerRadius: TFMetrics.fieldCornerRadius, style: .continuous)
        return configuration
            .textFieldStyle(.plain)
            .font(.system(size: monospaced ? 12 : 13, design: monospaced ? .monospaced : .default))
            .focused($focused)
            .padding(.horizontal, 10)
            .frame(height: TFControlSize.regular.height)
            .background(shape.fill(TFColors.control))
            .overlay {
                shape.strokeBorder(isError ? TFColors.danger : (focused ? TFColors.accent : TFColors.border),
                                   lineWidth: isError || focused ? 1 : TFMetrics.borderWidth)
            }
            .background {
                if focused {
                    shape.inset(by: -TFMetrics.focusRingWidth / 2)
                        .stroke(isError ? TFColors.danger.opacity(0.25) : TFColors.focusRing,
                                lineWidth: TFMetrics.focusRingWidth)
                }
            }
    }
}

/// A one-line message under a field; red for errors.
struct TFFieldMessage: View {
    let text: String
    var isError = true

    var body: some View {
        Text(text).font(.system(size: 11.5)).foregroundStyle(isError ? TFColors.danger : TFColors.textSecondary)
    }
}
