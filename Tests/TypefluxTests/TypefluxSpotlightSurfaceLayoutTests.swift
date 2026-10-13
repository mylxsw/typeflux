import AppKit
import SwiftUI
import Testing
@testable import Typeflux
@testable import TypefluxUI

@Suite("Spotlight layout and accessibility", .exclusiveUIState)
@MainActor
struct TypefluxSpotlightSurfaceLayoutTests {
    @Test(arguments: InterfaceStyle.allCases)
    func collapsedAndExpandedSurfacesHaveTheSpecifiedHeight(_ style: InterfaceStyle) {
        for expanded in [false, true] {
            let inputHeight = TypefluxControlHeight.spotlightInput.value(for: style)
            let view = TypefluxSpotlightSurface(showsResults: expanded) {
                Text("Search").frame(maxWidth: .infinity).frame(height: inputHeight)
            } modes: {
                TypefluxSpotlightModeControl {
                    Text("Mode").frame(width: 30, height: 26)
                }
            } results: {
                Text("Results").frame(height: 120)
            }
            .environment(\.interfaceStyle, style)
            .environment(\.glassMaterialOverride, .opaque)
            .frame(width: 600)
            let host = NSHostingView(rootView: view)
            let gap = TypefluxSpotlightMetrics.resultsSpacing(for: style) + (style == .classic ? 1 : 0)
            let expected = inputHeight + (expanded ? 120 + gap : 0)
            #expect(abs(host.fittingSize.height - expected) <= 1)
        }
    }

    @Test func selectedLabelsUseTheSystemSelectionText() {
        let selected = Color(nsColor: .alternateSelectedControlTextColor)
        #expect(TypefluxSpotlightRow.labelColor(selected: true) == selected)
        #expect(TypefluxSpotlightRow.labelColor(selected: true, secondary: true) == selected)
        #expect(TypefluxSpotlightRow.labelColor(selected: false) == TypefluxColor.label.color)
        #expect(TypefluxSpotlightRow.labelColor(selected: false, secondary: true) == TypefluxColor.secondaryLabel.color)
    }

    @Test(arguments: InterfaceStyle.allCases)
    func inputStaysAtTheTopWhileResultsAppearAndDisappear(_ style: InterfaceStyle) async throws {
        let state = ResultState()
        let view = ChangingResults(state: state)
            .environment(\.interfaceStyle, style)
            .environment(\.glassMaterialOverride, .opaque)
        try await TypefluxNavigationTestSupport.withWindow(view) { window, host in
            let field = try #require(TypefluxNavigationTestSupport.searchField(in: host))
            func topInset() -> CGFloat {
                let frame = window.convertToScreen(field.convert(field.bounds, to: nil))
                return window.frame.maxY - frame.maxY
            }
            let anchor = topInset()
            for height: CGFloat in [0, 80, 260, 0, 120] {
                state.height = height
                try await Task.sleep(for: .milliseconds(80))
                host.layoutSubtreeIfNeeded()
                #expect(abs(topInset() - anchor) < 0.5)
                #expect(TypefluxNavigationTestSupport.searchField(in: host) === field,
                        "Changing results must keep the existing native input")
            }
        }
    }

    @Test(arguments: InterfaceStyle.allCases)
    func accessibilityOverridesRemoveTheVisualEffect(_ style: InterfaceStyle) async throws {
        for options in [TypefluxAccessibilityOptions(reduceTransparency: true),
                        TypefluxAccessibilityOptions(increasedContrast: true)] {
            let view = TypefluxSpotlightSurface {
                Text("Search").frame(height: 56)
            } modes: {
                TypefluxSpotlightModeControl { Text("Mode") }
            } results: {
                Text("Results").frame(height: 100)
            }
            .environment(\.interfaceStyle, style)
            .environment(\.glassMaterialOverride, .visualEffect)
            .environment(\.typefluxAccessibilityOptions, options)
            try await TypefluxNavigationTestSupport.withWindow(view) { _, host in
                #expect(!descendants(host).contains { $0 is NSVisualEffectView })
            }
        }
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    @MainActor private final class ResultState: ObservableObject {
        @Published var height: CGFloat = 120
    }

    private struct ChangingResults: View {
        @ObservedObject var state: ResultState
        @Environment(\.interfaceStyle) private var style

        var body: some View {
            TypefluxSpotlightSurface(showsResults: state.height > 0, fillsAvailableHeight: true) {
                TypefluxNativeSearchField(text: .constant(""), focused: .constant(false), prompt: "Search",
                                          identifier: "spotlight.test.input")
                    .frame(height: TypefluxControlHeight.spotlightInput.value(for: style))
            } modes: {
                EmptyView()
            } results: {
                Text("Results").frame(height: state.height)
            }
        }
    }
}
