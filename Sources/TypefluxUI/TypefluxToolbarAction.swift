import SwiftUI

public struct TypefluxToolbarAction: Identifiable {
    public let id: String
    public let title: String
    public let systemImage: String
    public let role: ButtonRole?
    public let isEnabled: Bool
    public let perform: () -> Void

    public init(id: String, title: String, systemImage: String, role: ButtonRole? = nil,
                isEnabled: Bool = true, perform: @escaping () -> Void) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.role = role
        self.isEnabled = isEnabled
        self.perform = perform
    }
}
