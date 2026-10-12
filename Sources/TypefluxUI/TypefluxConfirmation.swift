import SwiftUI

/// Native alerts and confirmation dialogs own their system layout and destructive styling.
public struct TypefluxConfirmation {
    public let title: String
    public let message: String
    public let confirmTitle: String
    public let cancelTitle: String
    public let role: ButtonRole?

    public init(title: String, message: String, confirmTitle: String, cancelTitle: String,
                role: ButtonRole? = nil) {
        self.title = title
        self.message = message
        self.confirmTitle = confirmTitle
        self.cancelTitle = cancelTitle
        self.role = role
    }
}
