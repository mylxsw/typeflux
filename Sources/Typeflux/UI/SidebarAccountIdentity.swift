import SwiftUI

/// Chat's optional local-mode action beside the account row.
struct AskSignedOutIdentity: View {
    var active = false
    var compact = false
    var subtitle = L("ask.local.identity.storage")
    var detail: String
    let action: (() -> Void)?
    @State private var hovering = false

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

    @ViewBuilder private var label: some View {
        if compact {
            Label(L("ask.local.identity"), systemImage: "desktopcomputer").labelStyle(.iconOnly)
                .font(.body).frame(width: 28, height: 28).contentShape(Rectangle())
        } else {
            fullLabel
        }
    }

    private var fullLabel: some View {
        HStack(spacing: 9) {
            Image(systemName: "desktopcomputer").font(.system(size: 13, weight: .medium))
                .foregroundStyle(TypefluxColor.label.color)
                .frame(width: 30, height: 30)
                .background(TypefluxColor.label.color.opacity(0.06),
                            in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(L("ask.local.identity")).font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(TypefluxColor.label.color)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(TypefluxColor.tertiaryLabel.color)
                    .lineLimit(1).minimumScaleFactor(0.85)
            }
        }
        .padding(.leading, 4).padding(.trailing, 8)
        .frame(height: 40)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous)
            .fill(hovering || active ? TypefluxColor.label.color.opacity(0.06) : .clear))
        .contentShape(Rectangle())
    }
}
