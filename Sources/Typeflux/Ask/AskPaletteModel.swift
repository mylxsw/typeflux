import SwiftUI

/// The field and window dispatcher share one live selection, even before SwiftUI redraws.
@MainActor
final class AskPaletteModel: ObservableObject {
    @Published var query = "" {
        didSet { refresh() }
    }
    @Published private(set) var state = AskPaletteState(actions: [], conversations: [], highlighted: nil)
    private var conversations: [AskConversationSummary] = []
    private var available: [AskPaletteAction] = []

    func update(conversations: [AskConversationSummary], available: [AskPaletteAction]) {
        self.conversations = conversations
        self.available = available
        refresh()
    }

    func move(_ delta: Int) { state.move(delta) }

    func highlight(_ index: Int) {
        guard state.rows.indices.contains(index) else { return }
        state.highlighted = index
    }

    private func refresh() {
        state = AskPaletteState.make(query: query, conversations: conversations, available: available)
    }
}
