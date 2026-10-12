import SwiftUI

/// Groups related custom navigation surfaces so the system can merge and morph their glass.
public struct TypefluxGlassGroup<Content: View>: View {
    @Environment(\.interfaceStyle) private var style
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.typefluxAccessibilityOptions) private var accessibility
    private let spacing: CGFloat
    private let content: Content

    public init(spacing: CGFloat = 8, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    public var body: some View {
        #if compiler(>=6.2)
            if #available(macOS 26.0, *), style.usesGlass, !reduceTransparency, contrast != .increased,
               !accessibility.reduceTransparency, !accessibility.increasedContrast {
                GlassEffectContainer(spacing: spacing) { content }
            } else {
                content
            }
        #else
            content
        #endif
    }
}
