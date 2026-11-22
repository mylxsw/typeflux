import Foundation
import Testing
@testable import Typeflux

private final class InterleavingEncoder: SemanticEmbedding {
    var before: (([String]) throws -> Void)?
    private(set) var isWarm = false
    func embed(_ texts: [String], cancelled: () -> Bool) throws -> [[Float]] {
        if cancelled() {
            throw CancellationError()
        }
        try before?(texts)
        isWarm = true
        return texts.map { _ in semanticVector() }
    }
    func release() { isWarm = false }
}

@Suite("Live document fairness on the durable queue", .serialized)
struct SemanticIndexFairnessTests {
    @Test(arguments: [false, true])
    func documentHelperSurvivesBatchRotationWithNoMediaInference(cachedImages: Bool) throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let scope = semanticScope(root.path), reader = SemanticMediaFixtureReader(root: root.path)
        let store = try SemanticFileStore(url: root.appendingPathComponent("index.sqlite"))
        let media = SemanticFixtureMediaEncoder()
        let images = cachedImages ? (0 ..< 3).map { "image-\($0).png" } : []
        if cachedImages {
            _ = try SemanticFileIndexer.reconcile(paths: images.map { root.appendingPathComponent($0).path },
                                                   scope: scope, store: store,
                                                   reader: reader, encoder: SemanticFixtureEncoder(), media: media,
                                                   cancelled: { false }, progress: { _ in })
            media.release()
        }
        reader.names = (0 ..< 12).map { "note-\($0).txt" } + images
        let launches = root.appendingPathComponent("launches")
        func quoted(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let marker = "printf '%s\\n' \"$$\" >> \(quoted(launches.path))\n"
        let worker: SemanticEmbeddingWorker
        if let path = ProcessInfo.processInfo.environment["TYPEFLUX_SEMANTIC_TEST_MODEL"] {
            let shim = root.appendingPathComponent("record-helper")
            try ("#!/bin/sh\n" + marker + "exec \(quoted(SemanticModel.helperURL.path)) \"$@\"\n")
                .write(to: shim, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: shim.path)
            worker = SemanticEmbeddingWorker(helper: shim, model: URL(fileURLWithPath: path), indexing: true)
        } else {
            let vector = try #require(String(bytes: JSONEncoder().encode([semanticVector()]), encoding: .utf8))
            let script = try SemanticEmbeddingWorkerTests().script(marker + """
            while IFS= read -r line; do printf '%s\\n' '{"entries":[],"embeddings":\(vector)}'; done
            """, in: root)
            worker = SemanticEmbeddingWorker(helper: URL(fileURLWithPath: "/bin/sh"), model: script, indexing: true)
        }
        let budget = SemanticWorkBudget(enabled: true, state: { .init() })
        let started = ProcessInfo.processInfo.systemUptime
        let result = try budget.perform(cancelled: { false }, operation: {
            try SemanticFileIndexer.run(scope: scope, store: store, reader: reader, encoder: worker, media: media,
                                        idle: { Issue.record("Cached media must not wait for idle"); return true },
                                        cancelled: { false }, progress: { _ in })
        })
        let starts = try String(contentsOf: launches, encoding: .utf8).split(separator: "\n").count
        let counts = try store.counts()
        #expect(starts == 1)
        #expect(counts.documents == 12 && counts.images == (cachedImages ? 3 : 0))
        #expect(media.calls == counts.images && result.processed == 12 + counts.images)
        print("SEMANTIC_TEXT_REUSE cached_images=\(counts.images) documents=\(counts.documents) " +
            "helper_starts=\(starts) seconds=\(ProcessInfo.processInfo.systemUptime - started)")
    }

    @Test func enabledBudgetDoesNotDrainTheEntireDocumentBacklogBeforeAnotherMediaSegment() throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try SemanticFileStore(url: root.appendingPathComponent("index.sqlite"))
        let reader = SemanticMediaFixtureReader(root: root.path), mediaEncoder = SemanticFixtureMediaEncoder()
        let media = SemanticMediaWorker(helper: root, model: root, projector: root,
            models: SemanticMediaFixtureModels(source: root), makeEncoder: { _, _, _ in mediaEncoder })
        reader.names = ["video.mov"]; reader.pieces = 2
        let long = root.appendingPathComponent("long.txt"), gate = SemanticIndexPauseGate(),
            encoder = InterleavingEncoder()
        var calls = 0, observed = false
        encoder.before = { _ in calls += 1; gate.enqueueDocuments([long.path]) }
        mediaEncoder.before = { _ in
            #expect(!encoder.isWarm, "The text helper must be released before real media inference")
            if mediaEncoder.calls == 1 {
                try String(repeating: "project body ", count: 20000).write(to: long, atomically: true, encoding: .utf8)
                gate.enqueueDocuments([long.path])
            } else {
                #expect(try store.job(long.path)?.state == .partial)
                #expect(calls <= 2)
                observed = true
            }
        }
        var policy = SemanticWorkBudget.Policy(); policy.quantum = 1000; policy.documentBatches = 2
        let budget = SemanticWorkBudget(policy: policy, enabled: true, state: { .init() })
        _ = try budget.perform(cancelled: { false }, operation: {
            try SemanticFileIndexer.run(scope: semanticScope(root.path), store: store, reader: reader,
                                        encoder: encoder, media: media, documents: { gate.takeDocuments() },
                                        priorityReader: AskFileReader(),
                                        cancelled: { false }, progress: { _ in })
        })
        #expect(observed && calls > 2)
        #expect(try store.job(long.path)?.state == .done)
        #expect(try store.lock.withLock { try store.count("work_queue") } == 0)
    }

    @Test(arguments: [false, true])
    func `continuous events do not drain one long document before the next`(targeted: Bool) throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first.txt"), second = root.appendingPathComponent("second.txt")
        let small = root.appendingPathComponent("small.txt"),
            store = try SemanticFileStore(url: root.appendingPathComponent("index.sqlite"))
        let gate = SemanticIndexPauseGate(), encoder = InterleavingEncoder(), reader = AskFileReader()
        let longBody = String(repeating: "project notes ", count: 22000)
        try longBody.write(to: first, atomically: true, encoding: .utf8)
        var firstCalls = 0, secondCalls = 0, arrivals = 0, observed = false
        encoder.before = { texts in
            if texts[0].hasPrefix("title: first.txt") {
                firstCalls += 1
                if firstCalls == 1 {
                    try longBody.write(to: second, atomically: true, encoding: .utf8)
                    gate.enqueueDocuments([second.path])
                }
            } else if texts[0].hasPrefix("title: second.txt") {
                secondCalls += 1
                if secondCalls == 1 {
                    try "smallzebrabody".write(to: small, atomically: true, encoding: .utf8)
                    gate.enqueueDocuments([small.path])
                }
            }
            // Repeated events for a queued long file must not move it ahead of new arrivals.
            if firstCalls + secondCalls <= 8 {
                gate.enqueueDocuments([second.path, second.path])
            }
        }
        func progress(_: SemanticFileIndexer.Summary) {
            do {
                guard !observed, (try? store.job(small.path)?.state) == .done else { return }
                observed = true
                #expect(try store.job(first.path)?.state == .partial)
                #expect(try store.job(second.path)?.state == .partial)
                #expect(firstCalls <= 4 && secondCalls <= 3, "new work runs within a bounded number of batches")
                #expect(try store.lexicalSearch(text: "smallzebrabody", query: .init("smallzebrabody"), type: .all,
                                                scope: semanticScope(root.path), limit: 5, cancelled: { false })
                        .map(\.path) == [small.path])
                #expect(try store.search(vector: semanticVector(), text: "unrelated", query: .init("unrelated"),
                                         type: .all, scope: semanticScope(root.path), limit: 5, cancelled: { false })
                        .contains { $0.path == small.path })
            } catch { Issue.record(error) }
        }
        let take = { arrivals += 1; return gate.takeDocuments() }
        if targeted {
            _ = try SemanticFileIndexer.reconcile(paths: [first.path], scope: semanticScope(root.path), store: store,
                                                  reader: reader, encoder: encoder, documents: take,
                                                  cancelled: { false }, progress: progress)
        } else {
            _ = try SemanticFileIndexer.run(scope: semanticScope(root.path), store: store,
                                            reader: reader, encoder: encoder, documents: take, cancelled: { false },
                                            progress: progress)
        }
        #expect(observed && arrivals > firstCalls + secondCalls)
        #expect(try store.job(first.path)?.state == .done && store.job(second.path)?.state == .done)
        #expect(try store.counts().files == 3)
        #expect(try store.lock.withLock { try store.count("work_queue") } == 0)
    }

    @Test func `cancellation inside live document drain keeps committed batches for replay`() throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("long.txt"), small = root.appendingPathComponent("small.txt")
        try String(repeating: "project body ", count: 20000).write(to: file, atomically: true, encoding: .utf8)
        let store = try SemanticFileStore(url: root.appendingPathComponent("index.sqlite")),
            encoder = InterleavingEncoder()
        let gate = SemanticIndexPauseGate(), token = AskSearchCancellation()
        var calls = 0
        encoder.before = { _ in
            calls += 1
            if calls == 1 {
                try "resumedzebra".write(to: small, atomically: true, encoding: .utf8)
                gate.enqueueDocuments([small.path])
            }
        }
        #expect(throws: CancellationError.self) {
            try SemanticFileIndexer.reconcile(paths: [file.path], scope: semanticScope(root.path), store: store,
                                              reader: AskFileReader(), encoder: encoder,
                                              documents: { gate.takeDocuments() },
                                              cancelled: { token.isCancelled },
                                              progress: {
                                                  _ in if calls == 2 {
                                                      token.cancel()
                                                  }
                                              })
        }
        #expect(try store.job(file.path)?.state == .partial)
        let generation = try #require(store.job(file.path)?.generation)
        encoder.before = nil
        let reopened = try SemanticFileStore(url: store.url)
        // No new events are needed to resume either queued path.
        _ = try SemanticFileIndexer.reconcile(paths: [], scope: semanticScope(root.path), store: reopened,
                                              reader: AskFileReader(), encoder: encoder, cancelled: { false },
                                              progress: { _ in })
        #expect(try reopened.job(file.path)?.generation == generation && reopened.job(file.path)?.state == .done)
        #expect(try reopened.job(small.path)?.state == .done)
        #expect(try reopened.lock.withLock { try reopened.count("work_queue") } == 0)
    }

    @Test(arguments: [false, true])
    func `media preemption also accepts events between long document batches`(targeted: Bool) throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try SemanticFileStore(url: root.appendingPathComponent("index.sqlite"))
        let reader = SemanticMediaFixtureReader(root: root.path), media = SemanticFixtureMediaEncoder()
        reader.names = ["video.mov"]; reader.pieces = 2
        let long = root.appendingPathComponent("long.txt"), small = root.appendingPathComponent("small.txt")
        let encoder = InterleavingEncoder(), gate = SemanticIndexPauseGate()
        var firstBatch = true, observed = false
        media.before = { _ in
            if media.calls == 1 {
                try String(repeating: "project body ", count: 20000).write(to: long, atomically: true, encoding: .utf8)
                gate.enqueueDocuments([long.path])
            } else {
                #expect(try store.job(long.path)?.state == .done && store.job(small.path)?.state == .done)
            }
        }
        encoder.before = { _ in
            if firstBatch {
                firstBatch = false
                try "mediapreemptzebra".write(to: small, atomically: true, encoding: .utf8)
                gate.enqueueDocuments([small.path])
            }
        }
        func progress(_: SemanticFileIndexer.Summary) {
            do {
                if !observed, (try? store.job(small.path)?.state) == .done {
                    observed = true
                    #expect(try store.job(long.path)?.state == .partial)
                    #expect(media.calls == 1)
                }
            } catch { Issue.record(error) }
        }
        if targeted {
            _ = try SemanticFileIndexer.reconcile(paths: [root.path + "/video.mov"], scope: semanticScope(root.path),
                                                  store: store, reader: reader, encoder: encoder, media: media,
                                                  documents: { gate.takeDocuments() },
                                                  priorityReader: AskFileReader(), cancelled: { false },
                                                  progress: progress)
        } else {
            _ = try SemanticFileIndexer.run(scope: semanticScope(root.path), store: store, reader: reader,
                                            encoder: encoder, media: media, documents: { gate.takeDocuments() },
                                            priorityReader: AskFileReader(), cancelled: { false }, progress: progress)
        }
        #expect(observed && media.calls == 2)
        #expect(try store.counts().files == 3)
    }
}
