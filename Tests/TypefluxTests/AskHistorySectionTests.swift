import Foundation
import Testing
@testable import Typeflux

struct AskHistorySectionTests {
    @Test func headersHaveTheirOwnIdentityAndRowsKeepTheirOrder() {
        let items = [
            AskConversationSummary(id: "first", title: "First", updatedAt: .distantPast),
            AskConversationSummary(id: "second", title: "Second", updatedAt: .distantFuture),
            AskConversationSummary(id: "third", title: "Third", updatedAt: .distantPast)
        ]
        let sections = AskHistorySection.make(items) { $0 == .distantPast ? "earlier" : "today" }
        #expect(sections.map(\.id) == ["earlier", "today"])
        #expect(sections[0].items.map(\.id) == ["first", "third"])
        #expect(sections[1].items.map(\.id) == ["second"])
        #expect(AskHistorySection.make([]) { _ in "today" }.isEmpty)
    }
}
