import Foundation
import Testing
@testable import Typeflux

final class SemanticMediaFixtureReader: AskFileReading, @unchecked Sendable {
    let root: String
    var names = ["video.mov", "audio.wav", "image.png", "document.md"]
    var current = ""
    var scratch: String?
    var pieces = 1
    var badPath = false
    var changeAfter = false
    var finalFailure = false
    var directoryReads = 0
    var modified = Date(timeIntervalSince1970: 100)
    var modifiedByName: [String: Date] = [:]
    init(root: String) {
        self.root = root
    }

    func read(_ request: AskFileReadRequest, isCancelled: () -> Bool) throws -> AskFileReadResponse {
        if isCancelled() {
            throw CancellationError()
        }
        if request.operation == .directory {
            directoryReads += 1
            return .init(entries: names.map {
                .init(path: root + "/" + $0, kind: .file, modified: modifiedByName[$0] ?? modified)
            })
        }
        current = (request.path as NSString).lastPathComponent
        return .init(fileSize: 20, modified: modifiedByName[current] ?? modified,
                     pages: request.readText ? [.init(text: "reimbursement")] : nil)
    }

    func stream(_ request: AskFileReadRequest, isCancelled: () -> Bool,
                receive: (AskFileReadResponse) -> Bool) throws {
        guard request.operation == .media else { _ = try receive(read(request, isCancelled: isCancelled)); return }
        current = (request.path as NSString).lastPathComponent; scratch = request.scratch
        let folder = URL(fileURLWithPath: request.scratch!)
        for index in 0 ..< pieces {
            if isCancelled() {
                throw CancellationError()
            }
            let file = folder.appendingPathComponent("piece-\(index).jpg")
            try Data("fixture".utf8).write(to: file)
            let input = SemanticMediaInput(kind: current.hasSuffix("wav") ? .audio : .image,
                                           path: badPath ? "/outside/piece.jpg" : file.path, time: Double(index * 30))
            if !receive(.init(more: true, media: input)) {
                return
            }
        }
        if changeAfter {
            modified = modified.addingTimeInterval(1)
        }
        _ = receive(finalFailure ? .init(error: EILSEQ) : .init(
            fileSize: 20,
            modified: modifiedByName[current] ?? modified
        ))
    }
}

final class SemanticFixtureMediaEncoder: SemanticMediaEmbedding, @unchecked Sendable {
    var before: ((SemanticMediaInput) throws -> Void)?
    var calls = 0
    func embed(_ input: SemanticMediaInput, cancelled: () -> Bool) throws -> [Float] {
        if cancelled() {
            throw CancellationError()
        }
        calls += 1; try before?(input)
        return semanticVector()
    }
}

@Suite("Document-first idle media indexing", .serialized)
struct SemanticMediaIndexTests {
    @Test func `queued images do not starve audio and video`() throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let reader = SemanticMediaFixtureReader(root: root.path)
        reader.names = (0 ..< 10).map { "image-\($0).png" } + ["audio.wav", "video.mov"]
        let store = try SemanticFileStore(url: root.appendingPathComponent("index.sqlite"))
        let encoder = SemanticFixtureEncoder(), media = SemanticFixtureMediaEncoder()
        var order: [String] = []
        media.before = { _ in order.append(reader.current) }
        _ = try SemanticFileIndexer.run(scope: semanticScope(root.path), store: store, reader: reader, encoder: encoder,
                                        media: media, cancelled: { false }, progress: { _ in })
        #expect(order.prefix(3) == ["image-0.png", "audio.wav", "video.mov"])
        #expect(try store.counts().files == 12)
    }

    @Test func `real file worker commits image audio and video`() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let image = root.appendingPathComponent("image.png")
        let audio = root.appendingPathComponent("tone.wav")
        let movie = root.appendingPathComponent("movie.mov")
        try semanticTestImage(image)
        let samples = (0 ..< 16000).map { Float(sin(Double($0) * 0.17) * 0.2) }
        try samples.withUnsafeBytes { try SemanticMediaExtractor.wave(Data($0), to: audio) }
        try await semanticTestMovie(movie)
        let store = try SemanticFileStore(url: root.appendingPathComponent("index.sqlite"))
        let result = try SemanticFileIndexer.run(scope: semanticScope(root.path), store: store,
                                                 reader: AskFileReader(), encoder: SemanticFixtureEncoder(),
                                                 media: SemanticFixtureMediaEncoder(),
                                                 cancelled: { false }, progress: { _ in })
        let counts = try store.counts()
        #expect(result.total == 3 && result.processed == 3 && result.skipped == 0)
        #expect(counts.images == 1 && counts.audio == 1 && counts.videos == 1)
        #expect(counts.chunks >= 3)
    }

    @Test func `documents then images audio and video with idle gating and time evidence`() throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try SemanticFileStore(url: root.appendingPathComponent("index.sqlite"))
        let reader = SemanticMediaFixtureReader(root: root.path), encoder = SemanticFixtureEncoder()
        let media = SemanticFixtureMediaEncoder()
        var order: [String] = [], idleCalls = 0, progress: [SemanticFileIndexer.Summary] = []
        encoder.after = { order.append(reader.current) }
        media.before = { _ in order.append(reader.current) }
        let result = try SemanticFileIndexer.run(scope: semanticScope(root.path), store: store, reader: reader,
                                                 encoder: encoder, media: media,
                                                 idle: { idleCalls += 1; return idleCalls > 1 },
                                                 cancelled: { false }, progress: { progress.append($0) })
        #expect(order == ["document.md", "image.png", "audio.wav", "video.mov"])
        #expect(result.files == 4 && result.total == 4 && result.processed == 4)
        #expect(progress.contains { $0.waitingForIdle && $0.priority == .image })
        #expect(progress.last?.waitingForIdle == false)
        #expect(try store.counts().chunks == 4)
        for (type, name) in [(AskFileType.image, "image.png"), (.audio, "audio.wav"), (.video, "video.mov")] {
            let hits = try store.search(vector: semanticVector(), text: "music", query: .init("music"),
                                        type: type, scope: semanticScope(root.path), limit: 2, cancelled: { false })
            #expect(hits.map(\.name) == [name]); #expect(hits.first?.evidence?.time == 0)
            #expect(hits.first?.evidence?.text == "")
        }
        _ = try SemanticFileIndexer.run(scope: semanticScope(root.path), store: store, reader: reader,
                                        encoder: encoder, media: media, idle: {
                                            Issue.record("unchanged media must not wait for idle"); return true
                                        },
                                        cancelled: { false }, progress: { _ in })
        #expect(encoder.calls == 1 && media.calls == 3)
    }

    @Test(arguments: [false, true], [false, true])
    func `document events preempt at segment boundaries without repeating completed media`(
        rescan: Bool,
        targeted: Bool
    ) throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try SemanticFileStore(url: root.appendingPathComponent("index.sqlite"))
        let reader = SemanticMediaFixtureReader(root: root.path)
        reader.names = ["video.mov"]; reader.pieces = 3
        let priorityReader = SemanticFixtureReader(path: root.path + "/new-document.md")
        let encoder = SemanticFixtureEncoder(), media = SemanticFixtureMediaEncoder(), gate = SemanticIndexPauseGate()
        media.before = { _ in
            if media.calls == 1 {
                if rescan {
                    gate.enqueueDocumentScan()
                } else {
                    gate.enqueueDocuments([priorityReader.path])
                }
            } else {
                let hits = try store.lexicalSearch(text: "reimbursement", query: .init("reimbursement"), type: .all,
                                                   scope: semanticScope(root.path), limit: 5, cancelled: { false })
                #expect(hits.map(\.path) == [priorityReader.path])
            }
        }
        let result: SemanticFileIndexer.Summary = if targeted {
            try SemanticFileIndexer.reconcile(paths: [root.path + "/video.mov"], scope: semanticScope(root.path),
                                              store: store, reader: reader, encoder: encoder, media: media,
                                              documents: { gate.takeDocuments() },
                                              priorityReader: priorityReader, cancelled: { false },
                                              progress: { _ in })
        } else {
            try SemanticFileIndexer.run(scope: semanticScope(root.path), store: store, reader: reader,
                                        encoder: encoder, media: media, documents: { gate.takeDocuments() },
                                        priorityReader: priorityReader,
                                        cancelled: { false }, progress: { _ in })
        }
        #expect(media.calls == 3 && encoder.calls == 1)
        #expect(result.priorityUpdates == 1)
        #expect(try store.counts().chunks == 4)
        #expect(try store.counts().files == 2)
        #expect(priorityReader.directoryReads == (rescan ? 1 : 0))
    }

    @Test func `cancellation keeps a private snapshot and never publishes partial vectors`() throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let reader = SemanticMediaFixtureReader(root: root.path); reader.names = ["video.mov"]; reader.pieces = 2
        let store = try SemanticFileStore(url: root.appendingPathComponent("index.sqlite"))
        let previous = reader.modified.addingTimeInterval(-1), path = root.path + "/video.mov"
        try store.replace(path: path, modified: previous, bytes: 20,
                          chunks: [.init(text: "old", page: nil)], vectors: [semanticVector()])
        let token = AskSearchCancellation(), media = SemanticFixtureMediaEncoder()
        media.before = { _ in token.cancel() }
        #expect(throws: CancellationError.self) {
            try SemanticFileIndexer.run(scope: semanticScope(root.path), store: store, reader: reader,
                                        encoder: SemanticFixtureEncoder(), media: media,
                                        cancelled: { token.isCancelled }, progress: { _ in })
        }
        #expect(try store.unchanged(path: path, modified: previous, bytes: 20))
        #expect(try store.counts().chunks == 1)
        #expect(try FileManager.default.fileExists(atPath: #require(reader.scratch)))
        // Completed private segments survive restart, while committed content stays unchanged.
        let reopened = try SemanticFileStore(url: store.url)
        #expect(try reopened.job(path)?.state == .partial)
        media.before = nil
        let calls = media.calls
        _ = try SemanticFileIndexer.run(scope: semanticScope(root.path), store: reopened, reader: reader,
                                        encoder: SemanticFixtureEncoder(), media: media, cancelled: { false },
                                        progress: { _ in })
        #expect(media.calls == calls + 1, "the already completed first segment is reused")
        #expect(try reopened.job(path)?.state == .done)
        #expect(try !FileManager.default.fileExists(atPath: #require(reader.scratch)))
    }

    @Test func `unreadable media skips one file and model failure remains an error`() throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let reader = SemanticMediaFixtureReader(root: root.path); reader.names = ["bad.png", "good.png"]
        let store = try SemanticFileStore(url: root.appendingPathComponent("index.sqlite"))
        let media = SemanticFixtureMediaEncoder()
        media.before = {
            _ in if reader.current == "bad.png" {
                throw SemanticMediaInputError.unreadable
            }
        }
        let result = try SemanticFileIndexer.run(scope: semanticScope(root.path), store: store, reader: reader,
                                                 encoder: SemanticFixtureEncoder(), media: media, cancelled: { false },
                                                 progress: { _ in })
        #expect(result.files == 1 && result.skipped == 1)
        reader.modified = reader.modified.addingTimeInterval(1)
        media.before = { _ in throw URLError(.cannotLoadFromNetwork) }
        #expect(throws: SemanticMediaFailure.self) {
            try SemanticFileIndexer.run(scope: semanticScope(root.path), store: store, reader: reader,
                                        encoder: SemanticFixtureEncoder(), media: media, cancelled: { false },
                                        progress: { _ in })
        }
        #expect(try store.counts().files == 1)
    }

    @Test func `invalid worker paths changed files and invalid vectors never commit`() throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let reader = SemanticMediaFixtureReader(root: root.path); reader.names = ["image.png"]
        let store = try SemanticFileStore(url: root.appendingPathComponent("index.sqlite"))
        func run() throws -> SemanticFileIndexer.Summary {
            try SemanticFileIndexer.run(scope: semanticScope(root.path), store: store, reader: reader,
                                        encoder: SemanticFixtureEncoder(), media: SemanticFixtureMediaEncoder(),
                                        cancelled: { false },
                                        progress: { _ in })
        }
        reader.badPath = true; #expect(try run().skipped == 1)
        reader.badPath = false; reader.changeAfter = true; #expect(try run().skipped == 1)
        #expect(try store.counts().files == 0)
        let metadata = AskFileReadResponse(fileSize: 20, modified: reader.modified)
        let generation = try store.beginMediaJob(path: root.path + "/image.png", metadata: metadata)
        #expect(throws: SemanticFileStore.Failure.self) {
            try store.saveMediaSegment(path: root.path + "/image.png", generation: generation, ordinal: 0,
                                       input: .init(kind: .image, path: "fixture"), vector: [])
        }
        #expect(throws: SemanticFileStore.Failure.self) {
            try store.saveMediaSegment(path: root.path + "/image.png", generation: generation, ordinal: 0,
                                       input: .init(kind: .image, path: "fixture", time: -.infinity),
                                       vector: semanticVector())
        }
    }

    @Test func `idle wait can be cancelled before opening media`() throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let reader = SemanticMediaFixtureReader(root: root.path); reader.names = ["image.png"]
        let store = try SemanticFileStore(url: root.appendingPathComponent("index.sqlite"))
        let token = AskSearchCancellation()
        #expect(throws: CancellationError.self) {
            try SemanticFileIndexer.run(scope: semanticScope(root.path), store: store, reader: reader,
                                        encoder: SemanticFixtureEncoder(), media: SemanticFixtureMediaEncoder(),
                                        idle: { false },
                                        cancelled: { token.isCancelled },
                                        progress: {
                                            if $0.waitingForIdle {
                                                token.cancel()
                                            }
                                        })
        }
        #expect(reader.scratch == nil)
    }

    @Test func `decoder failure retains completed segments across restart`() throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let reader = SemanticMediaFixtureReader(root: root.path)
        reader.names = ["audio.wav"]; reader.pieces = 2; reader.finalFailure = true
        let media = SemanticFixtureMediaEncoder(), url = root.appendingPathComponent("index.sqlite")
        let store = try SemanticFileStore(url: url), path = root.path + "/audio.wav"
        let failed = try SemanticFileIndexer.run(scope: semanticScope(root.path), store: store, reader: reader,
                                                 encoder: SemanticFixtureEncoder(), media: media, cancelled: { false },
                                                 progress: { _ in })
        #expect(failed.skipped == 1 && media.calls == 2)
        #expect(try store.job(path)?.state == .failed && store.job(path)?.reason == "media-extraction-failed")
        #expect(try store.counts().files == 0)
        reader.finalFailure = false
        let reopened = try SemanticFileStore(url: url)
        let result = try SemanticFileIndexer.run(scope: semanticScope(root.path), store: reopened, reader: reader,
                                                 encoder: SemanticFixtureEncoder(), media: media, cancelled: { false },
                                                 progress: { _ in })
        #expect(result.files == 1 && media.calls == 2)
        #expect(try reopened.counts().chunks == 2)
        #expect(try reopened.job(path)?.state == .done && reopened.job(path)?.attempts == 1)
    }
}
