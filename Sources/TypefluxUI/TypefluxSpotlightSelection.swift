/// Preserves the selected result across updates and skips disabled results.
public struct TypefluxSpotlightSelection: Equatable, Sendable {
    public private(set) var selectedID: String?

    public init(selectedID: String? = nil) {
        self.selectedID = selectedID
    }

    public mutating func reconcile(_ items: [TypefluxSpotlightItem]) {
        if items.contains(where: { $0.id == selectedID && $0.isEnabled }) {
            return
        }
        selectedID = items.first(where: \.isEnabled)?.id
    }

    public mutating func select(_ id: String, in items: [TypefluxSpotlightItem]) {
        guard items.contains(where: { $0.id == id && $0.isEnabled }) else { return }
        selectedID = id
    }

    public mutating func move(_ delta: Int, in items: [TypefluxSpotlightItem]) {
        let enabled = items.filter(\.isEnabled)
        guard !enabled.isEmpty else { selectedID = nil; return }
        guard let current = enabled.firstIndex(where: { $0.id == selectedID }) else {
            selectedID = enabled[0].id
            return
        }
        // Clamp before addition to handle even an extreme delta without overflow.
        let step = min(max(delta, -current), enabled.count - 1 - current)
        selectedID = enabled[current + step].id
    }

    public func quickResult(_ number: Int, in items: [TypefluxSpotlightItem]) -> TypefluxSpotlightItem? {
        guard (1 ... 9).contains(number), items.indices.contains(number - 1),
              items[number - 1].isEnabled else { return nil }
        return items[number - 1]
    }
}
