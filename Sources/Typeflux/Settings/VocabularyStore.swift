import Foundation

extension Notification.Name {
    static let vocabularyStoreDidChange = Notification.Name("VocabularyStore.didChange")
}

enum VocabularySource: String, Codable, CaseIterable {
    case manual
    case automatic

    var displayName: String {
        switch self {
        case .manual:
            L("vocabulary.source.manual")
        case .automatic:
            L("vocabulary.source.automatic")
        }
    }
}

struct VocabularyEntry: Codable, Identifiable, Equatable {
    let id: UUID
    let term: String
    let source: VocabularySource
    let createdAt: Date

    init(id: UUID = UUID(), term: String, source: VocabularySource, createdAt: Date = Date()) {
        self.id = id
        self.term = term
        self.source = source
        self.createdAt = createdAt
    }
}

enum VocabularyStore {
    private static let key = "vocabulary.entries"

    static func load() -> [VocabularyEntry] {
        guard let data = UserDefaults.standard.data(forKey: key) else {
            return []
        }

        do {
            let decoded = try JSONDecoder().decode([VocabularyEntry].self, from: data)
            return deduplicated(decoded)
        } catch {
            ErrorLogStore.shared.log("Vocabulary load failed: \(error.localizedDescription)")
            return []
        }
    }

    static func save(_ entries: [VocabularyEntry]) {
        let deduplicatedEntries = deduplicated(entries)

        do {
            let data = try JSONEncoder().encode(deduplicatedEntries)
            UserDefaults.standard.set(data, forKey: key)
            NotificationCenter.default.post(
                name: .vocabularyStoreDidChange,
                object: nil,
                userInfo: ["entries": deduplicatedEntries],
            )
        } catch {
            ErrorLogStore.shared.log("Vocabulary save failed: \(error.localizedDescription)")
        }
    }

    static func add(term: String, source: VocabularySource = .manual) -> [VocabularyEntry] {
        let normalized = normalize(term)
        guard !normalized.isEmpty else { return load() }

        var entries = load()
        guard !entries.contains(where: { normalize($0.term) == normalized }) else { return entries }

        entries.insert(VocabularyEntry(term: normalized, source: source), at: 0)
        save(entries)
        return entries
    }

    static func remove(id: UUID) -> [VocabularyEntry] {
        var entries = load()
        entries.removeAll { $0.id == id }
        save(entries)
        return entries
    }

    static func update(id: UUID, term: String) -> [VocabularyEntry] {
        let normalized = normalize(term)
        guard !normalized.isEmpty else { return load() }

        var entries = load()
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return entries }
        guard !entries.contains(where: { $0.id != id && normalize($0.term) == normalized }) else { return entries }

        let existing = entries[index]
        entries[index] = VocabularyEntry(
            id: existing.id,
            term: normalized,
            source: existing.source,
            createdAt: existing.createdAt,
        )
        save(entries)
        return entries
    }

    static func activeTerms() -> [String] {
        load().map(\.term)
    }

    private static func deduplicated(_ entries: [VocabularyEntry]) -> [VocabularyEntry] {
        var seen = Set<String>()
        return entries
            .sorted { lhs, rhs in
                if lhs.createdAt == rhs.createdAt {
                    return lhs.term.localizedCaseInsensitiveCompare(rhs.term) == .orderedAscending
                }
                return lhs.createdAt > rhs.createdAt
            }
            .filter { entry in
                let normalized = normalize(entry.term)
                guard !normalized.isEmpty, !seen.contains(normalized) else { return false }
                seen.insert(normalized)
                return true
            }
    }

    private static func normalize(_ term: String) -> String {
        term.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
