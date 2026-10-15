import Foundation

/// The production composition root is also injectable without constructing
/// AppKit, audio devices or unrelated application services in storage tests.
struct StorageModules: Sendable {
    let notes: RecoveringAskNoteStore
    let words: RecoveringAskWordBookStore
    let conversations: RecoveringAskConversationCache
    let registry: ModuleRegistry

    init(healthDirectory: URL,
         conversationFactory: @escaping @Sendable () throws -> any AskCaching,
         wordBookFactory: @escaping @Sendable () throws -> any AskWordBookStoring,
         noteFactory: @escaping @Sendable () throws -> any AskNoteStoring) {
        notes = RecoveringAskNoteStore(factory: noteFactory,
            healthStore: ModuleHealthStore(url: healthDirectory.appendingPathComponent("notebook.json")))
        words = RecoveringAskWordBookStore(factory: wordBookFactory,
            healthStore: ModuleHealthStore(url: healthDirectory.appendingPathComponent("wordBook.json")))
        conversations = RecoveringAskConversationCache(factory: conversationFactory,
            healthStore: ModuleHealthStore(url: healthDirectory.appendingPathComponent("conversations.json")))
        // These stores are independent. Losing chat must not disable notebooks
        // or translations, and none is a prerequisite for the launcher shell.
        registry = ModuleRegistry([
            .init(.conversations, handle: conversations.module),
            .init(.wordBook, handle: words.module), .init(.notebook, handle: notes.module)
        ])
    }
}
