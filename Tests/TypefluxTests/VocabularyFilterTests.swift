import Foundation
import Testing
@testable import Typeflux

@Suite(.exclusiveUIState)
@MainActor
struct VocabularyFilterTests {
    @Test func `every source is represented and search trims whitespace`() {
        let sources = VocabularySource.allCases
        let entries = sources.enumerated().map { VocabularyEntry(term: "Term \($0.offset)", source: $0.element) }
        #expect(VocabularyFilter.all.entries(in: entries, query: " \n ").count == 4)
        #expect(VocabularyFilter.manual.entries(in: entries, query: "term").map(\.source) == [.manual])
        #expect(VocabularyFilter.automatic.entries(in: entries, query: " TERM ").map(\.source) == [.automatic])
        #expect(Set(VocabularyFilter.otherApps.entries(in: entries, query: "").map(\.source)) == [.claude, .codex])
        #expect(VocabularyFilter.all.entries(in: entries, query: "missing").isEmpty)
        for filter in VocabularyFilter.allCases {
            #expect(filter.id == filter.rawValue)
            #expect(!filter.title.hasPrefix("vocabulary.filter."))
            for source in sources {
                _ = filter.matches(source)
            }
        }
        for filter in HistorySettingsFilter.allCases {
            #expect(filter.id == filter.rawValue)
            #expect(!filter.title.hasPrefix("history.filter."))
        }
    }

    @Test func `all four table columns support ascending and descending sorting`() {
        let first = VocabularyEntry(term: "Alpha", source: .automatic, createdAt: Date(timeIntervalSince1970: 100),
                                    occurrenceCount: 4)
        let second = VocabularyEntry(term: "Beta", source: .manual, createdAt: Date(timeIntervalSince1970: 200),
                                     occurrenceCount: 8)
        let comparators = [KeyPathComparator(\VocabularyEntry.term), KeyPathComparator(\VocabularyEntry.sourceTitle),
                           KeyPathComparator(\VocabularyEntry.occurrenceCount),
                           KeyPathComparator(\VocabularyEntry.createdAt)]
        for comparator in comparators {
            let ascending = [first, second].sorted(using: [comparator])
            var reverse = comparator
            reverse.order = .reverse
            #expect([first, second].sorted(using: [reverse]).map(\.id) == ascending.reversed().map(\.id))
        }
    }
}
