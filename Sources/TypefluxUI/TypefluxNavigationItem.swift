public struct TypefluxNavigationItem: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let systemImage: String
    public let count: Int?

    public init(id: String, title: String, systemImage: String, count: Int? = nil) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.count = count.map { max(0, $0) }
    }
}
