import Darwin
import Foundation
import Testing
@testable import Typeflux

private final class ODTReader: AskFileReading {
    var cursors: [SemanticContentCursor] = []
    var after: (() -> Void)?
    private let native: AskFileReader?
    init(native: Bool = false) { self.native = native ? AskFileReader(timeout: 15) : nil }
    deinit { native?.stop() }
    func read(_ request: AskFileReadRequest, isCancelled: () -> Bool) throws -> AskFileReadResponse {
        if isCancelled() { throw CancellationError() }
        let response = try native?.read(request, isCancelled: isCancelled) ?? AskFileWorkerCommand.handle(request)
        if request.operation == .content, request.readText {
            cursors.append(request.cursor ?? .init()); after?()
        }
        return response
    }
}

@Suite("Offline ODT body and durable continuation", .serialized)
struct SemanticODTTextTests {
    private func document(_ body: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <o:document-content xmlns:o="urn:oasis:names:tc:opendocument:xmlns:office:1.0"
          xmlns:t="urn:oasis:names:tc:opendocument:xmlns:text:1.0"
          xmlns:b="urn:oasis:names:tc:opendocument:xmlns:table:1.0"
          xmlns:d="urn:oasis:names:tc:opendocument:xmlns:drawing:1.0"
          xmlns:xlink="http://www.w3.org/1999/xlink">
          <o:automatic-styles><t:p>hiddenstyle</t:p></o:automatic-styles>
          <o:body><o:text>\(body)</o:text></o:body>
        </o:document-content>
        """
    }

    private func fixture(_ root: URL, _ xml: String, stored: Bool = false,
                         encrypted: Bool = false, manifest: String? = nil) throws -> URL {
        let source = root.appendingPathComponent(".package-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: source.appendingPathComponent("META-INF"),
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: source) }
        try xml.write(to: source.appendingPathComponent("content.xml"), atomically: true, encoding: .utf8)
        try "application/vnd.oasis.opendocument.text".write(to: source.appendingPathComponent("mimetype"),
                                                          atomically: true, encoding: .utf8)
        let encryption = encrypted ? "<m:encryption-data/>" : ""
        try (manifest ?? """
        <m:manifest xmlns:m="urn:oasis:names:tc:opendocument:xmlns:manifest:1.0" m:version="1.3">
        <m:file-entry m:full-path="/" m:media-type="application/vnd.oasis.opendocument.text"/>
        <m:file-entry m:full-path="content.xml" m:media-type="text/xml">\(encryption)</m:file-entry>
        </m:manifest>
        """).write(to: source.appendingPathComponent("META-INF/manifest.xml"), atomically: true, encoding: .utf8)
        let file = root.appendingPathComponent("body-" + UUID().uuidString + ".odt")
        for arguments in [["-q", "-0", file.path, "mimetype"],
                          ["-q", stored ? "-0" : "-9", file.path, "content.xml", "META-INF/manifest.xml"]] {
            let zip = Process(); zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
            zip.currentDirectoryURL = source; zip.arguments = arguments
            zip.standardOutput = FileHandle.nullDevice; zip.standardError = FileHandle.nullDevice
            try zip.run(); zip.waitUntilExit(); try #require(zip.terminationStatus == 0)
        }
        return file
    }

    private func read(_ file: URL, root: URL, cursor: SemanticContentCursor? = nil) -> AskFileReadResponse {
        AskFileWorkerCommand.handle(.init(operation: .content, path: file.path,
                                         scope: semanticScope(root.path), cursor: cursor))
    }

    @Test(arguments: [false, true])
    func `native ODT reader extracts ordered paragraphs lists and tables without resources`(stored: Bool) throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let file = try fixture(root, document("""
        <t:h>Invoice</t:h><t:p>项目 <t:span>INV-682914</t:span><t:s t:c="3"/>approved<t:tab/>yes<t:line-break/>next</t:p>
        <t:list><t:list-item><t:p>listed</t:p></t:list-item></t:list>
        <b:table><b:table-row><b:table-cell><t:p><![CDATA[Table & body]]></t:p></b:table-cell>
        <b:table-cell><t:p>second cell</t:p></b:table-cell></b:table-row></b:table>
        <t:p><t:a xlink:href="http://127.0.0.1:9/must-not-load">visible link</t:a>
        <o:annotation><t:p>hiddenannotation</t:p></o:annotation><t:note><t:note-body><t:p>hiddennote</t:p></t:note-body></t:note>
        <d:frame><d:object xlink:href="file:///must-not-load"><t:p>hiddenobject</t:p></d:object></d:frame></t:p>
        <t:tracked-changes><t:changed-region><t:p>hiddendeletion</t:p></t:changed-region></t:tracked-changes>
        """), stored: stored)
        let child = AskFileReader(timeout: 15); defer { child.stop() }
        let result = try child.read(.init(operation: .content, path: file.path, scope: semanticScope(root.path)))
        let text = try #require(result.pages?.first?.text)
        #expect(result.error == nil && result.nextCursor == nil)
        #expect(text.contains("Invoice\n项目 INV-682914   approved\tyes\nnext\nlisted\n"))
        #expect(text.contains("Table & body\n\tsecond cell\n\t\n"))
        #expect(text.contains("visible link") && !text.contains("hidden"))
        #expect(result.pages?.first?.segmentKind == "odt-body" && result.pages?.first?.page == nil)
        #expect(SemanticFilePolicy.allows(file.path) && SemanticMediaPriority.of(file.path) == .document)
        #expect(SemanticFileStore.documentRecipe(file.path).contains(SemanticODTText.recipe))
        if !stored, let destination = ProcessInfo.processInfo.environment["TYPEFLUX_GUL405_ODT_EVIDENCE"] {
            let folder = URL(fileURLWithPath: destination)
            try FileManager.default.copyItem(at: file, to: folder.appendingPathComponent("synthetic-body.odt"))
            try JSONEncoder().encode(result).write(to: folder.appendingPathComponent("native-odt-result.json"))
        }
    }

    @Test func `long Unicode body resumes across worker and store restart without reencoding committed vectors`() throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let repeated = String(repeating: "项目 résumé 😀 notes & review ", count: 4500)
        let body = "<t:p>firstword " + repeated.replacingOccurrences(of: "&", with: "&amp;") + " tailodtzebra</t:p>"
        let file = try fixture(root, document(body))
        let first = read(file, root: root)
        var cursor = try #require(first.nextCursor), batches = 1, tail = false
        var complete = Data(first.pages!.first!.text.utf8.prefix(Int(cursor.offset)))
        let child = AskFileReader(timeout: 15); defer { child.stop() }
        repeat {
            let response = try child.read(.init(operation: .content, path: file.path,
                scope: semanticScope(root.path), cursor: cursor))
            try #require(response.error == nil)
            #expect(response.version == first.version && response.pages?.first?.offset == cursor.offset)
            #expect(response.pages!.first!.text.utf8.count <= 32768)
            tail = tail || response.pages!.first!.text.contains("tailodtzebra")
            batches += 1
            guard let next = response.nextCursor else {
                complete.append(contentsOf: response.pages!.first!.text.utf8); break
            }
            complete.append(contentsOf: response.pages!.first!.text.utf8.prefix(Int(next.offset - cursor.offset)))
            try #require(next.offset > cursor.offset); cursor = next
        } while batches < 20
        #expect(tail && batches > 2)
        #expect(String(data: complete, encoding: .utf8) == "firstword " + repeated + " tailodtzebra\n")
        let store = try SemanticFileStore(url: root.appendingPathComponent("index.sqlite"))
        let reader = ODTReader(native: true), encoder = SemanticFixtureEncoder()
        let token = AskSearchCancellation()
        encoder.after = { if encoder.calls == 2 { token.cancel() } }
        #expect(throws: CancellationError.self) {
            try SemanticFileIndexer.run(scope: semanticScope(root.path), store: store, reader: reader,
                encoder: encoder, cancelled: { token.isCancelled }, progress: { _ in })
        }
        let partial = try #require(try store.job(file.path))
        #expect(partial.state == .partial && partial.cursor.offset > 0)
        let reopened = try SemanticFileStore(url: store.url)
        let resumed = ODTReader(native: true), resumedEncoder = SemanticFixtureEncoder()
        _ = try SemanticFileIndexer.reconcile(paths: [], scope: semanticScope(root.path), store: reopened,
            reader: resumed, encoder: resumedEncoder, cancelled: { false }, progress: { _ in })
        #expect(resumed.cursors.first == partial.cursor)
        #expect(try reopened.job(file.path)?.state == .done)
        let hits = try reopened.lexicalSearch(text: "tailodtzebra", query: .init("tailodtzebra"), type: .all,
            scope: semanticScope(root.path), limit: 5, cancelled: { false })
        #expect(hits.first?.path == file.path && hits.first?.evidence?.segmentKind == "odt-body")
        #expect(hits.first?.evidence?.text.contains("tailodtzebra") == true)
        let calls = resumedEncoder.calls
        _ = try SemanticFileIndexer.run(scope: semanticScope(root.path), store: reopened, reader: resumed,
            encoder: resumedEncoder, cancelled: { false }, progress: { _ in })
        #expect(resumedEncoder.calls == calls)
    }

    @Test func `completed RTF era discovery adds ODT and preserves compatible vectors`() throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let file = try fixture(root, document("<t:p>newodtzebra</t:p>"))
        let plain = root.appendingPathComponent("unchanged.txt")
        try Data("compatibletextzebra".utf8).write(to: plain)
        let store = try SemanticFileStore(url: root.appendingPathComponent("index.sqlite"))
        let scope = semanticScope(root.path), reader = ODTReader(), encoder = SemanticFixtureEncoder()
        _ = try SemanticFileIndexer.reconcile(paths: [plain.path], scope: scope, store: store, reader: reader,
            encoder: encoder, cancelled: { false }, progress: { _ in })
        let calls = encoder.calls
        let oldFormats = SemanticFilePolicy.extensions.subtracting(["odt"]).sorted()
        let groups = [scope.roots, scope.excludedPaths, scope.excludedFolderNames.sorted(),
                      scope.excludedExtensions.sorted(), scope.blocked, [String(scope.includeHidden)], oldFormats]
        let oldKey = String(data: try JSONEncoder().encode(groups), encoding: .utf8)!
        let oldScanKey = String(data: try JSONEncoder().encode(groups + [["/"]]), encoding: .utf8)!
        try store.lock.withLock {
            try store.execute("INSERT INTO scan_checkpoint VALUES(?,?,?)", [oldKey, 100, "odt-fixture"])
            try store.execute("INSERT INTO scan_scope VALUES(?)", [oldScanKey])
            try store.execute("INSERT INTO scan_directories VALUES(?,'done')", [root.path])
        }
        #expect(try store.completedEventID(scope: scope, volumeSignature: "odt-fixture") == nil)
        _ = try SemanticFileIndexer.run(scope: scope, store: store, reader: reader, encoder: encoder,
            cancelled: { false }, progress: { _ in })
        #expect(try store.job(file.path)?.state == .done && encoder.calls == calls + 1)
        #expect(SemanticFileStore.documentRecipe(plain.path) == SemanticFileStore.documentProvenance)
    }

    @Test(arguments: ["cancel", "replace", "permission"])
    func `cancellation replacement and permission revocation prevent publication`(action: String) throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let file = try fixture(root, document("<t:p>notpublishedzebra</t:p>"))
        let store = try SemanticFileStore(url: root.appendingPathComponent("index.sqlite"))
        let reader = ODTReader(), encoder = SemanticFixtureEncoder()
        let token = AskSearchCancellation()
        reader.after = {
            if action == "replace" {
                try? Data(document("<t:p>replacement</t:p>").utf8).write(to: file)
            } else if action == "permission" {
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

    @Test(arguments: ["broken", "xml", "dtd", "manifest", "manifest-dtd", "encrypted", "crc", "zip64", "missing"])
    func `damaged encrypted and unsupported packages retain reasons and retry`(kind: String) throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let xml = kind == "xml" ? "<broken>" : kind == "dtd"
            ? "<!DOCTYPE x [<!ENTITY x SYSTEM 'file:///must-not-load'>]>" + document("<t:p>&x;</t:p>")
            : document("<t:p>healthyodtzebra</t:p>")
        let manifest = kind == "manifest" ? "<broken/>" : kind == "manifest-dtd"
            ? "<!DOCTYPE x [<!ENTITY x 'boom'>]><x/>" : nil
        let file = try fixture(root, xml, encrypted: kind == "encrypted", manifest: manifest)
        var data = try Data(contentsOf: file)
        if kind == "broken" { data = Data("broken".utf8) }
        if kind == "crc" || kind == "zip64" {
            let central = try #require(data.range(of: Data("content.xml".utf8), options: .backwards)?.lowerBound) - 46
            if kind == "crc" { data[central + 16] ^= 1 } else {
                data.replaceSubrange(central + 24 ..< central + 28, with: [255, 255, 255, 255])
            }
        }
        if kind == "missing" {
            while let range = data.range(of: Data("content.xml".utf8)) { data[range.lowerBound] = 88 }
        }
        try data.write(to: file)
        let store = try SemanticFileStore(url: root.appendingPathComponent("index.sqlite"))
        let reader = ODTReader(), encoder = SemanticFixtureEncoder()
        let reason = kind == "encrypted" ? "password-required"
            : ["dtd", "manifest-dtd", "zip64"].contains(kind) ? "unsupported-document" : "unreadable-content"
        for _ in 0..<2 {
            _ = try SemanticFileIndexer.reconcile(paths: [file.path], scope: semanticScope(root.path), store: store,
                reader: reader, encoder: encoder, cancelled: { false }, progress: { _ in })
            #expect(try store.job(file.path)?.state == .failed && store.job(file.path)?.reason == reason)
        }
        #expect(encoder.calls == 0)
        let repaired = try fixture(root, document("<t:p>repairedodtzebra</t:p>"))
        try Data(contentsOf: repaired).write(to: file)
        _ = try SemanticFileIndexer.reconcile(paths: [file.path], scope: semanticScope(root.path), store: store,
            reader: reader, encoder: encoder, cancelled: { false }, progress: { _ in })
        #expect(try store.job(file.path)?.state == .done && encoder.calls == 1)
    }

    @Test func `empty body explicit spaces and invalid logical cursors are bounded`() throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let empty = try fixture(root, document(""))
        #expect(read(empty, root: root).pages?.first?.text == "")
        let file = try fixture(root, document("<t:p>汉<t:s/>字</t:p>"))
        #expect(read(file, root: root).pages?.first?.text == "汉 字\n")
        for cursor in [SemanticContentCursor(page: 1), .init(offset: 1), .init(offset: 99), .init(offset: -1)] {
            #expect(read(file, root: root, cursor: cursor).error == EINVAL)
        }
        for count in ["0", "-1", "bad"] {
            let bad = try fixture(root, document("<t:p><t:s t:c='\(count)'/></t:p>"))
            #expect(read(bad, root: root).error == EINVAL)
        }
        let spaces = try fixture(root, document("<t:p><t:s t:c='100000'/>tailspaces</t:p>"))
        let first = read(spaces, root: root)
        #expect(first.nextCursor != nil && first.pages?.first?.text.utf8.count == 32768)
        #expect(read(spaces, root: root, cursor: .init(offset: 100000)).pages?.first?.text == "tailspaces\n")
        let other = try fixture(root, "<o:document-content xmlns:o='\(SemanticODTText.office)'><o:body><o:spreadsheet/></o:body></o:document-content>")
        #expect(read(other, root: root).error == EILSEQ)
    }
}
