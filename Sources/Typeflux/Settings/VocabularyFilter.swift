import Foundation

enum VocabularyFilter: String, CaseIterable, Identifiable {
    case all, automatic, manual, otherApps

    var id: String {
        rawValue
    }

    var title: String {
        L("vocabulary.filter." + rawValue)
    }

    func matches(_ source: VocabularySource) -> Bool {
        switch self {
        case .all: true
        case .automatic: source == .automatic
        case .manual: source == .manual
        case .otherApps: source.isExternalAppSource
        }
    }

    func entries(in entries: [VocabularyEntry], query: String) -> [VocabularyEntry] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return entries
            .filter { matches($0.source) && (query.isEmpty || $0.term.localizedCaseInsensitiveContains(query)) }
    }
}
