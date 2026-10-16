import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import Typeflux

func semanticFixture() throws -> URL {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        .appendingPathComponent("semantic-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return URL(fileURLWithPath: AskFileScope.canonical(root.path))
}

func semanticScope(_ root: String) -> AskFileScope {
    var names = AskLauncherSearchSettings(); names.fileRoots = [root]; names.excludedPaths = []
    return SemanticFilePolicy.scope(names: names, fullDiskAccess: true)
}

func semanticVector(_ index: Int = 0) -> [Float] {
    var vector = [Float](repeating: 0, count: SemanticFilePolicy.dimension); vector[index] = 1; return vector
}

@Suite("Semantic file policy")
struct SemanticFilePolicyTests {
    @Test func `settings default off and round trip`() throws {
        let name = UUID().uuidString, defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = SettingsStore(defaults: defaults)
        #expect(settings.semanticFileSearch == .init())
        settings.semanticFileSearch = .init(enabled: true)
        #expect(SettingsStore(defaults: defaults).semanticFileSearch == .init(enabled: true))
        defaults.set(Data(#"{"enabled":true,"roots":["/old/scope"]}"#.utf8), forKey: "ask.search.semantic")
        #expect(settings.semanticFileSearch == .init(enabled: true), "legacy roots are ignored")
        defaults.set(Data("broken".utf8), forKey: "ask.search.semantic")
        #expect(settings.semanticFileSearch == .init())
    }

    @Test func `queries preserve meaning without name length limit`() {
        #expect(SemanticFilePolicy.query("How can I submit a reimbursement for my project? ext:pdf in:team") ==
            "How can I submit a reimbursement for my project?")
        #expect(SemanticFilePolicy.query("怎么报销？ .pdf") == "怎么报销？")
        for text in ["", ".pdf in:team", "?", "a", "two\nlines", String(repeating: "a", count: 513)] {
            #expect(SemanticFilePolicy.query(text) == nil)
        }
        for type in [AskFileType.folder, .code] {
            #expect(SemanticFilePolicy.query("query", type: type) == nil)
        }
        #expect(SemanticFilePolicy.query("query", type: .pdf) == "query")
    }

    @Test func `explicit scope and credentials are conservative`() {
        var names = AskLauncherSearchSettings()
        names.fileRoots = ["/work"]; names.excludedPaths = ["/work/private"]
        names.excludedExtensions = ["csv"]
        let scope = SemanticFilePolicy.scope(names: names, fullDiskAccess: true)
        #expect(scope.roots == ["/work"])
        #expect(scope.includes("/work/docs/note.md", isDirectory: false))
        #expect(!scope.includes("/work/private/sub/note.md", isDirectory: false))
        #expect(!scope.includes("/work/docs/table.csv", isDirectory: false))
        #expect(!scope.includes("/work/docs/.hidden.txt", isDirectory: false))
        names.includeHidden = true
        #expect(SemanticFilePolicy.scope(names: names, fullDiskAccess: true)
            .includes("/work/docs/.hidden.txt", isDirectory: false))
        names.fileRoots = []
        #expect(SemanticFilePolicy.scope(names: names, fullDiskAccess: true).roots.isEmpty)
        for path in [
            "/work/.env.txt",
            "/work/.ssh/note.txt",
            "/work/credentials.txt",
            "/work/secret.md",
            "/work/a.pem",
            "/work/a.svg",
            "relative.md",
            "/work/../work/a.txt"
        ] {
            #expect(!SemanticFilePolicy.allows(path))
        }
        #expect(SemanticFilePolicy.allows("/work/Notes.MD"))
    }

    @Test func deniedPermissionRemainsVisibleWithoutReadingProtectedRoots() {
        let documents = NSHomeDirectory() + "/Documents"
        var names = AskLauncherSearchSettings()
        names.excludedPaths = []
        names.fileRoots = [documents]
        let scope = SemanticFilePolicy.scope(names: names, fullDiskAccess: false)
        #expect(scope.roots == [documents])
        #expect(scope.blockedInScope == [documents])
        #expect(!scope.includes(documents + "/report.txt", isDirectory: false))
    }

    @Test func `multilingual terms and bounded chunks`() {
        let terms = SemanticFilePolicy.terms("项目报销流程 reimbursement")
        #expect(terms.contains("报销")); #expect(terms.contains("reimbursement"))
        let pages = [
            SemanticPage(text: String(repeating: "项目报销流程。", count: 200), page: 2),
            .init(text: "last page", page: 3)
        ]
        let chunks = SemanticChunk.make(pages)
        #expect(chunks.count > 2); #expect(chunks.allSatisfy { $0.text.utf8.count <= 1200 })
        #expect(chunks.first?.page == 2); #expect(chunks.last?.page == 3)
        #expect(SemanticChunk.make([.init(text: "   \n")]).isEmpty)
        #expect(SemanticChunk.make([.init(text: String(repeating: "a", count: 200_000))]).count > 64)
        #expect(SemanticChunk.make([.init(text: String(repeating: "\u{301}", count: 2000))]).count > 1)
    }
}

@Suite("Semantic SQLite index")
struct SemanticFileStoreTests {
    @Test func `indexed file counts use the same media categories as indexing`() throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("index.sqlite")
        let store = try SemanticFileStore(url: url)
        for name in ["report.MD", "scan.pdf", "cover.PNG", "meeting.m4a", "demo.MOV"] {
            try store.replace(path: root.appendingPathComponent(name).path, modified: Date(), bytes: 10,
                              chunks: [.init(text: name, page: nil)], vectors: [semanticVector()])
        }
        let counts = try store.counts()
        #expect(counts.files == 5 && counts.chunks == 5)
        #expect(counts.documents == 2 && counts.images == 1 && counts.audio == 1 && counts.videos == 1)
        try store.remove(root.appendingPathComponent("cover.PNG").path)
        #expect(try SemanticFileStore(url: url).counts() == .init(documents: 2, audio: 1, videos: 1, chunks: 4))
        try store.clear()
        #expect(try store.counts() == .init())
    }

    @Test func `atomic replace persistence invalidation and pruning`() throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("index.sqlite"), path = root.appendingPathComponent("note.md").path
        let date = Date(timeIntervalSince1970: 100)
        let store = try SemanticFileStore(url: url)
        try store.replace(
            path: path,
            modified: date,
            bytes: 3,
            chunks: [.init(text: "first", page: nil)],
            vectors: [semanticVector()]
        )
        #expect(try store.unchanged(path: path, modified: date, bytes: 3))
        #expect(try !store.unchanged(path: path, modified: date, bytes: 4))
        #expect(try store.counts().chunks == 1)
        #expect(throws: SemanticFileStore.Failure.self) {
            try store.replace(
                path: path,
                modified: date,
                bytes: 5,
                chunks: [.init(text: "bad", page: nil)],
                vectors: [[.nan]]
            )
        }
        #expect(try store.unchanged(path: path, modified: date, bytes: 3))
        try store.replace(
            path: path,
            modified: date,
            bytes: 4,
            chunks: [.init(text: "second", page: 7)],
            vectors: [semanticVector()]
        )
        let reopened = try SemanticFileStore(url: url)
        #expect(try reopened.counts().files == 1)
        #expect(throws: CancellationError.self) { try store.prune(keeping: [], cancelled: { true }) }
        #expect(try store.counts().files == 1)
        try store.prune(keeping: [], cancelled: { false })
        #expect(try reopened.counts().chunks == 0)
        try store.replace(
            path: path,
            modified: date,
            bytes: 4,
            chunks: [.init(text: "new", page: nil)],
            vectors: [semanticVector()]
        )
        let upgraded = try SemanticFileStore(url: url, profile: "new-profile")
        while try upgraded.maintainSearchBatch(cancelled: { false }) {}
        #expect(try upgraded.counts().files == 0)
        try upgraded.clear()
        #expect(try upgraded.counts().chunks == 0)
    }

    @Test func `filters before top K and chinese lexical recall`() throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try SemanticFileStore(url: root.appendingPathComponent("index.sqlite"))
        func add(_ path: String, text: String, vector: [Float]) throws {
            try store.replace(
                path: path,
                modified: Date(),
                bytes: 10,
                chunks: [.init(text: text, page: 4)],
                vectors: [vector]
            )
        }
        try add("/outside/first.md", text: "报销", vector: semanticVector())
        try add(root.path + "/wrong.txt", text: "报销", vector: semanticVector())
        try add(root.path + "/team/handbook.pdf", text: "项目报销流程", vector: semanticVector(1))
        try add(root.path + "/team/credentials.txt", text: "报销", vector: semanticVector())
        let scope = semanticScope(root.path)
        let hits = try store.search(vector: semanticVector(), text: "报销", query: AskSearchQuery("报销 ext:pdf in:team"),
                                    type: .pdf, scope: scope, limit: 1, cancelled: { false })
        #expect(hits.count == 1); #expect(hits.first?.name == "handbook.pdf")
        #expect(hits.first?.match == 0); #expect(hits.first?.evidence?.page == 4)
        #expect(try store.search(vector: semanticVector(), text: "\" OR *", query: .init("nonexistent"), type: .folder,
                                 scope: scope, limit: 10, cancelled: { false }).isEmpty)
        #expect(try store.search(vector: [], text: "报销", query: .init("报销"), type: .all,
                                 scope: scope, limit: 1, cancelled: { false }).isEmpty)
        #expect(throws: CancellationError.self) {
            try store.search(vector: semanticVector(), text: "报销", query: .init("报销"), type: .all,
                             scope: scope, limit: 1, cancelled: { true })
        }
        try store.remove(root.path + "/team/handbook.pdf")
        #expect(try store.search(vector: semanticVector(1), text: "项目", query: .init("项目 ext:pdf"), type: .pdf,
                                 scope: scope, limit: 10, cancelled: { false }).isEmpty)
    }
}

@Suite("Semantic content reader")
struct SemanticFileContentTests {
    @Test func `bounded text metadata and safe paths`() throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("notes.md"), scope = semanticScope(root.path)
        func read(_ path: String? = nil, text: Bool = true) -> AskFileReadResponse {
            AskFileWorkerCommand.handle(.init(
                operation: .content,
                path: path ?? file.path,
                scope: scope,
                readText: text
            ))
        }
        try Data((Array(repeating: "line", count: 250).joined(separator: "\n") + "\nfinal reimbursement").utf8)
            .write(to: file)
        #expect(read().error == nil, "Content path: \(file.path); error: \(String(describing: read().error))")
        #expect(
            read().pages?.first?.text.contains("final reimbursement") == true,
            "content must not inherit preview's 200-line cap"
        )
        #expect(read(text: false).pages == nil); #expect(try #require(read(text: false).fileSize) > 1000)
        #expect(read(root.path + "/missing.md").error != nil)
        #expect(read("/outside/test.md").error == EACCES)
        #expect(read(root.path + "/.env.txt").error == EACCES)
        let link = root.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        #expect(read(link.path).error != nil)
        let directoryLink = root.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: directoryLink, withDestinationURL: root)
        #expect(read(directoryLink.path + "/notes.md").error != nil)
        try Data([0, 1, 2]).write(to: file); #expect(read().error == EILSEQ)
        try Data().write(to: file); #expect(read().pages?.first?.text == "")
        let handle = try FileHandle(forWritingTo: file); try handle
            .truncate(atOffset: UInt64(16 * 1024 * 1024 + 1)); try handle.close()
        #expect(read().error != nil)
        #expect(AskFileWorkerCommand.content(
            .init(operation: .content, path: file.path, scope: scope),
            mounts: .init(excluded: [root.path])
        ).skippedMounts == [root.path])
    }

    @Test func `pdf text layer and subprocess round trip`() throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let pdf = root.appendingPathComponent("manual.pdf"), scope = semanticScope(root.path)
        var box = CGRect(x: 0, y: 0, width: 400, height: 300)
        let context = try #require(CGContext(pdf as CFURL, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        context.textPosition = CGPoint(x: 20, y: 100)
        let text = NSAttributedString(string: "Project reimbursement policy", attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName(
                "Helvetica" as CFString,
                14,
                nil
            )
        ])
        CTLineDraw(CTLineCreateWithAttributedString(text), context)
        context.endPDFPage(); context.closePDF()
        let reader = AskFileReader()
        let result = try reader.read(.init(operation: .content, path: pdf.path, scope: scope))
        #expect(result.error == nil); #expect(result.pages?.first?.page == 1)
        #expect(result.pages?.first?.text.contains("reimbursement") == true)
        let direct = AskFileWorkerCommand.handle(.init(operation: .content, path: pdf.path, scope: scope))
        #expect(direct.pages == result.pages, "the bounded IPC must preserve PDF text and page numbers")
        try Data("invalid pdf".utf8).write(to: pdf)
        #expect(AskFileWorkerCommand.handle(.init(operation: .content, path: pdf.path, scope: scope)).error == EILSEQ)
        #expect(AskFileWorkerCommand.handle(.init(operation: .embedding, path: "")).error == EINVAL)
    }
}

final class SemanticFixtureReader: AskFileReading, @unchecked Sendable {
    var path: String
    var directoryEntries: [AskFileCrawler.Entry]?
    var text = "Project reimbursement policy"
    var modified = Date(timeIntervalSince1970: 100)
    var removed = false
    var failed = false
    var directoryReads = 0
    init(path: String) {
        self.path = path
    }

    func read(_ request: AskFileReadRequest, isCancelled: () -> Bool) throws -> AskFileReadResponse {
        if isCancelled() {
            throw CancellationError()
        }
        if request.operation == .directory {
            directoryReads += 1
            return .init(entries: removed ? [] : directoryEntries ?? [.init(
                path: path,
                kind: .file,
                modified: modified
            )])
        }
        if failed {
            return .init(error: EACCES)
        }
        return .init(fileSize: 20, modified: modified, pages: request.readText ? [.init(text: text)] : nil)
    }
}

final class SemanticFixtureEncoder: SemanticEmbedding, @unchecked Sendable {
    var calls = 0
    var failure = false
    var after: (() -> Void)?
    func embed(_ texts: [String], cancelled _: () -> Bool) throws -> [[Float]] {
        calls += 1
        if failure {
            throw SemanticFileStore.Failure.invalidVector
        }
        after?()
        return texts.map { _ in semanticVector() }
    }
}

@Suite("Semantic incremental indexing")
struct SemanticFileIndexerTests {
    @Test func changedFileReconcilesWithoutCrawlingOrReembeddingItsNeighbors() throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let first = root.path + "/first.md", second = root.path + "/second.md"
        let reader = SemanticFixtureReader(path: first), encoder = SemanticFixtureEncoder()
        reader.directoryEntries = [first, second].map { .init(path: $0, kind: .file, modified: reader.modified) }
        let store = try SemanticFileStore(url: root.appendingPathComponent("index.sqlite"))
        _ = try SemanticFileIndexer.run(scope: semanticScope(root.path), store: store, reader: reader,
                                        encoder: encoder, cancelled: { false }, progress: { _ in })
        #expect(encoder.calls == 2)
        let crawls = reader.directoryReads
        let original = reader.modified
        reader.modified = reader.modified.addingTimeInterval(1)
        let result = try SemanticFileIndexer.reconcile(paths: [second, second], scope: semanticScope(root.path),
                                                       store: store, reader: reader, encoder: encoder,
                                                       cancelled: { false }, progress: { _ in })
        #expect(result.total == 1 && result.processed == 1 && result.files == 1)
        #expect(encoder.calls == 3)
        #expect(reader.directoryReads == crawls)
        #expect(try store.unchanged(path: first, modified: original, bytes: 20))
        #expect(try store.unchanged(path: second, modified: reader.modified, bytes: 20))
        reader.failed = true
        let removed = try SemanticFileIndexer.reconcile(paths: [first], scope: semanticScope(root.path),
                                                        store: store, reader: reader, encoder: encoder,
                                                        cancelled: { false }, progress: { _ in })
        #expect(removed.skipped == 1)
        #expect(try store.counts().files == 1)
        #expect(reader.directoryReads == crawls)
    }

    @Test func unsupportedFilesDoNotConsumeTheSemanticFileLimit() throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let path = root.path + "/notes.md"
        let reader = SemanticFixtureReader(path: path), encoder = SemanticFixtureEncoder()
        reader.directoryEntries = (0 ..< 50000).map {
            .init(path: root.path + "/asset-\($0).bin", kind: .file, modified: reader.modified)
        } + [.init(path: path, kind: .file, modified: reader.modified)]
        let store = try SemanticFileStore(url: root.appendingPathComponent("index.sqlite"))
        var progress: [SemanticFileIndexer.Summary] = []
        let result = try SemanticFileIndexer.run(scope: semanticScope(root.path), store: store, reader: reader,
                                                 encoder: encoder, cancelled: { false },
                                                 progress: { progress.append($0) })
        #expect(result.files == 1)
        #expect(result.scanned == 50001 && result.discovered == 1)
        #expect(result.total == 1 && result.processed == 1)
        #expect(progress.contains { $0.total == nil && $0.scanned >= 1000 })
        #expect(progress.contains { $0.total == 1 && $0.processed == 0 })
        #expect(try store.counts().files == 1)
    }

    @Test func emptyOrScannedContentIsSkippedWithoutLoadingModel() throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let reader = SemanticFixtureReader(path: root.path + "/scan.pdf"), encoder = SemanticFixtureEncoder()
        reader.text = "   \n"
        let store = try SemanticFileStore(url: root.appendingPathComponent("index.sqlite"))
        let result = try SemanticFileIndexer.run(scope: semanticScope(root.path), store: store, reader: reader,
                                                 encoder: encoder, cancelled: { false }, progress: { _ in })
        #expect(result.files == 0); #expect(result.skipped == 1)
        #expect(encoder.calls == 0); #expect(try store.counts().files == 0)
    }

    @Test func `changes deletion failures and cancellation`() throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let reader = SemanticFixtureReader(path: root.path + "/handbook.txt"), encoder = SemanticFixtureEncoder()
        let store = try SemanticFileStore(url: root.appendingPathComponent("index.sqlite")),
            scope = semanticScope(root.path)
        func run() throws -> SemanticFileIndexer.Summary {
            try SemanticFileIndexer.run(
                scope: scope,
                store: store,
                reader: reader,
                encoder: encoder,
                cancelled: { false },
                progress: { _ in }
            )
        }
        #expect(try run().files == 1); #expect(encoder.calls == 1)
        #expect(try run().files == 1); #expect(encoder.calls == 1, "unchanged file reuses embeddings")
        reader.modified = reader.modified.addingTimeInterval(1)
        #expect(try run().files == 1); #expect(encoder.calls == 2)
        reader.failed = true
        #expect(try run().skipped == 1); #expect(try store.counts().files == 0)
        reader.failed = false
        encoder.after = { reader.modified = reader.modified.addingTimeInterval(1) }
        #expect(try run().skipped == 1); #expect(
            try store.counts().files == 0,
            "never commit content changed during inference"
        )
        encoder.after = nil; encoder.failure = true
        #expect(throws: SemanticFileStore.Failure.self) { try run() }
        encoder.failure = false
        _ = try run()
        reader.removed = true
        _ = try run(); #expect(try store.counts().chunks == 0)
        #expect(throws: CancellationError.self) {
            try SemanticFileIndexer.run(
                scope: scope,
                store: store,
                reader: reader,
                encoder: encoder,
                cancelled: { true },
                progress: { _ in }
            )
        }
    }
}
