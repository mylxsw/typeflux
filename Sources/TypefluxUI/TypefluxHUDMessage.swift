import Foundation

public struct TypefluxHUDMessage: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let title: String
    public let systemImage: String

    public init(title: String, systemImage: String = "checkmark.circle.fill", id: UUID = UUID()) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
    }
}
