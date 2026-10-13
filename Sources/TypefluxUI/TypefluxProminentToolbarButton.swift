import AppKit
import SwiftUI

/// Keep native button styling inside its own host: toolbar adaptation otherwise replaces it with a grey item.
struct TypefluxProminentToolbarButton: NSViewRepresentable {
    let action: TypefluxToolbarAction
    let style: InterfaceStyle
    let usesGlass: Bool

    private struct Content: View {
        let action: TypefluxToolbarAction
        let style: InterfaceStyle
        let usesGlass: Bool

        var body: some View {
            styledControl
                .tint(TypefluxColor.accent.color)
                .frame(width: TypefluxControlWidth.toolbarItem.value(for: style),
                       height: TypefluxControlHeight.toolbarItem.value(for: style))
        }

        @ViewBuilder private var styledControl: some View {
            #if compiler(>=6.2)
                if #available(macOS 26, *), usesGlass {
                    TypefluxToolbarActionControl(action: action)
                        .buttonStyle(.glassProminent).buttonBorderShape(.circle).controlSize(.large)
                } else {
                    opaqueControl
                }
            #else
                opaqueControl
            #endif
        }

        private var opaqueControl: some View {
            TypefluxToolbarActionControl(action: action).buttonStyle(.borderedProminent).controlSize(.regular)
        }
    }

    func makeNSView(context: Context) -> NSHostingView<AnyView> {
        let host = NSHostingView(rootView: content(environment: context.environment))
        host.sizingOptions = [.intrinsicContentSize]
        return host
    }

    func updateNSView(_ host: NSHostingView<AnyView>, context: Context) {
        host.rootView = content(environment: context.environment)
    }

    private func content(environment: EnvironmentValues) -> AnyView {
        AnyView(Content(action: action, style: style, usesGlass: usesGlass)
            .environment(\.colorScheme, environment.colorScheme)
            .disabled(!environment.isEnabled))
    }

    static func dismantleNSView(_ host: NSHostingView<AnyView>, coordinator _: ()) {
        // A closed window can remain in NSApp.windows; release its captured actions promptly.
        host.rootView = AnyView(EmptyView())
    }
}
