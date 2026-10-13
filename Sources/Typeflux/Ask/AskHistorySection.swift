import Foundation

/// A section is separate from its selectable rows in the native source list.
struct AskHistorySection: Identifiable {
    let id: String
    var items: [AskConversationSummary]

    static func make(_ items: [AskConversationSummary], title: (Date) -> String) -> [Self] {
        var sections: [Self] = []
        for item in items {
            let key = title(item.updatedAt)
            if let index = sections.firstIndex(where: { $0.id == key }) {
                sections[index].items.append(item)
            } else {
                sections.append(Self(id: key, items: [item]))
            }
        }
        return sections
    }
}
