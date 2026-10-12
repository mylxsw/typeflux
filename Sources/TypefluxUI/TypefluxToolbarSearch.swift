import SwiftUI

/// Precise circle-to-capsule search for custom navigation surfaces. Window templates
/// use the native `.searchable` adapter, whose toolbar item owns the system morph.
public struct TypefluxToolbarSearch: View {
    @ObservedObject private var state: TypefluxSearchState
    @Environment(\.interfaceStyle) private var style
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.glassMaterialOverride) private var materialOverride
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.typefluxAccessibilityOptions) private var accessibility
    @Namespace private var morph
    private let prompt: String

    public init(state: TypefluxSearchState, prompt: String) {
        self.state = state
        self.prompt = prompt
    }

    public var body: some View {
        TypefluxGlassGroup {
            morphingSurface
        }
        .frame(width: state.isExpanded ? TypefluxControlWidth.toolbarSearch.value(for: style)
            : TypefluxControlWidth.toolbarItem.value(for: style),
            height: TypefluxControlHeight.toolbarSearch.value(for: style))
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.8), value: state.isExpanded)
        .background(TypefluxKeyboardMonitor { event in
            guard isEnabled, event.modifierFlags.intersection([.command, .option, .control, .shift]) == .command,
                  event.charactersIgnoringModifiers?.lowercased() == "f" else { return false }
            state.expand()
            return true
        }.frame(width: 0, height: 0))
    }

    @ViewBuilder private var morphingSurface: some View {
        #if compiler(>=6.2)
            if #available(macOS 26.0, *), style.usesGlass, !reduceTransparency,
               contrast != .increased, materialOverride != .opaque,
               !accessibility.reduceTransparency, !accessibility.increasedContrast {
                if state.isExpanded {
                    field.glassEffect(.regular, in: Capsule()).glassEffectID("search", in: morph)
                } else {
                    magnifier.glassEffect(.regular.interactive(), in: Circle()).glassEffectID("search", in: morph)
                }
            } else {
                fallback
            }
        #else
            fallback
        #endif
    }

    @ViewBuilder private var fallback: some View {
        if state.isExpanded {
            field.background(TypefluxColor.controlBackground.color,
                             in: RoundedRectangle(cornerRadius: TypefluxRadius.toolbarSearch.value(for: style)))
        } else {
            magnifier
        }
    }

    private var field: some View {
        HStack(spacing: 6) {
            if style.usesGlass {
                Image(systemName: "magnifyingglass").foregroundStyle(TypefluxColor.secondaryLabel.color)
                    .accessibilityHidden(true)
            }
            TypefluxNativeSearchField(text: $state.query,
                                      focused: Binding(get: { state.isFocused }, set: { state.focusChanged($0) }),
                                      prompt: prompt, identifier: "typeflux.toolbar-search",
                                      borderless: style.usesGlass,
                                      onEscape: { state.escape() })
        }
        .padding(.horizontal, style.usesGlass ? 10 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var magnifier: some View {
        Button(action: state.expand) { Label(prompt, systemImage: "magnifyingglass").labelStyle(.iconOnly) }
            .buttonStyle(.borderless)
            .help(prompt + " (⌘F)")
            .accessibilityLabel(prompt)
            .accessibilityIdentifier("typeflux.toolbar-search.expand")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
