import Foundation

let vocabularyDecoratedCharacters = "._+-/"

extension Notification.Name {
    static let vocabularyStoreDidChange = Notification.Name("VocabularyStore.didChange")
}

enum VocabularySource: String, Codable, CaseIterable {
    case manual
    case automatic
    case claude
    case codex

    var displayName: String {
        switch self {
        case .manual:
            L("vocabulary.source.manual")
        case .automatic:
            L("vocabulary.source.automatic")
        case .claude:
            L("vocabulary.source.claude")
        case .codex:
            L("vocabulary.source.codex")
        }
    }

    var isExternalAppSource: Bool {
        self == .claude || self == .codex
    }
}

struct VocabularyEntry: Codable, Identifiable, Equatable {
    let id: UUID
    let term: String
    let source: VocabularySource
    let createdAt: Date
    var occurrenceCount: Int

    init(
        id: UUID = UUID(),
        term: String,
        source: VocabularySource,
        createdAt: Date = Date(),
        occurrenceCount: Int = 1,
    ) {
        self.id = id
        self.term = term
        self.source = source
        self.createdAt = createdAt
        self.occurrenceCount = max(0, occurrenceCount)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case term
        case source
        case createdAt
        case occurrenceCount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        term = try container.decode(String.self, forKey: .term)
        source = try container.decode(VocabularySource.self, forKey: .source)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        // Legacy entries saved before the occurrenceCount field existed decode as 1 so
        // they participate in ranking without being pushed to the bottom of the list.
        occurrenceCount = try container.decodeIfPresent(Int.self, forKey: .occurrenceCount) ?? 1
    }
}

struct VocabularyBatchImportResult {
    let entries: [VocabularyEntry]
    let addedCount: Int
    let updatedCount: Int
}

struct VocabularyTransferItem: Codable, Equatable {
    let term: String
    let source: VocabularySource
}

enum VocabularyImportError: LocalizedError, Equatable {
    case unsupportedFormat

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat:
            return "Unsupported vocabulary file format."
        }
    }
}

enum VocabularyStore {
    private static let key = "vocabulary.entries"
    /// Maximum number of terms returned to speech recognition as hints. Beyond this
    /// point most ASR backends either truncate silently or waste prompt budget, so
    /// we cap the list and let ranking decide who stays.
    static let activeTermLimit = 100

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

    static func exportData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(
            rankedEntries().map { VocabularyTransferItem(term: $0.term, source: $0.source) },
        )
    }

    @discardableResult
    static func importEntries(
        from data: Data,
        defaultSource: VocabularySource = .manual,
    ) throws -> VocabularyBatchImportResult {
        let items = try previewImportItems(from: data, defaultSource: defaultSource)
        return try importItems(items)
    }

    static func previewImportItems(
        from data: Data,
        defaultSource: VocabularySource = .manual,
    ) throws -> [VocabularyTransferItem] {
        deduplicatedImportItems(try decodeImportedItems(from: data, defaultSource: defaultSource))
    }

    @discardableResult
    static func importItems(_ items: [VocabularyTransferItem]) throws -> VocabularyBatchImportResult {
        merge(deduplicatedImportItems(items))
    }

    @discardableResult
    static func importTerms(
        _ terms: [String],
        source: VocabularySource = .manual,
    ) -> VocabularyBatchImportResult {
        let importedItems = terms.map {
            VocabularyTransferItem(term: $0, source: source)
        }
        return merge(deduplicatedImportItems(importedItems))
    }

    /// Add a new term, or bump the occurrence count if the normalized term already exists.
    /// Duplicate adds intentionally increment the counter so that "user manually re-added"
    /// and "auto-vocab re-approved" both reinforce ranking, not silently no-op.
    @discardableResult
    static func add(term: String, source: VocabularySource = .manual) -> [VocabularyEntry] {
        let normalized = normalize(term)
        guard !normalized.isEmpty else { return load() }
        let lowered = normalized.lowercased()

        var entries = load()
        if let index = entries.firstIndex(where: { normalize($0.term).lowercased() == lowered }) {
            let existing = entries[index]
            entries[index] = VocabularyEntry(
                id: existing.id,
                term: existing.term,
                source: existing.source,
                createdAt: existing.createdAt,
                occurrenceCount: existing.occurrenceCount + 1,
            )
            save(entries)
            return entries
        }

        entries.insert(
            VocabularyEntry(term: normalized, source: source, occurrenceCount: 1),
            at: 0,
        )
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
        guard !entries.contains(where: { $0.id != id && normalize($0.term).lowercased() == normalized.lowercased() }) else {
            return entries
        }

        let existing = entries[index]
        entries[index] = VocabularyEntry(
            id: existing.id,
            term: normalized,
            source: existing.source,
            createdAt: existing.createdAt,
            occurrenceCount: existing.occurrenceCount,
        )
        save(entries)
        return entries
    }

    /// Scan `text` for any existing vocabulary terms (case-insensitive substring
    /// match) and increment their occurrence count. Returns the names of terms that
    /// were bumped. Safe to call from any dictation/edit path — no-op when nothing
    /// matches or the text is empty.
    @discardableResult
    static func incrementOccurrences(in text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var entries = load()
        guard !entries.isEmpty else { return [] }

        let lowercasedText = trimmed.lowercased()
        var bumped: [String] = []
        for index in entries.indices {
            let lowered = entries[index].term.lowercased()
            guard !lowered.isEmpty, lowercasedText.contains(lowered) else { continue }
            let existing = entries[index]
            entries[index] = VocabularyEntry(
                id: existing.id,
                term: existing.term,
                source: existing.source,
                createdAt: existing.createdAt,
                occurrenceCount: existing.occurrenceCount + 1,
            )
            bumped.append(existing.term)
        }

        guard !bumped.isEmpty else { return [] }
        save(entries)
        return bumped
    }

    /// Top-ranked terms used as speech-recognition hints. Capped at
    /// `activeTermLimit`; higher occurrence count wins, ties broken by later
    /// `createdAt`. ASR backends consume this list.
    static func activeTerms() -> [String] {
        rankedEntries().prefix(activeTermLimit).map(\.term)
    }

    /// Full term list, unsorted by rank. Use this for deduplication, settings UI,
    /// and LLM "existing vocabulary" prompts — anywhere the ASR cap would lose
    /// useful signal.
    static func allTerms() -> [String] {
        load().map(\.term)
    }

    /// Entries sorted by (occurrenceCount DESC, createdAt DESC). Exposed for UI
    /// and diagnostics; ASR callers should use `activeTerms()`.
    static func rankedEntries() -> [VocabularyEntry] {
        load().sorted { lhs, rhs in
            if lhs.occurrenceCount != rhs.occurrenceCount {
                return lhs.occurrenceCount > rhs.occurrenceCount
            }
            return lhs.createdAt > rhs.createdAt
        }
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
                let normalized = normalize(entry.term).lowercased()
                guard !normalized.isEmpty, !seen.contains(normalized) else { return false }
                seen.insert(normalized)
                return true
            }
    }

    private static func merge(_ importedItems: [VocabularyTransferItem]) -> VocabularyBatchImportResult {
        var entries = load()
        var addedCount = 0
        var updatedCount = 0

        for importedItem in importedItems {
            let normalizedTerm = normalize(importedItem.term)
            guard !normalizedTerm.isEmpty else { continue }
            if let index = entries.firstIndex(where: {
                normalize($0.term).caseInsensitiveCompare(normalizedTerm) == .orderedSame
            }) {
                let existing = entries[index]
                let mergedEntry = VocabularyEntry(
                    id: existing.id,
                    term: preferredSurface(existing: existing.term, imported: normalizedTerm),
                    source: mergedSource(existing: existing.source, imported: importedItem.source),
                    createdAt: existing.createdAt,
                    occurrenceCount: ensureMinimumCount(existing.occurrenceCount),
                )
                if mergedEntry != existing {
                    entries[index] = mergedEntry
                    updatedCount += 1
                }
            } else {
                entries.insert(
                    VocabularyEntry(
                        term: normalizedTerm,
                        source: importedItem.source,
                    ),
                    at: 0,
                )
                addedCount += 1
            }
        }

        save(entries)
        return VocabularyBatchImportResult(
            entries: load(),
            addedCount: addedCount,
            updatedCount: updatedCount,
        )
    }

    private static func decodeImportedItems(
        from data: Data,
        defaultSource: VocabularySource,
    ) throws -> [VocabularyTransferItem] {
        let decoder = JSONDecoder()
        if let entries = try? decoder.decode([VocabularyTransferItem].self, from: data) {
            return entries
        }

        if let terms = try? decoder.decode([String].self, from: data) {
            return terms.map { VocabularyTransferItem(term: $0, source: defaultSource) }
        }

        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let terms = object["terms"] as? [String]
        {
            return terms.map { VocabularyTransferItem(term: $0, source: defaultSource) }
        }

        guard let text = String(data: data, encoding: .utf8) else {
            throw VocabularyImportError.unsupportedFormat
        }

        let separators = CharacterSet(charactersIn: ",;\n\r")
        let terms = text
            .components(separatedBy: separators)
            .map { VocabularyTransferItem(term: $0, source: defaultSource) }
            .filter { !normalize($0.term).isEmpty }

        guard !terms.isEmpty else {
            throw VocabularyImportError.unsupportedFormat
        }

        return terms
    }

    private static func deduplicatedImportItems(_ items: [VocabularyTransferItem]) -> [VocabularyTransferItem] {
        var deduplicated: [VocabularyTransferItem] = []
        var indexByNormalizedTerm: [String: Int] = [:]

        for item in items {
            let normalizedTerm = normalize(item.term)
            guard !normalizedTerm.isEmpty else { continue }
            let key = normalizedTerm.lowercased()

            if let index = indexByNormalizedTerm[key] {
                let existing = deduplicated[index]
                deduplicated[index] = VocabularyTransferItem(
                    term: preferredSurface(existing: existing.term, imported: normalizedTerm),
                    source: mergedSource(existing: existing.source, imported: item.source),
                )
            } else {
                deduplicated.append(
                    VocabularyTransferItem(term: normalizedTerm, source: item.source),
                )
                indexByNormalizedTerm[key] = deduplicated.endIndex - 1
            }
        }

        return deduplicated
    }

    /// Merge source precedence keeps the highest-signal provenance available:
    /// manual > same source > latest imported external app > existing external app >
    /// automatic/other existing source.
    /// This lets local/user-curated terms stay strongest while ensuring an explicit
    /// Claude/Codex import updates the displayed provenance for shared terms.
    private static func mergedSource(
        existing: VocabularySource,
        imported: VocabularySource,
    ) -> VocabularySource {
        if existing == .manual || imported == .manual {
            return .manual
        }
        if existing == imported {
            return existing
        }
        if imported.isExternalAppSource {
            return imported
        }
        if existing.isExternalAppSource {
            return existing
        }
        if existing == .automatic || imported == .automatic {
            return .automatic
        }
        return existing
    }

    /// Preserve the user-visible spelling that carries more intent: decorated
    /// terms (uppercase, separators, or punctuation commonly used in product and
    /// model names) are preferred over plain lowercase imports.
    private static func preferredSurface(existing: String, imported: String) -> String {
        let existingHasDecoratedCharacters = existing.hasVocabularyDecoration
        let importedHasDecoratedCharacters = imported.hasVocabularyDecoration
        if importedHasDecoratedCharacters && !existingHasDecoratedCharacters {
            return imported
        }
        return existing
    }

    private static func normalize(_ term: String) -> String {
        term.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func ensureMinimumCount(_ count: Int) -> Int {
        max(1, count)
    }
}

private extension String {
    var hasVocabularyDecoration: Bool {
        contains(where: { $0.isUppercase || vocabularyDecoratedCharacters.contains($0) })
    }
}
