import AppKit
import SwiftUI
import Testing
@testable import Typeflux
@testable import TypefluxUI

@Suite("Spotlight layout and accessibility", .exclusiveUIState)
@MainActor
struct TypefluxSpotlightSurfaceLayoutTests {
    @Test(arguments: InterfaceStyle.allCases)
    func decorationPreservesTheSuppliedContentSize(_ style: InterfaceStyle) {
        for editor: CGFloat in [32, 58, 148] {
            for results: CGFloat in [0, 120, 300] {
                let content = VStack(spacing: 0) {
                    Text("Search").frame(height: editor).padding(.vertical, 12)
                    Color.clear.frame(height: results)
                    Text("Hints").frame(height: 48)
                }
                .frame(width: 600)
                let plain = NSHostingView(rootView: content.environment(\.interfaceStyle, style))
                let surface = NSHostingView(rootView: TypefluxSpotlightSurface { content }
                    .environment(\.interfaceStyle, style)
                    .environment(\.glassMaterialOverride, .opaque))
                #expect(abs(surface.fittingSize.width - plain.fittingSize.width) < 0.5)
                #expect(abs(surface.fittingSize.height - plain.fittingSize.height) < 0.5)
            }
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
    func decorationPreservesNativeEditorFramesWhileContentAndWindowResize(_ style: InterfaceStyle) async throws {
        let state = LayoutState()
        let view = HStack(spacing: 0) {
            ComposerContent(state: state, context: "baseline")
            TypefluxSpotlightSurface { ComposerContent(state: state, context: "surface") }
        }
        .environment(\.interfaceStyle, style)
        .environment(\.glassMaterialOverride, .opaque)
        try await TypefluxNavigationTestSupport.withWindow(view, nonactivating: true) { window, host in
            @MainActor func editor(_ context: String) throws -> AskComposerTextView.Editor {
                try #require(TypefluxNavigationTestSupport.descendants(of: host)
                    .compactMap { $0 as? AskComposerTextView.Editor }.first { $0.contextID == context })
            }
            let baseline = try editor("baseline")
            let decorated = try editor("surface")
            let plainScroll = try #require(baseline.enclosingScrollView)
            let surfaceScroll = try #require(decorated.enclosingScrollView)
            for (editorHeight, resultsHeight): (CGFloat, CGFloat) in [
                (32, 0), (32, 300), (58, 300), (148, 300), (32, 0), (32, 120)
            ] {
                state.editorHeight = editorHeight
                state.resultsHeight = resultsHeight
                let windowHeight = editorHeight + resultsHeight + 108
                var frame = window.frame
                frame.origin.y = frame.maxY - windowHeight
                frame.size.height = windowHeight
                window.setFrame(frame, display: false)
                try await Task.sleep(for: .milliseconds(80))
                host.layoutSubtreeIfNeeded()
                let plainFrame = plainScroll.convert(plainScroll.bounds, to: nil)
                let surfaceFrame = surfaceScroll.convert(surfaceScroll.bounds, to: nil)
                #expect(abs(surfaceFrame.maxY - plainFrame.maxY) < 0.5)
                #expect(abs(surfaceFrame.height - plainFrame.height) < 0.5)
                #expect(try editor("baseline") === baseline)
                #expect(try editor("surface") === decorated)
            }
        }
    }

    @Test(arguments: InterfaceStyle.allCases)
    func accessibilityOverridesRemoveTheVisualEffect(_ style: InterfaceStyle) async throws {
        for options in [TypefluxAccessibilityOptions(reduceTransparency: true),
                        TypefluxAccessibilityOptions(increasedContrast: true)] {
            let view = TypefluxSpotlightSurface {
                Text("Search").frame(height: 58)
            }
            .environment(\.interfaceStyle, style)
            .environment(\.glassMaterialOverride, .visualEffect)
            .environment(\.typefluxAccessibilityOptions, options)
            try await TypefluxNavigationTestSupport.withWindow(view, nonactivating: true) { _, host in
                #expect(!TypefluxNavigationTestSupport.descendants(of: host).contains { $0 is NSVisualEffectView })
            }
        }
    }

    @MainActor private final class LayoutState: ObservableObject {
        @Published var editorHeight: CGFloat = 32
        @Published var resultsHeight: CGFloat = 0
    }

    private struct ComposerContent: View {
        @ObservedObject var state: LayoutState
        let context: String

        var body: some View {
            VStack(spacing: 0) {
                AskComposerTextView(text: .constant("Question"), placeholder: "Search", contextID: context,
                                    onSubmit: {})
                    .frame(height: state.editorHeight)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)
                Color.clear.frame(height: state.resultsHeight)
                Text("Hints").frame(height: 48)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }
}
