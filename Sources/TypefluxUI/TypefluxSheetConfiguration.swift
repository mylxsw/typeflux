import SwiftUI

public struct TypefluxSheetConfiguration {
    public let title: String
    public let cancelTitle: String
    public let confirmTitle: String
    public let isConfirmEnabled: Bool
    public let role: ButtonRole?

    public init(title: String, cancelTitle: String, confirmTitle: String,
                isConfirmEnabled: Bool = true, role: ButtonRole? = nil) {
        self.title = title
        self.cancelTitle = cancelTitle
        self.confirmTitle = confirmTitle
        self.isConfirmEnabled = isConfirmEnabled
        self.role = role
    }
}
