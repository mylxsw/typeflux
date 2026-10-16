import CoreGraphics
import CoreText
import Darwin
import Foundation
import SQLite3
import Testing
@testable import Typeflux

private final class RecoveryBundle: NSObject {}

private final class RecoveryReader: AskFileReading {
    var textReads = 0
    var maximumBytes = 0
    var before: ((AskFileReadRequest) throws -> Void)?
    var transform: ((AskFileReadRequest, inout AskFileReadResponse) -> Void)?
    func read(_ request: AskFileReadRequest, isCancelled: () -> Bool) throws -> AskFileReadResponse {
        if isCancelled() {
            throw CancellationError()
        }
        try before?(request)
        var result = AskFileWorkerCommand.handle(request)
        transform?(request, &result)
        if request.operation == .content, request.readText {
            textReads += 1
            maximumBytes = max(maximumBytes, result.pages?.reduce(0) { $0 + $1.text.utf8.count } ?? 0)
        }
        return result
    }
}

private final class RecoveryEncoder: SemanticEmbedding {
    var calls = 0
    var texts = 0
    var before: (() throws -> Void)?
    func embed(_ values: [String], cancelled: () -> Bool) throws -> [[Float]] {
        if cancelled() {
            throw CancellationError()
        }
        calls += 1; texts += values.count
        try before?()
        return values.map { _ in semanticVector() }
    }
}

@Suite("Durable semantic checkpoints and failure recovery", .serialized)
struct SemanticIndexRecoveryTests {
    private func run(_ root: URL, _ store: SemanticFileStore, _ reader: AskFileReading,
                     _ encoder: SemanticEmbedding, cancelled: () -> Bool = { false }) throws -> SemanticFileIndexer
        .Summary {
        try SemanticFileIndexer.run(scope: semanticScope(root.path), store: store, reader: reader,
                                    encoder: encoder, cancelled: cancelled, progress: { _ in })
    }

    private func hits(_ store: SemanticFileStore, _ root: URL, _ text: String) throws -> [AskFileHit] {
        try store.lexicalSearch(text: text, query: .init(text), type: .all,
                                scope: semanticScope(root.path), limit: 5, cancelled: { false })
    }

    private func execute(_ url: URL, _ sql: String) throws {
        var db: OpaquePointer?
        try #require(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        try #require(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
    }

    @Test(arguments: [90000, 160_000, 16 * 1024 * 1024 + 4096])
    func `tails beyond every old text limit finish without unbounded reads`(size: Int) throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("long.txt")
        // Repeated words avoid a synthetic unbounded token in the FTS tokenizer.
        let text = String(repeating: "project notes. ", count: size / 15) + " tailmarkerzebra"
        try text.write(to: file, atomically: true, encoding: .utf8)
        let store = try SemanticFileStore(url: root.appendingPathComponent("index.sqlite"))
        let reader = RecoveryReader(), encoder = RecoveryEncoder()
        let result = try run(root, store, reader, encoder)
        #expect(result.files == 1 && result.skipped == 0)
        #expect(try store.job(file.path)?.state == .done)
        #expect(try store.counts().chunks > 64)
        #expect(try hits(store, root, "tailmarkerzebra").map(\.path) == [file.path])
        #expect(reader.maximumBytes <= SemanticFilePolicy.contentBatchBytes)
        let calls = encoder.calls, reads = reader.textReads
        _ = try run(root, SemanticFileStore(url: store.url), reader, encoder)
        #expect(
            encoder.calls == calls && reader.textReads == reads,
            "restart never repeats committed extraction or encoding"
        )
    }

    @Test func `pdf beyond five hundred pages and page internal checkpoint`() throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("long.pdf")
        var box = CGRect(x: 0, y: 0, width: 500, height: 400)
        let context = try #require(CGContext(file as CFURL, mediaBox: &box, nil))
        for page in 0 ..< 503 {
            context.beginPDFPage(nil); context.textPosition = .init(x: 20, y: 100)
            let text = NSAttributedString(string: page == 502 ? "pdfzebratail" : "page body", attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName(
                    "Helvetica" as CFString,
                    14,
                    nil
                )
            ])
            CTLineDraw(CTLineCreateWithAttributedString(text), context); context.endPDFPage()
        }
        context.closePDF()
        let store = try SemanticFileStore(url: root.appendingPathComponent("index.sqlite"))
        _ = try run(root, store, RecoveryReader(), RecoveryEncoder())
        #expect(try hits(store, root, "pdfzebratail").first?.evidence?.page == 503)
        #expect(try store.job(file.path)?.state == .done)
        // A single giant PDF text page also continues inside that page, without advancing early.
        let fixture = SemanticPage(text: String(repeating: "page text ", count: 5000), page: 1)
        let bytes = Data(fixture.text.utf8)
        let part = try #require(AskFileWorkerCommand.contentSlice(bytes, offset: 0))
        #expect(part.consumed < bytes.count && part.text.utf8.count <= SemanticFilePolicy.contentBatchBytes)
        let next = try #require(AskFileWorkerCommand.contentSlice(bytes, offset: part.consumed))
        #expect(!next.text.isEmpty)
    }

    @Test func `fts precedes vectors and cancellation resumes only missing batches`() throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("long.txt")
        try ("firstzebra " + String(repeating: "project notes ", count: 20000) + " tailzebra").write(
            to: file,
            atomically: true,
            encoding: .utf8
        )
        let url = root.appendingPathComponent("index.sqlite"), reader = RecoveryReader(), encoder = RecoveryEncoder()
        var store: SemanticFileStore? = try SemanticFileStore(url: url)
        let token = AskSearchCancellation()
        encoder.before = {
            if encoder.calls == 1 {
                #expect(
                    try hits(store!, root, "firstzebra").count == 1,
                    "FTS must be visible before any vector is returned"
                )
                #expect(try store!.job(file.path)?.state == .partial)
            }
            if encoder.calls == 2 {
                token.cancel(); throw CancellationError()
            }
        }
        #expect(throws: CancellationError.self) { try run(
            root,
            #require(store),
            reader,
            encoder,
            cancelled: { token.isCancelled }
        ) }
        #expect(try store?.job(file.path)?.state == .partial)
        let interruptedJob = try store?.job(file.path)
        let firstGeneration = try #require(interruptedJob?.generation)
        let prior = encoder.texts - 8
        store = nil
        let reopened = try SemanticFileStore(url: url), recovery = RecoveryEncoder()
        _ = try run(root, reopened, reader, recovery)
        #expect(try reopened.job(file.path)?.generation == firstGeneration)
        #expect(try reopened.job(file.path)?.state == .done)
        #expect(try hits(reopened, root, "tailzebra").count == 1)
        #expect(try recovery.texts + prior == (reopened.counts().chunks))
    }

    @Test func `round robin lets small file finish before long file`() throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let long = root.appendingPathComponent("a-long.txt"), small = root.appendingPathComponent("z-small.txt")
        try String(repeating: "long document ", count: 20000).write(to: long, atomically: true, encoding: .utf8)
        try "smallzebra".write(to: small, atomically: true, encoding: .utf8)
        let store = try SemanticFileStore(url: root.appendingPathComponent("index.sqlite")), encoder = RecoveryEncoder()
        var checked = false
        encoder.before = {
            if try store.job(small.path)?.state == .done {
                #expect(try store.job(long.path)?.state == .partial)
                checked = true
            }
        }
        _ = try run(root, store, RecoveryReader(), encoder)
        #expect(checked)
    }

    @Test(arguments: ["fts", "vector"])
    func `disk and transaction failure roll back checkpoint and retry without duplicates`(stage: String) throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("note.txt")
        try "transactionzebra".write(to: file, atomically: true, encoding: .utf8)
        let url = root.appendingPathComponent("index.sqlite"), store = try SemanticFileStore(url: url)
        let action = stage == "fts" ? "INSERT" : "UPDATE OF vector"
        // FTS virtual tables cannot own triggers; fail chunk INSERT to roll back its whole FTS/checkpoint batch.
        try execute(
            url,
            "CREATE TRIGGER fail_write BEFORE \(stage == "fts" ? "INSERT" : action) ON chunks BEGIN SELECT RAISE(FAIL,'injected'); END"
        )
        #expect(throws: SemanticFileStore.Failure.self) { try run(root, store, RecoveryReader(), RecoveryEncoder()) }
        #expect(try store.job(file.path)?.state == (stage == "fts" ? .pending : .partial))
        #expect(try store.counts().chunks == (stage == "fts" ? 0 : 1))
        try execute(url, "DROP TRIGGER fail_write")
        _ = try run(root, SemanticFileStore(url: url), RecoveryReader(), RecoveryEncoder())
        #expect(try store.counts().chunks == 1)
        #expect(try store.job(file.path)?.state == .done)
        #expect(try hits(store, root, "transactionzebra").count == 1)
    }

    @Test func `timeout is durable retried and does not block other files or prune`() throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let bad = root.appendingPathComponent("bad.txt"), good = root.appendingPathComponent("good.txt")
        try "retryzebra".write(to: bad, atomically: true, encoding: .utf8)
        try "goodzebra".write(to: good, atomically: true, encoding: .utf8)
        let store = try SemanticFileStore(url: root.appendingPathComponent("index.sqlite")), reader = RecoveryReader()
        try store.replace(path: root.path + "/deleted.txt", modified: Date(), bytes: 10,
                          chunks: [.init(text: "stalezebra", page: nil)], vectors: [semanticVector()])
        reader.before = {
            if $0.path == bad.path, $0.readText {
                throw AskFileReadError.timeout
            }
        }
        let result = try run(root, store, reader, RecoveryEncoder())
        #expect(result.files == 1 && result.skipped == 1)
        #expect(try store.job(bad.path)?.state == .failed && store.job(bad.path)?.reason == "reader-failed")
        #expect(try hits(store, root, "stalezebra").isEmpty)
        reader.before = nil
        _ = try run(root, store, reader, RecoveryEncoder())
        #expect(try store.job(bad.path)?.state == .done && store.job(bad.path)?.attempts == 1)
    }

    @Test(arguments: ["rewrite", "delete", "permission"])
    func `mutation during inference cannot publish old content`(action: String) throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("note.txt")
        try "oldzebra".write(to: file, atomically: true, encoding: .utf8)
        let store = try SemanticFileStore(url: root.appendingPathComponent("index.sqlite"))
        let reader = RecoveryReader(), encoder = RecoveryEncoder()
        var revoked = false
        reader.before = {
            request in if revoked, request.path == file.path {
                throw POSIXError(.EACCES)
            }
        }
        encoder.before = {
            if action == "rewrite" {
                try "newzebra".write(to: file, atomically: true, encoding: .utf8)
            }
            if action == "delete" {
                try FileManager.default.removeItem(at: file)
            }
            if action == "permission" {
                revoked = true
            }
        }
        _ = try run(root, store, reader, encoder)
        // The service's metadata validator is also required when revocation races with the writer.
        let candidates = try hits(store, root, "oldzebra")
        #expect(SemanticFileValidator(reader: reader).validate(
            candidates,
            scope: semanticScope(root.path),
            limit: 5,
            cancelled: { false }
        ).isEmpty)
        #expect(candidates.isEmpty)
        revoked = false; encoder.before = nil
        if action != "delete" {
            _ = try run(root, store, reader, encoder)
            #expect(try store.job(file.path)?.state == .done)
        }
    }

    @Test func `generations reject stale responses and rename reencodes title`() throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let old = root.appendingPathComponent("old.txt"), renamed = root.appendingPathComponent("renamed.txt")
        try "renamezebra".write(to: old, atomically: true, encoding: .utf8)
        let store = try SemanticFileStore(url: root.appendingPathComponent("index.sqlite")), reader = RecoveryReader()
        let meta = try reader.read(
            .init(operation: .content, path: old.path, scope: semanticScope(root.path), readText: false),
            isCancelled: { false }
        )
        let stale = try store.prepareDocument(path: old.path, metadata: meta)
        try store.remove(old.path)
        let fresh = try store.prepareDocument(path: old.path, metadata: meta)
        #expect(stale.generation != fresh.generation)
        #expect(try !store.publish([.init(text: "stale", page: nil)], next: nil, job: stale))
        #expect(try !store.publishVectors([semanticVector()], work: [.init(id: 1, text: "stale")], job: stale))
        let encoder = RecoveryEncoder()
        _ = try run(root, store, reader, encoder)
        try FileManager.default.moveItem(at: old, to: renamed)
        let result = try SemanticFileIndexer.reconcile(
            paths: [old.path, renamed.path, renamed.path],
            scope: semanticScope(root.path),
            store: store,
            reader: reader,
            encoder: encoder,
            cancelled: { false },
            progress: { _ in }
        )
        #expect(result.processed == 2 && encoder.calls == 2)
        #expect(try hits(store, root, "renamezebra").map(\.path) == [renamed.path])
        #expect(try store.publishVectors([], work: [], job: fresh) == false)
        #expect(throws: SemanticFileStore.Failure.self) { try store.publishVectors(
            [[]],
            work: [.init(id: 1, text: "")],
            job: fresh
        ) }
    }

    @Test func `failed directory protects only its subtree and empty files do not block prune`() throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let restricted = root.appendingPathComponent("restricted")
        try FileManager.default.createDirectory(at: restricted, withIntermediateDirectories: true)
        try "".write(to: root.appendingPathComponent("empty.txt"), atomically: true, encoding: .utf8)
        let store = try SemanticFileStore(url: root.appendingPathComponent("index.sqlite")), reader = RecoveryReader()
        for path in [restricted.path + "/unconfirmed.txt", root.path + "/deleted.txt"] {
            try store.replace(path: path, modified: Date(), bytes: 10,
                              chunks: [.init(text: "prunezebra", page: nil)], vectors: [semanticVector()])
        }
        reader.before = {
            if $0.operation == .directory, $0.path == restricted.path {
                throw AskFileReadError.timeout
            }
        }
        _ = try run(root, store, reader, RecoveryEncoder())
        #expect(try hits(store, root, "prunezebra").map(\.path) == [restricted.path + "/unconfirmed.txt"])
        #expect(try store.job(root.path + "/empty.txt")?.reason == "empty-or-no-text")
        reader.before = nil
        _ = try run(root, store, reader, RecoveryEncoder())
        #expect(try hits(store, root, "prunezebra").isEmpty)
    }

    @Test func `compatible migration retains vectors and interrupted migration rolls back`() throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("legacy.sqlite")
        try execute(url, """
        CREATE TABLE profile(value TEXT NOT NULL);
        INSERT INTO profile VALUES('\(SemanticFilePolicy.profile)');
        CREATE TABLE files(path TEXT PRIMARY KEY,modified REAL NOT NULL,bytes INTEGER NOT NULL);
        CREATE TABLE chunks(id INTEGER PRIMARY KEY,path TEXT NOT NULL REFERENCES files(path) ON DELETE CASCADE,text TEXT NOT NULL,page INTEGER,vector BLOB NOT NULL);
        INSERT INTO files VALUES('/legacy.txt',100,10);
        INSERT INTO chunks(path,text,vector) VALUES('/legacy.txt','legacy',zeroblob(3072));
        """)
        // Crash in a real SQLite DDL transaction before the application opens the legacy database.
        let interrupted = Process()
        interrupted.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        interrupted.arguments = ["python3", "-c", """
        import os, sqlite3, sys
        connection = sqlite3.connect(sys.argv[1])
        connection.execute('BEGIN IMMEDIATE')
        connection.execute("ALTER TABLE files ADD COLUMN version TEXT NOT NULL DEFAULT ''")
        connection.execute('ALTER TABLE chunks ADD COLUMN time REAL')
        os._exit(74)
        """, url.path]
        interrupted.standardOutput = FileHandle.nullDevice; interrupted.standardError = FileHandle.nullDevice
        try interrupted.run(); interrupted.waitUntilExit()
        #expect(interrupted.terminationStatus == 74)
        let store = try SemanticFileStore(url: url)
        while try store.maintainSearchBatch(cancelled: { false }) {}
        #expect(try store.counts().chunks == 1, "compatible migration preserves old payloads after DDL rollback")
        let reopened = try SemanticFileStore(url: url)
        #expect(try reopened.counts().chunks == 1)
        let reset = try SemanticFileStore(url: url, profile: "incompatible")
        while try reset.maintainSearchBatch(cancelled: { false }) {}
        #expect(try reset.counts().chunks == 0)
    }

    @Test func `invalid cursors UTF 8 and long combining characters cannot loop or lose tail`() throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("unicode.txt"), scope = semanticScope(root.path)
        try (String(repeating: "中é", count: 15000) + " finalunicodezebra").write(
            to: file,
            atomically: true,
            encoding: .utf8
        )
        let reader = AskFileReader()
        var cursor: SemanticContentCursor?, iterations = 0
        repeat {
            let response = try reader.read(.init(operation: .content, path: file.path, scope: scope, cursor: cursor))
            #expect(response.error == nil && response.version != nil)
            #expect(response.pages?.first?.text.utf8.count ?? 0 <= SemanticFilePolicy.contentBatchBytes)
            cursor = response.nextCursor; iterations += 1
        } while cursor != nil && iterations < 10
        #expect(cursor == nil && iterations >= 3)
        for cursor in [SemanticContentCursor(page: -1), .init(offset: -1), .init(offset: 999_999)] {
            #expect(AskFileWorkerCommand.handle(.init(
                operation: .content,
                path: file.path,
                scope: scope,
                cursor: cursor
            )).error == EINVAL)
        }
        #expect(AskFileWorkerCommand.contentSlice(Data([0xFF]), offset: 0) == nil)
    }

    @Test func `abrupt process exit recovers committed batches`() throws {
        let env = ProcessInfo.processInfo.environment
        if let childRoot = env["TYPEFLUX_CHECKPOINT_CRASH_ROOT"] {
            let root = URL(fileURLWithPath: childRoot)
            let store = try SemanticFileStore(url: root.appendingPathComponent("crash.sqlite"))
            let encoder = RecoveryEncoder()
            encoder.before = {
                if encoder.calls == 2 {
                    _exit(73)
                }
            }
            _ = try run(root, store, RecoveryReader(), encoder)
            Issue.record("crash injection did not execute")
            return
        }
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        try String(repeating: "crash recovery text ", count: 10000).write(
            to: root.appendingPathComponent("note.txt"),
            atomically: true,
            encoding: .utf8
        )
        let bundle = Bundle(for: RecoveryBundle.self)
        let fallback = bundle.bundleURL
            .appendingPathComponent("Contents/MacOS/" + bundle.bundleURL.deletingPathExtension().lastPathComponent)
        let binary = CommandLine.arguments.first { $0.contains(".xctest/Contents/MacOS/") }
            .map { URL(fileURLWithPath: $0) } ?? fallback
        let developer = Process(), pipe = Pipe()
        developer.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        developer.arguments = ["-p"]; developer.standardOutput = pipe
        try developer.run(); developer.waitUntilExit()
        let directory = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let process = Process()
        process
            .executableURL =
            URL(fileURLWithPath: directory +
                "/Toolchains/XcodeDefault.xctoolchain/usr/libexec/swift/pm/swiftpm-testing-helper")
        process.arguments = [
            "--test-bundle-path",
            binary.path,
            "--testing-library",
            "swift-testing",
            "--no-parallel",
            "--filter",
            "SemanticIndexRecoveryTests/.*" + NSRegularExpression.escapedPattern(for: #function.replacingOccurrences(
                of: "()",
                with: ""
            ))
        ]
        var childEnvironment = env
        childEnvironment["TYPEFLUX_CHECKPOINT_CRASH_ROOT"] = root.path
        childEnvironment["LLVM_PROFILE_FILE"] = root.appendingPathComponent("crash-%p.profraw").path
        process.environment = childEnvironment
        let log = root.appendingPathComponent("crash-child.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let output = try FileHandle(forWritingTo: log)
        defer { try? output.close() }
        process.standardOutput = output; process.standardError = output
        try process.run(); process.waitUntilExit()
        let detail = try String(decoding: Data(contentsOf: log), as: UTF8.self)
        #expect(process.terminationStatus == 73, "Child recovery runner (\(binary.lastPathComponent)): \(detail)")
        let store = try SemanticFileStore(url: root.appendingPathComponent("crash.sqlite"))
        let checkpoint = try store.job(root.path + "/note.txt")
        let before = try #require(checkpoint)
        #expect(before.state == .partial)
        let encoder = RecoveryEncoder()
        _ = try run(root, store, RecoveryReader(), encoder)
        #expect(try store.job(before.path)?.state == .done)
        #expect(try encoder.texts + 8 == (store.counts().chunks), "the eight committed vectors survive _exit")
    }

    @Test func `sqlite full rolls back FTS and checkpoint and can resume`() throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("full.txt")
        try "diskfullzebra".write(to: file, atomically: true, encoding: .utf8)
        let store = try SemanticFileStore(url: root.appendingPathComponent("index.sqlite"))
        let metadata = AskFileWorkerCommand.handle(.init(
            operation: .content,
            path: file.path,
            scope: semanticScope(root.path),
            readText: false
        ))
        let job = try store.prepareDocument(path: file.path, metadata: metadata)
        try store.lock.withLock {
            let row = try store.statement("PRAGMA page_count")
            defer { sqlite3_finalize(row) }
            try #require(sqlite3_step(row) == SQLITE_ROW)
            try store.sql("PRAGMA max_page_count=\(sqlite3_column_int64(row, 0))")
        }
        let chunks = SemanticChunk.make([.init(text: String(repeating: "diskfullzebra ", count: 3000))])
        #expect(throws: SemanticFileStore.Failure.self) { try store.publish(chunks, next: nil, job: job) }
        #expect(try store.job(file.path)?.state == .pending)
        #expect(try store.counts().chunks == 0)
        try store.lock.withLock { try store.sql("PRAGMA max_page_count=1000000") }
        #expect(try store.publish(chunks, next: nil, job: job))
        #expect(try !store.publish(chunks, next: nil, job: job), "same extraction response cannot be committed twice")
        let first = try store.vectorWork(job)
        #expect(first.count == 8)
        #expect(try store.publishVectors(first.map { _ in semanticVector() }, work: first, job: job))
        #expect(try store.publishVectors(first.map { _ in semanticVector() }, work: first, job: job))
        #expect(try store.vectorWork(job).first?.id != first.first?.id)
    }

    @Test func `media metadata and recipe invalidate only incompatible checkpoints`() throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let path = root.path + "/movie.mov",
            store = try SemanticFileStore(url: root.appendingPathComponent("index.sqlite"))
        let metadata = AskFileReadResponse(fileSize: 10, modified: Date(timeIntervalSince1970: 100), version: "v1")
        let first = try store.beginMediaJob(path: path, metadata: metadata)
        let input = SemanticMediaInput(kind: .audio, path: "fixture", time: 30, endTime: 42)
        try store.saveMediaSegment(path: path, generation: first, ordinal: 0, input: input, vector: semanticVector())
        #expect(try store.hasMediaSegment(path: path, generation: first, ordinal: 0))
        try store.failJob(path, reason: "media-encoding-failed")
        #expect(try store.beginMediaJob(path: path, metadata: metadata) == first)
        #expect(try store.job(path)?.attempts == 1)
        for end in [29.0, Double.infinity] {
            #expect(throws: SemanticFileStore.Failure.self) {
                try store.saveMediaSegment(path: path, generation: first, ordinal: 1,
                                           input: .init(kind: .audio, path: "fixture", time: 30, endTime: end),
                                           vector: semanticVector())
            }
        }
        try execute(store.url, "UPDATE media_jobs SET recipe='old-projector'")
        let second = try store.beginMediaJob(path: path, metadata: metadata)
        #expect(second != first)
        #expect(try !store.hasMediaSegment(path: path, generation: second, ordinal: 0))
        try store.saveMediaSegment(path: path, generation: second, ordinal: 0, input: input, vector: semanticVector())
        #expect(try store.commitMediaJob(path: path, generation: second, metadata: metadata, segments: 1))
        #expect(try store.mediaUnchanged(path: path, metadata: metadata))
        try store.lock.withLock {
            let row = try store
                .statement("SELECT time,end_time,modality,segment_kind,provenance FROM chunks WHERE path=?")
            defer { sqlite3_finalize(row) }
            store.bind(row, [path])
            try #require(sqlite3_step(row) == SQLITE_ROW)
            #expect(sqlite3_column_double(row, 0) == 30 && sqlite3_column_double(row, 1) == 42)
            #expect(store.string(row, 2) == "audio" && store.string(row, 3) == "audio-window")
            #expect(store.string(row, 4) == SemanticFileStore.mediaProvenance)
        }
        func vectorHits() throws -> [AskFileHit] {
            try store.search(vector: semanticVector(), text: "compatibility", query: .init("compatibility"),
                             type: .all, scope: semanticScope(root.path), limit: 5, cancelled: { false })
        }
        #expect(try vectorHits().map(\.path) == [path])
        try execute(store.url, "UPDATE chunks SET provenance='old-projector'")
        #expect(try !store.mediaUnchanged(path: path, metadata: metadata))
        #expect(try vectorHits().isEmpty, "incompatible media stays hidden while paused or rebuilding")
        try store.replace(path: root.path + "/legacy.txt", modified: Date(), bytes: 10,
                          chunks: [.init(text: "legacy", page: nil)], vectors: [semanticVector()])
        try store.replace(path: root.path + "/legacy.png", modified: Date(), bytes: 10,
                          chunks: [.init(text: "legacy", page: nil)], vectors: [semanticVector()])
        #expect(try vectorHits().map(\.path) == [root.path + "/legacy.txt"],
                "compatible legacy documents survive; unknown media projectors require rebuild")
    }

    @Test(arguments: [Int32(EILSEQ), EACCES, ENOENT, EAGAIN, -1])
    func `corrupt files and malformed worker checkpoints do not block prune or recovery`(code: Int32) throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("bad.txt"), good = root.appendingPathComponent("good.txt")
        try "badzebrabody".write(to: file, atomically: true, encoding: .utf8)
        if code == EILSEQ {
            try Data([0, 1, 2]).write(to: file)
        }
        try "goodzebrabody".write(to: good, atomically: true, encoding: .utf8)
        let store = try SemanticFileStore(url: root.appendingPathComponent("index.sqlite")), reader = RecoveryReader()
        try store.replace(path: root.path + "/deleted.txt", modified: Date(), bytes: 10,
                          chunks: [.init(text: "deletedzebra", page: nil)], vectors: [semanticVector()])
        reader.transform = { request, response in
            if request.path == file.path, request.readText {
                if code == -1 {
                    response.nextCursor = request.cursor ?? .init()
                } else if code != EILSEQ {
                    response.error = code
                }
            }
        }
        let result = try run(root, store, reader, RecoveryEncoder())
        #expect(result.files == 1 && result.skipped == 1)
        #expect(try hits(store, root, "deletedzebra").isEmpty)
        #expect(try hits(store, root, "badzebrabody").isEmpty)
        if code == EACCES {
            #expect(try store.job(file.path)?.reason == "permission-denied")
        }
        if code == ENOENT || code == EAGAIN {
            #expect(try store.job(file.path)?.reason == "file-missing-or-changed")
        }
        if code == EILSEQ || code == -1 {
            #expect(try store.job(file.path)?.state == .failed)
            #expect(try store.job(file.path)?.reason == (code == EILSEQ ? "unreadable-content" : "reader-failed"))
        }
        reader.transform = nil
        try "recoveredzebra".write(to: file, atomically: true, encoding: .utf8)
        _ = try run(root, store, reader, RecoveryEncoder())
        #expect(try store.job(file.path)?.state == .done)
        var revokedScope = semanticScope(root.path); revokedScope.excludedPaths = [file.path]
        _ = try SemanticFileIndexer.reconcile(paths: [file.path], scope: revokedScope, store: store, reader: reader,
                                              encoder: RecoveryEncoder(), cancelled: { false }, progress: { _ in })
        #expect(try hits(store, root, "recoveredzebra").isEmpty)
    }

    @Test func `pdf single page text can continue with stable page offsets`() throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("single-page.pdf")
        var box = CGRect(x: 0, y: 0, width: 500, height: 8000)
        let context = try #require(CGContext(file as CFURL, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        let font = CTFontCreateWithName("Helvetica" as CFString, 3, nil)
        for line in 0 ..< 1800 {
            context.textPosition = .init(x: 20, y: 7800 - Double(line * 4))
            let text = NSAttributedString(
                string: line == 1799 ? "singlepagetailzebra" :
                    "PDF page body line \(line) has complete checkpoint text.",
                attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]
            )
            CTLineDraw(CTLineCreateWithAttributedString(text), context)
        }
        context.endPDFPage(); context.closePDF()
        let scope = semanticScope(root.path), reader = RecoveryReader()
        let first = try reader.read(.init(operation: .content, path: file.path, scope: scope), isCancelled: { false })
        let next = try #require(first.nextCursor)
        #expect(next.page == 0 && next.offset > 0)
        #expect(first.pages?.first?.text.utf8.count ?? 0 <= SemanticFilePolicy.contentBatchBytes)
        let eof = try reader.read(
            .init(operation: .content, path: file.path, scope: scope, cursor: .init(page: 1)),
            isCancelled: { false }
        )
        #expect(eof.pages == [] && eof.nextCursor == nil)
        let store = try SemanticFileStore(url: root.appendingPathComponent("index.sqlite"))
        _ = try run(root, store, reader, RecoveryEncoder())
        #expect(try hits(store, root, "singlepagetailzebra").first?.evidence?.page == 1)
        #expect(try store.job(file.path)?.state == .done)
        #expect(reader.maximumBytes <= SemanticFilePolicy.contentBatchBytes)
    }

    @Test func `pending and failed jobs count only published files`() throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try SemanticFileStore(url: root.appendingPathComponent("index.sqlite"))
        let path = root.path + "/pending.txt"
        var metadata = AskFileReadResponse(fileSize: 20, modified: Date(timeIntervalSince1970: 100), version: "one")
        _ = try store.prepareDocument(path: path, metadata: metadata)
        #expect(try store.counts().files == 0 && store.counts().chunks == 0)
        try store.failJob(path, reason: "reader-failed")
        #expect(try store.counts().files == 0)
        let retry = try store.prepareDocument(path: path, metadata: metadata)
        #expect(try store.publish([.init(text: "partialzebra", page: nil)], next: .init(offset: 10), job: retry))
        #expect(try store.counts().documents == 1 && store.counts().chunks == 1)
        metadata.version = "two"
        _ = try store.prepareDocument(path: path, metadata: metadata)
        #expect(try store.counts().files == 0 && store.counts().chunks == 0)
    }
}
