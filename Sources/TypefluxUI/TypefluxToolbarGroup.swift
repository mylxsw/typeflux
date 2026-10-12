public struct TypefluxToolbarGroup: Identifiable {
    public let id: String
    public let actions: [TypefluxToolbarAction]

    public init(id: String, actions: [TypefluxToolbarAction]) {
        self.id = id
        self.actions = actions
    }
}
