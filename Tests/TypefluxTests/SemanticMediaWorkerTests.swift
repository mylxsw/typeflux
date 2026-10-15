import Foundation
import Testing
@testable import Typeflux

final class SemanticMediaFixtureModels: SemanticModelHandling, @unchecked Sendable {
    let source: URL
    var status = 200
    var cancel: AskSearchCancellation?
    var fetches = 0
    init(source: URL) { self.source = source }
    func verify(_ url: URL, cancelled: @Sendable () -> Bool) throws {
        if cancelled() { throw CancellationError() }
        guard FileManager.default.fileExists(atPath: url.path) else { throw URLError(.fileDoesNotExist) }
    }
    func install(_ url: URL, to target: URL, cancelled: @Sendable () -> Bool) throws {
        if cancelled() { throw CancellationError() }
        if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
        try FileManager.default.copyItem(at: url, to: target)
    }
    func fetch(progress: @escaping @Sendable (Int64) -> Void) async throws -> (URL, URLResponse) {
        fetches += 1; progress(100)
        cancel?.cancel()
        try await Task.sleep(for: .milliseconds(150))
        let copy = source.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        try FileManager.default.copyItem(at: source, to: copy)
        return (copy, HTTPURLResponse(url: SemanticMediaModel.url, statusCode: status,
                                     httpVersion: nil, headerFields: nil)!)
    }
}

@Suite("Lazy media model and runtime", .serialized)
struct SemanticMediaWorkerTests {
    @Test func downloadIsLazyVerifiedAndReused() throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("weights"), target = root.appendingPathComponent("projector.gguf")
        try Data("fixture".utf8).write(to: source)
        let models = SemanticMediaFixtureModels(source: source), encoder = SemanticFixtureMediaEncoder()
        let worker = SemanticMediaWorker(helper: source, model: source, projector: target, models: models,
                                         makeEncoder: { _, _, _ in encoder })
        #expect(models.fetches == 0)
        let input = SemanticMediaInput(kind: .image, path: "/fixture.jpg")
        #expect(try worker.embed(input, cancelled: { false }) == semanticVector())
        #expect(try worker.embed(input, cancelled: { false }) == semanticVector())
        #expect(models.fetches == 1 && encoder.calls == 2)
        #expect(try Data(contentsOf: target) == Data(contentsOf: source))
        let cached = SemanticMediaWorker(helper: source, model: source, projector: target, models: models,
                                         makeEncoder: { _, _, _ in encoder })
        _ = try cached.embed(input, cancelled: { false })
        #expect(models.fetches == 1)
    }

    @Test func failedAndCancelledTransfersAreJoinedAndNeverInstalled() throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("weights"), target = root.appendingPathComponent("projector.gguf")
        try Data("fixture".utf8).write(to: source)
        let models = SemanticMediaFixtureModels(source: source), token = AskSearchCancellation()
        models.cancel = token
        let worker = SemanticMediaWorker(helper: source, model: source, projector: target, models: models)
        #expect(throws: CancellationError.self) {
            try worker.embed(.init(kind: .image, path: "/fixture.jpg"), cancelled: { token.isCancelled })
        }
        #expect(!FileManager.default.fileExists(atPath: target.path))
        models.cancel = nil; models.status = 503
        let failing = SemanticMediaWorker(helper: source, model: source, projector: target, models: models)
        #expect(throws: URLError.self) {
            try failing.embed(.init(kind: .audio, path: "/fixture.wav"), cancelled: { false })
        }
        #expect(!FileManager.default.fileExists(atPath: target.path))
        #expect(throws: CancellationError.self) {
            try worker.embed(.init(kind: .image, path: "/fixture.jpg"), cancelled: { true })
        }
    }

    @Test func repeatedQueriesUseTheSmallEmbeddingCache() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let counter = root.appendingPathComponent("calls")
        let vectors = try JSONEncoder().encode([semanticVector()])
        let json = "{\"entries\":[],\"embeddings\":" + (String(data: vectors, encoding: .utf8) ?? "[]") + "}"
        let script = try SemanticEmbeddingWorkerTests().script(
            "while IFS= read -r line; do printf 'x\\n' >> '\(counter.path)'; printf '%s\\n' '" + json + "'; done\n", in: root)
        let worker = SemanticEmbeddingWorker(helper: URL(fileURLWithPath: "/bin/sh"), model: script)
        defer { worker.stop() }
        _ = try await worker.query("reimbursement", lifecycle: AskSearchCancellation())
        _ = try await worker.query("reimbursement", lifecycle: AskSearchCancellation())
        #expect(try String(contentsOf: counter, encoding: .utf8).split(separator: "\n").count == 1)
        for index in 0 ..< 17 { _ = try await worker.query("query \(index)", lifecycle: AskSearchCancellation()) }
        _ = try await worker.query("reimbursement", lifecycle: AskSearchCancellation())
        #expect(try String(contentsOf: counter, encoding: .utf8).split(separator: "\n").count == 19)
        let cancelled = AskSearchCancellation(); cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await worker.query("query 16", lifecycle: cancelled) }
        worker.release()
    }

    @Test func realImageAndAudioEmbeddingsWhenPinnedWeightsAreProvided() throws {
        guard let model = ProcessInfo.processInfo.environment["TYPEFLUX_SEMANTIC_TEST_MODEL"],
              let projector = ProcessInfo.processInfo.environment["TYPEFLUX_SEMANTIC_TEST_PROJECTOR"] else { return }
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        try SemanticMediaModelFiles().verify(URL(fileURLWithPath: projector), cancelled: { false })
        let red = root.appendingPathComponent("red.png"), blue = root.appendingPathComponent("blue.png")
        let audio = root.appendingPathComponent("tone.wav")
        try semanticTestImage(red); try semanticTestImage(blue, red: false)
        let samples = (0 ..< 16000 * 2).map { Float(sin(Double($0) * 0.17) * 0.2) }
        try samples.withUnsafeBytes { try SemanticMediaExtractor.wave(Data($0), to: audio) }
        let worker = SemanticEmbeddingWorker(helper: SemanticModel.helperURL, model: URL(fileURLWithPath: model),
            indexing: true, projector: URL(fileURLWithPath: projector), timeout: 120, startupTimeout: 180)
        defer { worker.release() }
        let redVector = try worker.embed(.init(kind: .image, path: red.path), cancelled: { false })
        let blueVector = try worker.embed(.init(kind: .image, path: blue.path), cancelled: { false })
        let audioVector = try worker.embed(.init(kind: .audio, path: audio.path), cancelled: { false })
        #expect([redVector, blueVector, audioVector].allSatisfy(SemanticFileStore.valid))
        let query = try worker.embed(["task: search result | query: a red square"], cancelled: { false })[0]
        func score(_ vector: [Float]) -> Float { zip(query, vector).reduce(0) { $0 + $1.0 * $1.1 } }
        print("Real cross-modal red query: red=\(score(redVector)), blue=\(score(blueVector))")
        #expect(score(redVector) > score(blueVector))
    }

    @Test func realMediaFilesReachTheSemanticIndexWhenPinnedWeightsAreProvided() async throws {
        guard let model = ProcessInfo.processInfo.environment["TYPEFLUX_SEMANTIC_TEST_MODEL"],
              let projector = ProcessInfo.processInfo.environment["TYPEFLUX_SEMANTIC_TEST_PROJECTOR"] else { return }
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let image = root.appendingPathComponent("image.png")
        let audio = root.appendingPathComponent("tone.wav")
        let movie = root.appendingPathComponent("movie.mov")
        try Data(String(repeating: "A red square appears in this document. ", count: 10).utf8)
            .write(to: root.appendingPathComponent("note.txt"))
        try semanticTestImage(image)
        let samples = (0 ..< 16000).map { Float(sin(Double($0) * 0.17) * 0.2) }
        try samples.withUnsafeBytes { try SemanticMediaExtractor.wave(Data($0), to: audio) }
        try await semanticTestMovie(movie)

        let helper = SemanticModel.helperURL, modelURL = URL(fileURLWithPath: model)
        let store = try SemanticFileStore(url: root.appendingPathComponent("index.sqlite"))
        let encoder = SemanticEmbeddingWorker(helper: helper, model: modelURL, indexing: true)
        let media = SemanticMediaWorker(helper: helper, model: modelURL,
            projector: URL(fileURLWithPath: projector))
        defer { encoder.release() }
        let reader = AskFileReader()
        let result = try SemanticFileIndexer.run(scope: semanticScope(root.path), store: store,
            reader: reader, encoder: encoder, media: media, idle: { true },
            cancelled: { false }, progress: { _ in })
        let counts = try store.counts()
        #expect(result.total == 4 && result.processed == 4)
        #expect(counts.documents == 1 && counts.images == 1 && counts.audio == 1 && counts.videos == 1)
    }
}
