import Darwin
import Foundation
import Testing
@testable import Typeflux

private final class WordReader: AskFileReading {
    var cursors: [SemanticContentCursor] = []
    var after: (() -> Void)?
    func read(_ request: AskFileReadRequest, isCancelled: () -> Bool) throws -> AskFileReadResponse {
        if isCancelled() { throw CancellationError() }
        let result = AskFileWorkerCommand.handle(request)
        if request.operation == .content, request.readText {
            cursors.append(request.cursor ?? .init()); after?()
        }
        return result
    }
}

@Suite("Local DOCX body and discovery upgrade", .serialized)
struct SemanticWordTextTests {
    private let namespace = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"

    private func fixture(_ root: URL, body: String, stored: Bool = false, raw: Bool = false) throws -> URL {
        let source = root.appendingPathComponent(".package-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: source.appendingPathComponent("word/_rels"),
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source.appendingPathComponent("_rels"),
                                                withIntermediateDirectories: true)
        let xml = raw ? body : "<?xml version=\"1.0\" encoding=\"UTF-8\"?><w:document xmlns:w=\"\(namespace)\"><w:body>\(body)</w:body></w:document>"
        try xml.write(to: source.appendingPathComponent("word/document.xml"), atomically: true, encoding: .utf8)
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
        <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
        </Types>
        """.write(to: source.appendingPathComponent("[Content_Types].xml"), atomically: true, encoding: .utf8)
        try """
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
        </Relationships>
        """.write(to: source.appendingPathComponent("_rels/.rels"), atomically: true, encoding: .utf8)
        try """
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId99" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="http://127.0.0.1:9/must-not-load" TargetMode="External"/>
        </Relationships>
        """.write(to: source.appendingPathComponent("word/_rels/document.xml.rels"), atomically: true, encoding: .utf8)
        let file = root.appendingPathComponent("body-" + UUID().uuidString + ".docx")
        let zip = Process(); zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = source
        zip.arguments = ["-q", stored ? "-0" : "-9", file.path, "word/document.xml", "[Content_Types].xml",
                         "_rels/.rels", "word/_rels/document.xml.rels"]
        zip.standardOutput = FileHandle.nullDevice; zip.standardError = FileHandle.nullDevice
        try zip.run(); zip.waitUntilExit()
        try #require(zip.terminationStatus == 0)
        try FileManager.default.removeItem(at: source)
        return file
    }

    private func read(_ file: URL, root: URL, cursor: SemanticContentCursor? = nil) -> AskFileReadResponse {
        AskFileWorkerCommand.handle(.init(operation: .content, path: file.path,
                                         scope: semanticScope(root.path), cursor: cursor))
    }

    private func hits(_ store: SemanticFileStore, root: URL, text: String) throws -> [AskFileHit] {
        try store.lexicalSearch(text: text, query: .init(text), type: .all,
                                scope: semanticScope(root.path), limit: 5, cancelled: { false })
    }

    @Test(arguments: [false, true])
    func `real Word package extracts only body text through disposable reader`(stored: Bool) throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let file = try fixture(root, body: """
        <w:p><w:r><w:t>项目报销 INV-</w:t></w:r><w:r><w:t>682914 &amp; approval</w:t><w:tab/><w:t>accepted</w:t><w:br/><w:t>second line</w:t></w:r></w:p>
        <w:tbl><w:tr><w:tc><w:p><w:r><w:t><![CDATA[Table body]]></w:t></w:r></w:p></w:tc></w:tr></w:tbl>
        <w:p><w:r><w:instrText>unexecutedinstruction</w:instrText><w:delText>deletedcontent</w:delText></w:r></w:p>
        """, stored: stored)
        let child = AskFileReader(timeout: 15); defer { child.stop() }
        let response = try child.read(.init(operation: .content, path: file.path, scope: semanticScope(root.path)))
        #expect(response.error == nil)
        let text = try #require(response.pages?.first?.text)
        #expect(text.contains("项目报销 INV-682914 & approval\taccepted\nsecond line\n"))
        #expect(text.contains("Table body"))
        #expect(!text.contains("deletedcontent") && !text.contains("unexecutedinstruction"))
        #expect(response.nextCursor == nil && response.pages?.first?.segmentKind == "docx-body")
        #expect(response.pages?.first?.page == nil && response.pages?.first?.offset == 0)
        if !stored, let destination = ProcessInfo.processInfo.environment["TYPEFLUX_GUL405_WORD_EVIDENCE"] {
            let folder = URL(fileURLWithPath: destination)
            try FileManager.default.copyItem(at: file, to: folder.appendingPathComponent("synthetic-body.docx"))
            try JSONEncoder().encode(response).write(to: folder.appendingPathComponent("native-docx-result.json"))
        }
    }

    @Test func `long Unicode body continues after reader and store restart without reencoding committed vectors`() throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let file = try fixture(root, body: "<w:p><w:r><w:t>firstword " +
            String(repeating: "项目 notes &amp; résumé. ", count: 5000) + " tailwordzebra</w:t></w:r></w:p>")
        let first = read(file, root: root)
        let next = try #require(first.nextCursor)
        #expect(first.error == nil && next.offset > 0 && first.pages!.first!.text.utf8.count <= 32768)
        let child = AskFileReader(timeout: 15)
        var cursor = next, foundTail = false, batches = 1
        repeat {
            let response = try child.read(.init(operation: .content, path: file.path,
                scope: semanticScope(root.path), cursor: cursor))
            try #require(response.error == nil)
            #expect(response.version == first.version && response.pages!.first!.offset == cursor.offset)
            #expect(response.pages!.first!.text.utf8.count <= 32768)
            foundTail = foundTail || response.pages!.first!.text.contains("tailwordzebra")
            batches += 1
            guard let next = response.nextCursor else { break }
            try #require(next.offset > cursor.offset); cursor = next
        } while batches < 20
        child.stop()
        #expect(foundTail && batches > 2)
        let store = try SemanticFileStore(url: root.appendingPathComponent("index.sqlite"))
        let reader = WordReader(), encoder = SemanticFixtureEncoder(), token = AskSearchCancellation()
        encoder.after = { if encoder.calls == 2 { token.cancel() } }
        #expect(throws: CancellationError.self) {
            try SemanticFileIndexer.run(scope: semanticScope(root.path), store: store, reader: reader,
                encoder: encoder, cancelled: { token.isCancelled }, progress: { _ in })
        }
        let partial = try #require(try store.job(file.path))
        #expect(partial.state == .partial && partial.cursor.offset > 0)
        let resumedReader = WordReader(), resumedEncoder = SemanticFixtureEncoder()
        let reopened = try SemanticFileStore(url: store.url)
        _ = try SemanticFileIndexer.reconcile(paths: [], scope: semanticScope(root.path), store: reopened,
            reader: resumedReader, encoder: resumedEncoder, cancelled: { false }, progress: { _ in })
        #expect(resumedReader.cursors.first == partial.cursor)
        #expect(try reopened.job(file.path)?.state == .done)
        #expect(try hits(reopened, root: root, text: "tailwordzebra").first?.path == file.path)
        #expect(try hits(reopened, root: root, text: "tailwordzebra").first?.evidence?.segmentKind == "docx-body")
        let calls = resumedEncoder.calls
        _ = try SemanticFileIndexer.run(scope: semanticScope(root.path), store: reopened, reader: resumedReader,
            encoder: resumedEncoder, cancelled: { false }, progress: { _ in })
        #expect(resumedEncoder.calls == calls)
    }

    @Test func `old completed discovery rescans new formats and preserves existing text vectors`() throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let file = try fixture(root, body: "<w:p><w:r><w:t>newformatzebra</w:t></w:r></w:p>")
        let plain = root.appendingPathComponent("unchanged.txt")
        try "existingtextzebra".write(to: plain, atomically: true, encoding: .utf8)
        let store = try SemanticFileStore(url: root.appendingPathComponent("index.sqlite"))
        let scope = semanticScope(root.path), reader = WordReader(), encoder = SemanticFixtureEncoder()
        _ = try SemanticFileIndexer.reconcile(paths: [plain.path], scope: scope, store: store, reader: reader,
            encoder: encoder, cancelled: { false }, progress: { _ in })
        let calls = encoder.calls
        let groups = [scope.roots, scope.excludedPaths, scope.excludedFolderNames.sorted(),
                      scope.excludedExtensions.sorted(), scope.blocked, [String(scope.includeHidden)]]
        let oldKey = String(data: try JSONEncoder().encode(groups), encoding: .utf8)!
        let oldScanKey = String(data: try JSONEncoder().encode(groups + [["/"]]), encoding: .utf8)!
        try store.lock.withLock {
            try store.execute("INSERT INTO scan_checkpoint VALUES(?,?,?)", [oldKey, 100, "word-fixture"])
            try store.execute("INSERT INTO scan_scope VALUES(?)", [oldScanKey])
            try store.execute("INSERT INTO scan_directories VALUES(?,'done')", [root.path])
        }
        #expect(try store.completedEventID(scope: scope, volumeSignature: "word-fixture") == nil)
        _ = try SemanticFileIndexer.run(scope: scope, store: store, reader: reader,
            encoder: encoder, cancelled: { false }, progress: { _ in })
        #expect(try store.job(file.path)?.state == .done)
        #expect(encoder.calls == calls + 1, "existing compatible text vectors must survive discovery upgrade")
        #expect(try hits(store, root: root, text: "newformatzebra").first?.path == file.path)
        try store.saveEventID(101, scope: scope, volumeSignature: "word-fixture")
        let reopened = try SemanticFileStore(url: store.url)
        #expect(try reopened.completedEventID(scope: scope, volumeSignature: "word-fixture") == 101)
        #expect(SemanticFilePolicy.allows(file.path) && SemanticMediaPriority.of(file.path) == .document)
        for ext in ["doc", "xls", "ppt"] {
            #expect(!SemanticFilePolicy.allows(root.path + "/unsupported." + ext))
        }
        #expect(SemanticFileStore.documentRecipe(plain.path) == SemanticFileStore.documentProvenance)
        #expect(SemanticFileStore.documentRecipe(file.path).contains(SemanticWordText.recipe))
    }

    @Test(arguments: ["cancel", "replace", "permission"])
    func `content returned after cancellation replacement or permission revocation never publishes`(action: String) throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let file = try fixture(root, body: "<w:p><w:r><w:t>notpublishedzebra</w:t></w:r></w:p>")
        let store = try SemanticFileStore(url: root.appendingPathComponent("index.sqlite"))
        let token = AskSearchCancellation(), reader = WordReader(), encoder = SemanticFixtureEncoder()
        reader.after = {
            if action == "replace" { try? Data("replacement".utf8).write(to: file) } else if action == "permission" {
                try? FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
            } else { token.cancel() }
        }
        if action == "cancel" {
            #expect(throws: CancellationError.self) {
                try SemanticFileIndexer.reconcile(paths: [file.path], scope: semanticScope(root.path), store: store,
                    reader: reader, encoder: encoder, cancelled: { token.isCancelled }, progress: { _ in })
            }
        } else {
            _ = try SemanticFileIndexer.reconcile(paths: [file.path], scope: semanticScope(root.path), store: store,
                reader: reader, encoder: encoder, cancelled: { false }, progress: { _ in })
        }
        #expect(try store.counts().chunks == 0 && encoder.calls == 0)
        var denied = semanticScope(root.path); denied.excludedPaths = [file.path]
        #expect(AskFileWorkerCommand.handle(.init(operation: .content, path: file.path, scope: denied)).error == EACCES)
    }

    @Test(arguments: ["broken", "xml", "dtd", "crc", "encrypted", "zip64", "method", "missing"])
    // swiftlint:disable:next cyclomatic_complexity
    func `corrupt encrypted and unsupported bodies keep fixed reasons and can retry`(kind: String) throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let xml: String
        if kind == "xml" { xml = "<w:document>broken" } else if kind == "dtd" {
            xml = "<!DOCTYPE x [<!ENTITY x SYSTEM \"file:///must-not-load\">]><w:document xmlns:w=\"\(namespace)\"><w:body><w:p><w:r><w:t>&x;</w:t></w:r></w:p></w:body></w:document>"
        } else { xml = "<w:document xmlns:w=\"\(namespace)\"><w:body><w:p><w:r><w:t>healthybody</w:t></w:r></w:p></w:body></w:document>" }
        let file = try fixture(root, body: xml, raw: true)
        var data = try Data(contentsOf: file)
        let central = try #require(data.range(of: Data([0x50, 0x4B, 0x01, 0x02]))?.lowerBound)
        switch kind {
        case "broken": data = Data("broken".utf8)
        case "crc": data[central + 16] ^= 1
        case "encrypted": data[central + 8] |= 1
        case "zip64": data.replaceSubrange(central + 24 ..< central + 28, with: [255, 255, 255, 255])
        case "method": data[central + 10] = 99
        case "missing":
            let name = Data("word/document.xml".utf8)
            while let range = data.range(of: name) { data[range.lowerBound] = 120 }
        default: break
        }
        try data.write(to: file)
        let response = read(file, root: root)
        let unsupported = ["dtd", "zip64", "method"].contains(kind)
        let expected: Int32 = kind == "encrypted" ? EAUTH : unsupported ? ENOTSUP : EILSEQ
        #expect(response.error == expected)
        let store = try SemanticFileStore(url: root.appendingPathComponent("index.sqlite"))
        let reader = WordReader(), encoder = SemanticFixtureEncoder()
        for attempt in 0 ..< 2 {
            _ = try SemanticFileIndexer.reconcile(paths: [file.path], scope: semanticScope(root.path), store: store,
                reader: reader, encoder: encoder, cancelled: { false }, progress: { _ in })
            let job = try #require(try store.job(file.path))
            #expect(job.state == .failed && job.attempts == attempt)
            let reason = expected == EAUTH ? "password-required"
                : expected == ENOTSUP ? "unsupported-document" : "unreadable-content"
            #expect(job.reason == reason)
        }
        #expect(encoder.calls == 0)
    }

    @Test func `invalid logical cursor is rejected and empty body finishes`() throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let file = try fixture(root, body: "<w:p><w:r><w:t>汉字</w:t></w:r></w:p>")
        for cursor in [SemanticContentCursor(page: 1), .init(offset: 1), .init(offset: 999), .init(offset: -1)] {
            #expect(read(file, root: root, cursor: cursor).error == EINVAL)
        }
        let empty = try fixture(root, body: "")
        let response = read(empty, root: root)
        #expect(response.error == nil && response.nextCursor == nil && response.pages?.first?.text == "")
    }
}
