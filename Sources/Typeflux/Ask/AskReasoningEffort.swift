import SwiftUI

enum AskReasoningEffort: String, CaseIterable {
    case providerDefault = ""
    case low, medium, high

    var label: String {
        L("ask.reasoning." + (self == .providerDefault ? "default" : rawValue))
    }

    /// One line under each level in the chooser, so the trade-off is visible
    /// before picking rather than only in a tooltip.
    var caption: String {
        L("ask.reasoning." + (self == .providerDefault ? "default" : rawValue) + ".caption")
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

    static func labelColor(_ effort: AskReasoningEffort) -> Color {
        effort == .high ? AskTheme.accentText : StudioTheme.textSecondary
    }

    var body: some View {
        if reference.hasPrefix("cloud:"), library.registry.resolve(reference)?.1.reasoning == true {
            Button { expanded.toggle() } label: {
                HStack(spacing: 6) {
                    // Sparkles, not a brain: the brain is the memory chip's symbol.
                    Image(systemName: "sparkles")
                    Text(effort.label)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(StudioTheme.textTertiary)
                }
                .font(.system(size: 13, weight: .medium))
                // A secondary setting stays grey until it costs more: "high" is tinted.
                .foregroundStyle(Self.labelColor(effort))
                .padding(.horizontal, compact ? AskMetrics.composerControlPadding : 11)
                .frame(height: compact ? AskMetrics.composerControlHeight : 32)
                .background(fill, in: Capsule())
                .overlay(Capsule().strokeBorder(compact ? Color.clear : ModelVisualStyle.border))
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
        VStack(alignment: .leading, spacing: 0) {
            AskPopoverHeader(title: L("ask.reasoning.title"))
            ForEach(AskReasoningEffort.allCases, id: \.self) { choice in
                AskPopoverRow(title: choice.label, caption: choice.caption, selected: effort == choice) {
                    effort = choice; dismiss()
                }
            }
        }
        .padding(.vertical, 6)
        .frame(width: 300)
        .modifier(AskPopoverSurface())
    }
}
