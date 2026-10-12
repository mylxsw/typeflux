public struct TypefluxSpotlightItem: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let subtitle: String?
    public let systemImage: String
    public let isEnabled: Bool

    public init(id: String, title: String, subtitle: String? = nil,
                systemImage: String = "doc", isEnabled: Bool = true) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.isEnabled = isEnabled
    }
}
