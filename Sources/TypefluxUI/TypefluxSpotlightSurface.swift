import AppKit
import SwiftUI

/// Shared Spotlight chrome. Callers own result selection, keyboard routing and previews.
public struct TypefluxSpotlightSurface<Results: View, Hints: View>: View {
    @Binding private var query: String
    @Binding private var mode: String
    @Binding private var focused: Bool
    @Environment(\.interfaceStyle) private var style
    private let prompt: String
    private let inputSystemImage: String
    private let modes: [TypefluxSpotlightMode]
    private let onEscape: () -> Void
    private let results: Results
    private let hints: Hints
    private let usesSuppliedLayout: Bool
    private let placement: GlassPlacement

    public init(query: Binding<String>, mode: Binding<String>, focused: Binding<Bool>, prompt: String,
                modes: [TypefluxSpotlightMode], inputSystemImage: String = "magnifyingglass",
                onEscape: @escaping () -> Void,
                @ViewBuilder results: () -> Results,
                @ViewBuilder hints: () -> Hints) {
        _query = query
        _mode = mode
        _focused = focused
        self.prompt = prompt
        self.inputSystemImage = inputSystemImage
        self.modes = modes
        self.onEscape = onEscape
        self.results = results()
        self.hints = hints()
        usesSuppliedLayout = false
        placement = .floating
    }

    /// Decorate an existing rich editor layout without supplying frames, spacing or size proposals.
    public init(placement: GlassPlacement = .floating, @ViewBuilder content: () -> Results)
        where Hints == EmptyView {
        _query = .constant("")
        _mode = .constant("")
        _focused = .constant(false)
        prompt = ""
        inputSystemImage = "magnifyingglass"
        modes = []
        onEscape = {}
        results = content()
        hints = EmptyView()
        usesSuppliedLayout = true
        self.placement = placement
    }

    @ViewBuilder public var body: some View {
        if usesSuppliedLayout {
            results
                .background {
                    TypefluxGlassContainer(radius: .spotlightResults, placement: placement) { Color.clear }
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                .clipShape(RoundedRectangle(cornerRadius: TypefluxRadius.spotlightResults.value(for: style)))
        } else {
            nativePanel
        }
    }

    private var nativePanel: some View {
        Group {
            if style == .classic {
                TypefluxGlassContainer(radius: .spotlightResults) {
                    VStack(spacing: 0) {
                        TypefluxSpotlightHeader(focused: focused, input: { input }, modes: { modeButtons })
                            .padding(.trailing, 10)
                        Divider()
                        resultPanel
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: TypefluxRadius.spotlightResults.value(for: style)))
            } else {
                TypefluxGlassGroup(spacing: 12) {
                    VStack(spacing: 12) {
                        TypefluxSpotlightHeader(focused: focused, input: { input }, modes: { modeButtons })
                        TypefluxGlassContainer(radius: .spotlightResults) { resultPanel }
                            .clipShape(RoundedRectangle(
                                cornerRadius: TypefluxRadius.spotlightResults.value(for: style)))
                    }
                }
            }
        }
        .foregroundStyle(TypefluxColor.label.color)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("typeflux.spotlight.surface")
        // Restore focus after the native views have reconciled the new mode.
        .onChange(of: mode) { _ in focused = true }
    }

    private var input: some View {
        HStack(spacing: 8) {
            Image(systemName: inputSystemImage).foregroundStyle(TypefluxColor.secondaryLabel.color)
                .accessibilityHidden(true)
            TypefluxNativeSearchField(text: $query, focused: $focused, prompt: prompt,
                                      identifier: "typeflux.spotlight.search", borderless: true, onEscape: onEscape)
                .frame(minWidth: 0, maxWidth: .infinity)
        }
        .padding(.horizontal, 16)
        .frame(height: TypefluxControlHeight.spotlightInput.value(for: style))
    }

    private var modeButtons: some View {
        HStack(spacing: style == .classic ? 2 : 8) {
            ForEach(modes) { item in modeButton(item) }
        }
        .fixedSize()
    }

    private func modeButton(_ item: TypefluxSpotlightMode) -> some View {
        let selected = mode == item.id
        let width = style == .classic ? 30 : TypefluxControlHeight.spotlightModeButton.value(for: style)
        let height = style == .classic ? 26 : width
        return TypefluxSpotlightModeSurface(selected: selected) {
            Button {
                mode = item.id
                focused = true
            } label: {
                Label(item.title, systemImage: item.systemImage).labelStyle(.iconOnly)
                    .frame(width: width, height: height)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(width: width, height: height)
            // Keep the nonactivating panel's field editor while switching modes.
            .focusable(false)
            .help(item.title)
            .accessibilityLabel(item.title)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityIdentifier("typeflux.spotlight.mode." + item.id)
            .foregroundStyle(selected
                ? (style == .classic ? TypefluxColor.accent.color : Color(nsColor: .alternateSelectedControlTextColor))
                : TypefluxColor.secondaryLabel.color)
        }
    }

    private var resultPanel: some View {
        VStack(spacing: 0) {
            // Floating result rows are navigation. The enclosing glass container supplies the
            // opaque Classic/accessibility fallback without covering Liquid Glass with a white canvas.
            results
            Divider()
            hints
        }
    }
}
