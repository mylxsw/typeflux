import Foundation

/// Folders the user attached to a conversation. The `files` tool can read them
/// for that conversation only, next to the folders authorized in Settings.
/// Grants survive a restart so follow-ups keep working; the oldest
/// conversations drop off once `maximumConversations` is reached.
final class AskFolderGrants: @unchecked Sendable {
    static let maximumConversations = 200
    static let defaultsKey = "ask.folderGrants"

    private let defaults: UserDefaults
    private let lock = NSLock()

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    private struct Entry: Codable { var conversationId: String; var paths: [String] }

    private func load() -> [Entry] {
        guard let data = defaults.data(forKey: Self.defaultsKey) else { return [] }
        return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
    }

    private func store(_ entries: [Entry]) {
        defaults.set(try? JSONEncoder().encode(entries), forKey: Self.defaultsKey)
    }

    func folders(for conversationId: String) -> [String] {
        lock.lock(); defer { lock.unlock() }
        let id = conversationId.lowercased()
        return load().first { $0.conversationId == id }?.paths ?? []
    }

    /// Adds folders to a conversation and marks it most recently used.
    func grant(_ paths: [String], to conversationId: String) {
        let paths = paths.filter { !$0.isEmpty }
        guard !paths.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        let id = conversationId.lowercased()
        var entries = load()
        var existing = entries.first { $0.conversationId == id }?.paths ?? []
        for path in paths where !existing.contains(path) { existing.append(path) }
        entries.removeAll { $0.conversationId == id }
        entries.append(Entry(conversationId: id, paths: existing))
        store(Array(entries.suffix(Self.maximumConversations)))
    }

    func revoke(_ conversationId: String) {
        lock.lock(); defer { lock.unlock() }
        let id = conversationId.lowercased()
        store(load().filter { $0.conversationId != id })
    }
}
