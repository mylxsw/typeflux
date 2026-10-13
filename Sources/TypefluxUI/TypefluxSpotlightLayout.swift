import SwiftUI

/// Shared Spotlight surfaces. Callers retain their editor, result content and keyboard routing.
public struct TypefluxSpotlightLayout<Input: View, Modes: View, Results: View>: View {
    @Environment(\.interfaceStyle) private var style
    private let showsResults: Bool
    private let placement: GlassPlacement
    private let fillsAvailableHeight: Bool
    private let input: Input
    private let modes: Modes
    private let results: Results

    public init(showsResults: Bool = true, placement: GlassPlacement = .floating,
                fillsAvailableHeight: Bool = false,
                @ViewBuilder input: () -> Input, @ViewBuilder modes: () -> Modes,
                @ViewBuilder results: () -> Results) {
        self.showsResults = showsResults
        self.placement = placement
        self.fillsAvailableHeight = fillsAvailableHeight
        self.input = input()
        self.modes = modes()
        self.results = results()
    }

    public var body: some View {
        Group {
            if style == .classic {
                VStack(spacing: 0) {
                    HStack(alignment: .top, spacing: 8) { input; modes }
                    if showsResults {
                        Divider()
                        results
                    }
                }
                .background { surface(.spotlightResults) }
                .clipShape(RoundedRectangle(cornerRadius: TypefluxRadius.spotlightResults.value(for: style)))
            } else {
                TypefluxGlassGroup(spacing: TypefluxSpotlightMetrics.resultsSpacing(for: style)) {
                    VStack(spacing: TypefluxSpotlightMetrics.resultsSpacing(for: style)) {
                        HStack(alignment: .top, spacing: 8) {
                            input.background { surface(.spotlightInput) }
                            modes
                        }
                        if showsResults {
                            results.background { surface(.spotlightResults) }
                                .clipShape(RoundedRectangle(
                                    cornerRadius: TypefluxRadius.spotlightResults.value(for: style)
                                ))
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: fillsAvailableHeight ? .infinity : nil, alignment: .top)
    }

    /// Materials decorate the layout without reparenting its native editors or controls.
    private func surface(_ radius: TypefluxRadius) -> some View {
        TypefluxGlassContainer(radius: radius, placement: placement) { Color.clear }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
