import Foundation
import Testing
@testable import Typeflux

@Suite("Semantic inference isolation")
struct SemanticEmbeddingWorkerTests {
    func script(_ contents: String, in root: URL) throws -> URL {
        let url = root.appendingPathComponent(UUID().uuidString + ".sh")
        try Data(contents.utf8).write(to: url)
        return url
    }

    @Test func `validated vectors and malformed helper responses`() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let vector = semanticVector()
        let json = try "{\"entries\":[],\"embeddings\":" + String(decoding: JSONEncoder().encode([vector]), as: UTF8.self) + "}"
        let source = try script("while IFS= read -r line; do printf '%s\\n' '" + json + "'; done\n", in: root)
        let worker = SemanticEmbeddingWorker(helper: URL(fileURLWithPath: "/bin/sh"), model: source)
        #expect(try worker.embed(["document"], cancelled: { false }) == [vector])
        #expect(try await worker.query("query", lifecycle: AskSearchCancellation()) == vector)
        #expect(throws: SemanticFileStore.Failure.self) { try worker.embed(["one", "two"], cancelled: { false }) }
        #expect(throws: CancellationError.self) { try worker.embed(["document"], cancelled: { true }) }
        worker.stop()
        for response in ["{\"entries\":[],\"error\":22}", "{\"entries\":[],\"embeddings\":[[0]]}", "broken-json"] {
            let file = try script("read line; printf '%s\\n' '" + response + "'\n", in: root)
            let invalid = SemanticEmbeddingWorker(helper: URL(fileURLWithPath: "/bin/sh"), model: file)
            #expect(throws: (any Error).self) { try invalid.embed(["document"], cancelled: { false }) }
        }
        let idle = try script("read first; read second\n", in: root)
        let blocked = SemanticEmbeddingWorker(
            helper: URL(fileURLWithPath: "/bin/sh"),
            model: idle,
            timeout: 0.05,
            startupTimeout: 0.05
        )
        #expect(throws: AskFileReadError.self) { try blocked.embed(["document"], cancelled: { false }) }
    }

    @Test func realModelUsesTheApplicationIPCWhenProvided() async throws {
        guard let path = ProcessInfo.processInfo.environment["TYPEFLUX_SEMANTIC_TEST_MODEL"] else { return }
        let helper = SemanticModel.helperURL
        #expect(FileManager.default.isExecutableFile(atPath: helper.path), "Build the optional helper first")
        let worker = SemanticEmbeddingWorker(helper: helper, model: URL(fileURLWithPath: path))
        let vector = try await worker.query("项目费用报销需要什么？", lifecycle: AskSearchCancellation())
        #expect(SemanticFileStore.valid(vector))
        worker.stop()
    }
}
