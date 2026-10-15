import Foundation
import Testing
@testable import Typeflux

@Suite("Independent lexical WAL reader")
struct SemanticLexicalSearchTests {
    @Test func `cjk filters permissions cancellation and committed changes`() throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try SemanticFileStore(url: root.appendingPathComponent("index.sqlite"))
        let scope = semanticScope(root.path)
        for name in ["skip.pdf", "casefolder/match.txt", "match.txt"] {
            try store.replace(path: root.path + "/" + name, modified: Date(timeIntervalSince1970: 1), bytes: 10,
                              chunks: [.init(text: "项目报销流程 reimbursement", page: 3)], vectors: [semanticVector()])
        }
        func search(_ text: String, type: AskFileType = .all, scope: AskFileScope? = nil, limit: Int = 5,
                    cancelled: () -> Bool = { false }) throws -> [AskFileHit] {
            try store.lexicalSearch(
                text: text,
                query: AskSearchQuery(text),
                type: type,
                scope: scope ?? semanticScope(root.path),
                limit: limit,
                cancelled: cancelled
            )
        }
        #expect(try search("报销").count == 3)
        #expect(try search("报销").first?.evidence?.page == 3)
        #expect(try search("reimbursement .pdf").map(\.name) == ["skip.pdf"])
        #expect(try search("reimbursement in:casefolder").map(\.name) == ["match.txt"])
        #expect(try search("reimbursement", type: .pdf, limit: 1).map(\.name) == ["skip.pdf"])
        #expect(try search("unmatched").isEmpty)
        #expect(try search("\" OR *").isEmpty)
        #expect(try search("reimbursement", limit: 0).isEmpty)
        #expect(try search("").isEmpty)
        var restricted = scope; restricted.excludedPaths = [root.path + "/casefolder"]
        #expect(try search("reimbursement", scope: restricted).count == 2)
        #expect(throws: CancellationError.self) { try search("reimbursement", cancelled: { true }) }
        try store.remove(root.path + "/skip.pdf")
        #expect(try search("reimbursement", type: .pdf).isEmpty)
        try store.destroy()
        #expect(throws: SemanticFileStore.Failure.self) { try search("reimbursement") }
    }

    @Test func `blocked matches do not consume top K and chunks deduplicate`() throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try SemanticFileStore(url: root.appendingPathComponent("index.sqlite"))
        for name in ["blocked.txt", "allowed.txt"] {
            try store.replace(path: root.path + "/" + name, modified: Date(), bytes: 1,
                              chunks: [.init(text: "needle", page: 1), .init(text: "needle", page: 2)],
                              vectors: [semanticVector(), semanticVector()])
        }
        var scope = semanticScope(root.path); scope.excludedPaths = [root.path + "/blocked.txt"]
        let hits = try store.lexicalSearch(text: "needle", query: .init("needle"), type: .all, scope: scope,
                                           limit: 1, cancelled: { false })
        #expect(hits.map(\.name) == ["allowed.txt"])
    }
}
