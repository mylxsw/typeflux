import SwiftUI

enum AskReasoningEffort: String, CaseIterable {
    case providerDefault = ""
    case low, medium, high

    var label: String {
        L("ask.reasoning." + (self == .providerDefault ? "default" : rawValue))
    }

    func requestValue(for model: RegisteredModel?) -> String? {
        guard model?.reference.hasPrefix("cloud:") == true, model?.reasoning == true,
              self != .providerDefault else { return nil }
        return rawValue
    }
}

struct AskReasoningMenu: View {
    @ObservedObject var library: AskModelLibrary
    var reference: String
    @Binding var effort: AskReasoningEffort
    var disabled = false
    /// Matches `AskModelMenu.compact`: borderless inside the composer footer.
    var compact = false

    @State private var expanded = false
    @State private var hovering = false

    private var fill: Color {
        guard compact else { return ModelVisualStyle.input }
        return hovering || expanded ? AskTheme.hoverFill : .clear
    }

    var body: some View {
        if reference.hasPrefix("cloud:"), library.registry.resolve(reference)?.1.reasoning == true {
            Button { expanded.toggle() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "brain").foregroundStyle(StudioTheme.textSecondary)
                    Text(effort.label)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(StudioTheme.textSecondary)
                }
                .font(.system(size: compact ? 12.5 : 13, weight: .medium))
                .padding(.horizontal, compact ? 9 : 11).frame(height: compact ? 28 : 32)
                .background(fill, in: RoundedRectangle(cornerRadius: compact ? 8 : 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: compact ? 8 : 16, style: .continuous)
                    .strokeBorder(compact ? Color.clear : ModelVisualStyle.border))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .fixedSize()
            .disabled(disabled)
            .help(L("ask.reasoning.help"))
            .accessibilityLabel(L("ask.reasoning.title"))
            .accessibilityValue(effort.label)
            .popover(isPresented: $expanded, arrowEdge: .bottom) {
                AskReasoningChoices(effort: $effort) { expanded = false }
            }
        }
    }
}

struct AskReasoningChoices: View {
    @Binding var effort: AskReasoningEffort
    var dismiss: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L("ask.reasoning.title"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(StudioTheme.textSecondary)
                .padding(.horizontal, 12).padding(.vertical, 8)
            ForEach(AskReasoningEffort.allCases, id: \.self) { choice in
                Button { effort = choice; dismiss() } label: {
                    HStack {
                        Text(choice.label)
                        Spacer()
                        if effort == choice {
                            Image(systemName: "checkmark").font(.system(size: 12, weight: .semibold))
                        }
                    }
                    .font(.system(size: 13, weight: effort == choice ? .semibold : .regular))
                    .foregroundStyle(effort == choice ? ModelVisualStyle.accent : StudioTheme.textPrimary)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(effort == choice ? ModelVisualStyle.accent.opacity(0.15) : .clear,
                                in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(effort == choice ? [.isSelected] : [])
            }
        }
        .padding(8).frame(width: 200).background(ModelVisualStyle.input)
    }
}
