import AppKit
import SwiftUI

public struct TypefluxHUD: View {
    @Environment(\.interfaceStyle) private var style
    private let message: TypefluxHUDMessage

    public init(message: TypefluxHUDMessage) {
        self.message = message
    }

    public var body: some View {
        TypefluxGlassContainer(radius: style == .classic ? .spotlightResults : .spotlightInput) {
            Label(message.title, systemImage: message.systemImage)
                .font(.body)
                .foregroundStyle(TypefluxColor.label.color)
                .padding(.horizontal, 18)
                .frame(height: style == .classic ? 44 : 40)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(message.title)
        .accessibilityIdentifier("typeflux.hud")
        .onAppear {
            NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                                 userInfo: [
                                     .announcement: message.title,
                                     .priority: NSAccessibilityPriorityLevel.medium.rawValue
                                 ])
        }
    }
}

public extension View {
    func typefluxHUD(_ state: TypefluxHUDState) -> some View {
        modifier(TypefluxHUDModifier(state: state))
    }
}

private struct TypefluxHUDModifier: ViewModifier {
    @ObservedObject var state: TypefluxHUDState

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let message = state.message {
                TypefluxHUD(message: message).padding(.bottom, 24).allowsHitTesting(false)
            }
        }
        .onDisappear { state.dismiss() }
    }
}
