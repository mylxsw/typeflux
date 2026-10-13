import Testing
@testable import Typeflux

struct AskWorkspaceSearchTests {
    private let conversations = [
        AskConversationSummary(id: "cloud", title: "Release plan", updatedAt: .distantPast),
        AskConversationSummary(id: "private", title: "Private release notes", updatedAt: .distantPast),
        AskConversationSummary(id: "other", title: "Swift concurrency", updatedAt: .distantPast)
    ]

    @Test(arguments: ["", " \n\t "])
    func emptySearchPreservesAllRowsAndTheirOrder(query: String) {
        #expect(AskWorkspaceSearch.filter(conversations, query: query) == conversations)
    }

    @Test func titleSearchTrimsWhitespaceAndIgnoresCase() {
        #expect(AskWorkspaceSearch.filter(conversations, query: "  RELEASE \n").map(\.id) == ["cloud", "private"])
        #expect(AskWorkspaceSearch.filter(conversations, query: "missing").isEmpty)
        #expect(AskWorkspaceSearch.filter([], query: "release").isEmpty)
    }

    @Test func searchRespectsThePrivateConversationFilter() {
        let local = AskHistoryFilter.local.apply(conversations, isLocal: { $0 == "private" })
        let cloud = AskHistoryFilter.cloud.apply(conversations, isLocal: { $0 == "private" })
        #expect(AskWorkspaceSearch.filter(local, query: "release").map(\.id) == ["private"])
        #expect(AskWorkspaceSearch.filter(cloud, query: "release").map(\.id) == ["cloud"])
    }
}
