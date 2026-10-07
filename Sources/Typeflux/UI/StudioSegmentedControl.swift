import SwiftUI

/// Shared tabs and inline choices across settings, with optional counts and stable accessibility IDs.
struct StudioSegmentedControl<Value: Hashable>: View {
    enum Size {
        case regular, compact

        var itemHeight: CGFloat {
            self == .regular ? 26 : 22
        }

        var horizontalPadding: CGFloat {
            self == .regular ? 16 : 10
        }

        var fontSize: CGFloat {
            self == .regular ? 12.5 : 12
        }
    }

    let options: [(label: String, value: Value)]
    @Binding var selection: Value
    var size: Size = .regular
    var counts: [Value: Int] = [:]
    var optionIdentifier: ((Value) -> String)?

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                let selected = selection == option.value
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { selection = option.value }
                } label: {
                    HStack(spacing: 4) {
                        Text(option.label)
                            .foregroundStyle(selected ? StudioTheme.textPrimary : StudioTheme.textSecondary)
                        if let count = counts[option.value] {
                            Text("\(count)").foregroundStyle(StudioTheme.textTertiary)
                        }
                    }
                    .font(.system(size: size.fontSize, weight: .semibold))
                    .lineLimit(1)
                    .padding(.horizontal, size.horizontalPadding).frame(height: size.itemHeight)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(selected ? StudioTheme.selectionSurfaceRaised : Color.clear)
                            .shadow(color: .black.opacity(selected ? 0.18 : 0), radius: 1, y: 1)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityIdentifier(optionIdentifier?(option.value) ?? option.label)
            }
        }
        .padding(2)
        .background(StudioTheme.controlSurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(StudioTheme.border))
        .fixedSize()
    }
}

typealias ModelSegmentedControl<Value: Hashable> = StudioSegmentedControl<Value>
typealias StudioSegmentedPicker<Value: Hashable> = StudioSegmentedControl<Value>
