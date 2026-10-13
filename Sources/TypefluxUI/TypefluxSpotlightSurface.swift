import AppKit
import SwiftUI

/// Shared Spotlight chrome. Callers own result selection, keyboard routing and previews.
public struct TypefluxSpotlightSurface<Results: View, Hints: View>: View {
    @Binding private var query: String
    @Binding private var mode: String
    @Binding private var focused: Bool
    @Environment(\.interfaceStyle) private var style
    private let prompt: String
    private let modes: [TypefluxSpotlightMode]
    private let onEscape: () -> Void
    private let results: Results
    private let hints: Hints
    private let customInput: AnyView?
    private let customModes: AnyView?
    private let showsResults: Bool
    private let fillsAvailableHeight: Bool
    private let placement: GlassPlacement

    public init(query: Binding<String>, mode: Binding<String>, focused: Binding<Bool>, prompt: String,
                modes: [TypefluxSpotlightMode], onEscape: @escaping () -> Void,
                @ViewBuilder results: () -> Results,
                @ViewBuilder hints: () -> Hints) {
        _query = query
        _mode = mode
        _focused = focused
        self.prompt = prompt
        self.modes = modes
        self.onEscape = onEscape
        self.results = results()
        self.hints = hints()
        customInput = nil
        customModes = nil
        showsResults = true
        fillsAvailableHeight = false
        placement = .floating
    }

    /// Rich composers retain their editor, action controls and result/footer routing on the same shared surface.
    public init<Input: View, Modes: View>(showsResults: Bool = true, placement: GlassPlacement = .floating,
                                          fillsAvailableHeight: Bool = false,
                                          @ViewBuilder input: () -> Input, @ViewBuilder modes: () -> Modes,
                                          @ViewBuilder results: () -> Results) where Hints == EmptyView {
        _query = .constant("")
        _mode = .constant("")
        _focused = .constant(false)
        prompt = ""
        self.modes = []
        onEscape = {}
        customInput = AnyView(input())
        customModes = AnyView(modes())
        self.results = results()
        hints = EmptyView()
        self.showsResults = showsResults
        self.fillsAvailableHeight = fillsAvailableHeight
        self.placement = placement
    }

    private var usesCustomChrome: Bool { customInput != nil }

    @ViewBuilder public var body: some View {
        if usesCustomChrome {
            customPanel
                .foregroundStyle(TypefluxColor.label.color)
                .frame(maxWidth: .infinity, maxHeight: fillsAvailableHeight ? .infinity : nil, alignment: .top)
        } else {
            nativePanel
        }
    }

    // Keep the accepted native search hierarchy: its field editor and focus callbacks depend on it.
    private var nativePanel: some View {
        Group {
            if style == .classic {
                TypefluxGlassContainer(radius: .spotlightResults) {
                    VStack(spacing: 0) {
                        HStack(spacing: 8) { input; modeButtons }.padding(.trailing, 10)
                        Divider()
                        resultPanel
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: TypefluxRadius.spotlightResults.value(for: style)))
            } else {
                TypefluxGlassGroup(spacing: 12) {
                    VStack(spacing: 12) {
                        HStack(spacing: 8) {
                            TypefluxGlassContainer(radius: .spotlightInput) { input }
                            modeButtons
                        }
                        TypefluxGlassContainer(radius: .spotlightResults) { resultPanel }
                            .clipShape(RoundedRectangle(
                                cornerRadius: TypefluxRadius.spotlightResults.value(for: style)))
                    }
                }
            }
        }
        .foregroundStyle(TypefluxColor.label.color)
        .accessibilityIdentifier("typeflux.spotlight.surface")
        // Restore focus after the native views have reconciled the new mode.
        .onChange(of: mode) { _ in focused = true }
    }

    @ViewBuilder private var customPanel: some View {
        if style == .classic {
            TypefluxSpotlightContentPlacement(spacing: 0, fillsAvailableHeight: fillsAvailableHeight) {
                customHeader
                if showsResults {
                    VStack(spacing: 0) {
                        Divider()
                        results
                    }
                }
            }
            .background { surface(.spotlightResults) }
            .clipShape(RoundedRectangle(cornerRadius: TypefluxRadius.spotlightResults.value(for: style)))
        } else {
            TypefluxGlassGroup(spacing: TypefluxSpotlightMetrics.resultsSpacing(for: style)) {
                TypefluxSpotlightContentPlacement(spacing: TypefluxSpotlightMetrics.resultsSpacing(for: style),
                                                   fillsAvailableHeight: fillsAvailableHeight) {
                    customHeader
                    if showsResults {
                        results.background { surface(.spotlightResults) }
                            .clipShape(RoundedRectangle(
                                cornerRadius: TypefluxRadius.spotlightResults.value(for: style)))
                    }
                }
            }
        }
    }

    private var customHeader: some View {
        HStack(alignment: .top, spacing: 8) {
            customInput.background { if style.usesGlass { surface(.spotlightInput) } }
            customModes
        }
        // Result updates can temporarily exceed the viewport before the native panel grows.
        // Reserve the editor's full height; only the results may yield to a smaller proposal.
        .fixedSize(horizontal: false, vertical: true)
        .layoutPriority(1)
    }

    /// Rich editors stay outside the material's hosting hierarchy during a resize.
    private func surface(_ radius: TypefluxRadius) -> some View {
        TypefluxGlassContainer(radius: radius, placement: placement) { Color.clear }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private var input: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(TypefluxColor.secondaryLabel.color)
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

    @ViewBuilder private func modeButton(_ item: TypefluxSpotlightMode) -> some View {
        let selected = mode == item.id
        let button = Button {
            mode = item.id
            focused = true
        } label: {
            Label(item.title, systemImage: item.systemImage).labelStyle(.iconOnly)
                .frame(width: style == .classic ? 30 : TypefluxControlHeight.spotlightModeButton.value(for: style),
                       height: style == .classic ? 26 : TypefluxControlHeight.spotlightModeButton.value(for: style))
        }
        .buttonStyle(.borderless)
        // Keep the nonactivating panel's field editor while switching modes.
        .focusable(false)
        .help(item.title)
        .accessibilityLabel(item.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("typeflux.spotlight.mode." + item.id)
        .foregroundStyle(selected
            ? (style == .classic ? TypefluxColor.accent.color : Color(nsColor: .alternateSelectedControlTextColor))
            : TypefluxColor.secondaryLabel.color)
        .background {
            if selected {
                if style == .classic {
                    RoundedRectangle(cornerRadius: TypefluxRadius.button.value(for: style))
                        .fill(TypefluxColor.accent.color.opacity(0.15))
                } else {
                    Circle().fill(TypefluxColor.accent.color)
                }
            }
        }
        if style == .classic {
            button
        } else {
            TypefluxGlassContainer(radius: .spotlightInput) { button }
        }
    }

    private var resultPanel: some View {
        VStack(spacing: 0) {
            // Result content is always solid; glass belongs to the panel's navigation chrome.
            results.background(TypefluxColor.contentBackground.color)
            Divider()
            hints
        }
    }
}
