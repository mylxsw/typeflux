import AppKit
import SwiftUI

/// Keep the explicit prominent SwiftUI style when AppKit adapts toolbar content.
/// A hosting view prevents native toolbar button extraction from discarding that style.
struct TypefluxProminentToolbarButton: NSViewRepresentable {
    let action: TypefluxToolbarAction
    @Environment(\.interfaceStyle) private var style
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.controlActiveState) private var controlActiveState
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.typefluxAccessibilityOptions) private var accessibility

    private var content: AnyView {
        AnyView(TypefluxToolbarButton(action: action, prominent: true)
            .environment(\.interfaceStyle, style)
            .environment(\.colorScheme, colorScheme)
            .environment(\.controlActiveState, controlActiveState)
            .environment(\.typefluxAccessibilityOptions, TypefluxAccessibilityOptions(
                reduceTransparency: reduceTransparency || accessibility.reduceTransparency,
                increasedContrast: contrast == .increased || accessibility.increasedContrast))
            .disabled(!isEnabled))
    }

    func makeNSView(context _: Context) -> NSHostingView<AnyView> {
        ToolbarHostingView(rootView: content)
    }

    func updateNSView(_ view: NSHostingView<AnyView>, context _: Context) { view.rootView = content }
}

private final class ToolbarHostingView: NSHostingView<AnyView> {
    override var isOpaque: Bool { false }
}
