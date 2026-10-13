import SwiftUI

/// Shared Spotlight surfaces. Callers retain their editor, result content and keyboard routing.
public struct TypefluxSpotlightLayout<Input: View, Modes: View, Results: View>: View {
    @Environment(\.interfaceStyle) private var style
    private let showsResults: Bool
    private let placement: GlassPlacement
    private let input: Input
    private let modes: Modes
    private let results: Results

    public init(showsResults: Bool = true, placement: GlassPlacement = .floating,
                @ViewBuilder input: () -> Input, @ViewBuilder modes: () -> Modes,
                @ViewBuilder results: () -> Results) {
        self.showsResults = showsResults
        self.placement = placement
        self.input = input()
        self.modes = modes()
        self.results = results()
    }

    public var body: some View {
        Group {
            if style == .classic {
                TypefluxGlassContainer(radius: .spotlightResults, placement: placement) {
                    VStack(spacing: 0) {
                        HStack(alignment: .top, spacing: 8) { input; modes }
                        if showsResults {
                            Divider()
                            results
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: TypefluxRadius.spotlightResults.value(for: style)))
            } else {
                TypefluxGlassGroup(spacing: TypefluxSpotlightMetrics.resultsSpacing(for: style)) {
                    VStack(spacing: TypefluxSpotlightMetrics.resultsSpacing(for: style)) {
                        HStack(alignment: .top, spacing: 8) {
                            TypefluxGlassContainer(radius: .spotlightInput, placement: placement) { input }
                            modes
                        }
                        if showsResults {
                            TypefluxGlassContainer(radius: .spotlightResults, placement: placement) { results }
                                .clipShape(RoundedRectangle(
                                    cornerRadius: TypefluxRadius.spotlightResults.value(for: style)
                                ))
                        }
                    }
                }
            }
        }
        .accessibilityIdentifier("typeflux.spotlight.layout")
    }
}
