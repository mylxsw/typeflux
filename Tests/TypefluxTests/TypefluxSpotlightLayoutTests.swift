import AppKit
import SwiftUI
import Testing
@testable import Typeflux
@testable import TypefluxUI

@Suite("Spotlight layout and accessibility", .exclusiveUIState)
@MainActor
struct TypefluxSpotlightLayoutTests {
    @Test(arguments: InterfaceStyle.allCases)
    func collapsedAndExpandedSurfacesHaveTheSpecifiedHeight(_ style: InterfaceStyle) {
        for expanded in [false, true] {
            let inputHeight = TypefluxControlHeight.spotlightInput.value(for: style)
            let view = TypefluxSpotlightLayout(showsResults: expanded) {
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
    func accessibilityOverridesRemoveTheVisualEffect(_ style: InterfaceStyle) async throws {
        for options in [TypefluxAccessibilityOptions(reduceTransparency: true),
                        TypefluxAccessibilityOptions(increasedContrast: true)] {
            let view = TypefluxSpotlightLayout {
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
}
