/// A bounded heap whose root is the worst retained item. Memory is O(limit),
/// and selecting a few recent files no longer sorts the entire index.
struct AskSearchTopK<Element> {
    private(set) var items: [Element] = []
    let limit: Int
    let precedes: (Element, Element) -> Bool

    @inline(__always) mutating func insert(_ value: Element) {
        guard limit > 0 else { return }
        if items.count < limit {
            items.append(value)
            var child = items.count - 1
            while child > 0 {
                let parent = (child - 1) / 2
                guard precedes(items[parent], items[child]) else { break }
                items.swapAt(parent, child)
                child = parent
            }
        } else if precedes(value, items[0]) {
            items[0] = value
            var parent = 0
            while parent * 2 + 1 < items.count {
                var child = parent * 2 + 1
                if child + 1 < items.count, precedes(items[child], items[child + 1]) { child += 1 }
                guard precedes(items[parent], items[child]) else { break }
                items.swapAt(parent, child)
                parent = child
            }
        }
    }

    var sorted: [Element] { items.sorted(by: precedes) }
}
