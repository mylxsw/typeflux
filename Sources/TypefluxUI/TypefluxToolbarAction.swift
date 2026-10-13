import SwiftUI

public struct TypefluxToolbarAction: Identifiable {
    public let id: String
    public let title: String
    public let systemImage: String
    public let role: ButtonRole?
    public let isEnabled: Bool
    public let accessibilityIdentifier: String
    public let shortcut: KeyEquivalent?
    public let modifiers: EventModifiers
    /// When present without menu actions, the control is a native ShareLink.
    public let sharingText: String?
    public let menuActions: [TypefluxToolbarAction]
    public let perform: () -> Void

    public var keyboardShortcut: KeyboardShortcut? {
        shortcut.map { KeyboardShortcut($0, modifiers: modifiers) }
    }

    public init(id: String, title: String, systemImage: String, role: ButtonRole? = nil,
                isEnabled: Bool = true, accessibilityIdentifier: String? = nil,
                shortcut: KeyEquivalent? = nil, modifiers: EventModifiers = .command,
                sharingText: String? = nil, menuActions: [TypefluxToolbarAction] = [],
                perform: @escaping () -> Void) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.role = role
        self.isEnabled = isEnabled
        self.accessibilityIdentifier = accessibilityIdentifier ?? "typeflux.toolbar." + id
        self.shortcut = shortcut
        self.modifiers = modifiers
        self.sharingText = sharingText
        self.menuActions = menuActions
        self.perform = perform
    }
}
