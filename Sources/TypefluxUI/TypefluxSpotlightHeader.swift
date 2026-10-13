import SwiftUI

/// A rich editor can share the clipboard's capsule and independent mode surfaces.
public struct TypefluxSpotlightHeader<Input: View, Modes: View>: View {
    @Environment(\.interfaceStyle) private var style
    private let input: Input
    private let modes: Modes
    private let focused: Bool

    public init(focused: Bool = false, @ViewBuilder input: () -> Input, @ViewBuilder modes: () -> Modes) {
        self.focused = focused
        self.input = input()
        self.modes = modes()
    }

    public var body: some View {
        TypefluxSpotlightHeaderLayout(spacing: TypefluxSpacing.small.value(for: style),
                                      minimumHeight: TypefluxControlHeight.spotlightInput.value(for: style)) {
            if style == .classic {
                input.frame(minWidth: 0, maxWidth: .infinity).clipped()
            } else {
                TypefluxGlassContainer(radius: .spotlightInput) {
                    input.frame(minWidth: 0, maxWidth: .infinity)
                }
                .clipShape(RoundedRectangle(cornerRadius: TypefluxRadius.spotlightInput.value(for: style),
                                            style: .circular))
                .overlay {
                    if focused {
                        RoundedRectangle(cornerRadius: TypefluxRadius.spotlightInput.value(for: style),
                                         style: .circular)
                            .strokeBorder(TypefluxColor.accent.color, lineWidth: 1)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
            }
            modes.fixedSize(horizontal: true, vertical: true)
        }
        .accessibilityElement(children: .contain)
    }
}

/// Reserve the modes first; the native editor receives only the remaining finite width.
private struct TypefluxSpotlightHeaderLayout: Layout {
    let spacing: CGFloat
    let minimumHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        let modes = subviews[1].sizeThatFits(.unspecified)
        let gap = modes.width > 0 ? spacing : 0
        let idealInput = subviews[0].sizeThatFits(.unspecified).width
        let naturalWidth = max(160, idealInput.isFinite ? idealInput : 160) + gap + modes.width
        let width = proposal.width.flatMap { $0.isFinite ? max(0, $0) : nil } ?? naturalWidth
        let input = subviews[0].sizeThatFits(ProposedViewSize(width: max(0, width - modes.width - gap), height: nil))
        return CGSize(width: width, height: max(minimumHeight, max(input.height, modes.height)))
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        guard subviews.count == 2 else { return }
        let modes = subviews[1].sizeThatFits(.unspecified)
        let gap = modes.width > 0 ? spacing : 0
        let inputWidth = max(0, bounds.width - modes.width - gap)
        subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading,
                          proposal: ProposedViewSize(width: inputWidth, height: bounds.height))
        subviews[1].place(at: CGPoint(x: bounds.maxX, y: bounds.midY), anchor: .trailing,
                          proposal: ProposedViewSize(width: modes.width, height: modes.height))
    }
}
