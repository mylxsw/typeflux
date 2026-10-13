import SwiftUI

/// Reusable signed-out identity. Chat supplies a local-mode action; settings shows status.
struct AskSignedOutIdentity: View {
    var active = false
    var subtitle = L("ask.local.identity.storage")
    var detail: String
    let action: (() -> Void)?
    @State private var hovering = false
    @Environment(\.interfaceStyle) private var style

    var body: some View {
        if let action {
            Button(action: action) { label }
                .buttonStyle(.plain)
                .padding(.leading, -4)
                .onHover { hovering = $0 }
                .help(detail)
                .accessibilityLabel(L("ask.local.identity"))
                .accessibilityValue(detail)
                .accessibilityIdentifier("sidebar.signedOutIdentity")
        } else {
            // Status only: both lines stay readable as static text.
            label
                .padding(.leading, -4)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("sidebar.signedOutIdentity")
        }
    }

    private var label: some View {
        HStack(spacing: 9) {
            Image(systemName: "desktopcomputer").font(.body.weight(.medium))
                .foregroundStyle(TypefluxColor.label.color)
                .frame(width: 30, height: 30)
                .background(TypefluxColor.label.color.opacity(0.06),
                            in: RoundedRectangle(cornerRadius: TypefluxRadius.navigationIcon.value(for: style),
                                                 style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(L("ask.local.identity")).font(.body.weight(.semibold))
                    .foregroundStyle(TypefluxColor.label.color)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(TypefluxColor.tertiaryLabel.color)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, 4).padding(.trailing, 8)
        .frame(minHeight: 40)
        .background(RoundedRectangle(cornerRadius: TypefluxRadius.sidebarRow.value(for: style), style: .continuous)
            .fill(hovering || active ? TypefluxColor.label.color.opacity(0.06) : .clear))
        .contentShape(Rectangle())
    }
}
