import Darwin
import Foundation
import Testing
@testable import Typeflux

private final class PPTXReader: AskFileReading {
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

@Suite("PPTX presentation order and durable continuation", .serialized)
// swiftlint:disable:next type_body_length
struct SemanticPresentationTextTests {
    private func document(_ runs: String) -> String {
        """
        <p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"
          xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">
        <p:cSld><p:spTree><p:sp><p:txBody><a:bodyPr/><a:lstStyle/><a:p>\(runs)</a:p></p:txBody></p:sp>
        </p:spTree></p:cSld></p:sld>
        """
    }

    // swiftlint:disable:next function_body_length
    private func fixture(_ root: URL, _ xml: String, second: String? = nil, stored: Bool = false,
                         presentation: String? = nil, relations: String? = nil) throws -> URL {
        let source = root.appendingPathComponent(".package-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: source.appendingPathComponent("ppt/_rels"),
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source.appendingPathComponent("ppt/slides"),
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: source) }
        let ids = second == nil ? "" : "<p:sldId id='257' link:id='second'/>"
        let order = presentation ?? """
        <p:presentation xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"
          xmlns:link="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
        <p:sldIdLst><p:sldId id="256" link:id="first"/>\(ids)</p:sldIdLst></p:presentation>
        """
        let extra = second == nil ? "" : "<Relationship Id='second' Type='\(SemanticPresentationText.relationship)/slide' Target='/ppt/slides/slide10.xml'/>"
        let links = relations ?? """
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        \(extra)<Relationship Id="unused" Type="external" TargetMode="External" Target="http://127.0.0.1:9/must-not-load"/>
        <Relationship Id="first" Type="\(SemanticPresentationText.relationship)/slide" Target="slides/../slides/slide2.xml"/>
        </Relationships>
        """
        var files = ["ppt/slides/slide2.xml": xml, "ppt/presentation.xml": order,
                     "ppt/_rels/presentation.xml.rels": links,
                     "[Content_Types].xml": """
                     <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
                     <Default Extension="xml" ContentType="application/xml"/>
                     <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
                     <Override PartName="/ppt/presentation.xml"
                       ContentType="application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"/>
                     <Override PartName="/ppt/slides/slide2.xml"
                       ContentType="application/vnd.openxmlformats-officedocument.presentationml.slide+xml"/>
                     </Types>
                     """,
                     "_rels/.rels": "<Relationships xmlns='http://schemas.openxmlformats.org/package/2006/relationships'><Relationship Id='rId1' Type='\(SemanticPresentationText.relationship)/officeDocument' Target='ppt/presentation.xml'/></Relationships>"]
        if let second {
            files["ppt/slides/slide10.xml"] = second
            files["[Content_Types].xml"] = files["[Content_Types].xml"]?.replacingOccurrences(of: "</Types>", with: """
            <Override PartName="/ppt/slides/slide10.xml"
              ContentType="application/vnd.openxmlformats-officedocument.presentationml.slide+xml"/></Types>
            """)
        }
        for (path, text) in files {
            let url = source.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        let file = root.appendingPathComponent("body-" + UUID().uuidString + ".pptx")
        let zip = Process(); zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = source; zip.arguments = ["-q", stored ? "-0" : "-9", file.path] + files.keys.sorted()
        zip.standardOutput = FileHandle.nullDevice; zip.standardError = FileHandle.nullDevice
        try zip.run(); zip.waitUntilExit(); try #require(zip.terminationStatus == 0)
        return file
    }

    private func read(_ file: URL, root: URL, cursor: SemanticContentCursor? = nil) -> AskFileReadResponse {
        AskFileWorkerCommand.handle(.init(operation: .content, path: file.path,
                                         scope: semanticScope(root.path), cursor: cursor))
    }

    @Test(arguments: [false, true])
    func `native reader follows relationship order and extracts shapes and tables only`(stored: Bool) throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let table = """
        <p:graphicFrame><a:graphic><a:graphicData><a:tbl><a:tr><a:tc><a:txBody><a:p>
        <a:r><a:t><![CDATA[Table & body]]></a:t></a:r></a:p></a:txBody></a:tc></a:tr></a:tbl>
        </a:graphicData></a:graphic></p:graphicFrame>
        <p:pic><a:t>hiddenpicture</a:t></p:pic><p:oleObj><p:sp><p:txBody><a:p><a:r><a:t>hiddenobject</a:t>
        </a:r></a:p></p:txBody></p:sp></p:oleObj>
        """
        let xml = document("<a:r><a:rPr><a:hlinkClick xmlns:r='\(SemanticPresentationText.relationship)' r:id='external'/></a:rPr><a:t>项目 INV-682914</a:t></a:r><a:br/><a:fld><a:t>cached field</a:t></a:fld>")
            .replacingOccurrences(of: "</p:spTree>", with: table + "</p:spTree>")
        let file = try fixture(root, xml, second: document("<a:r><a:t>secondslidezebra</a:t></a:r>"), stored: stored)
        let child = AskFileReader(timeout: 15); defer { child.stop() }
        let result = try child.read(.init(operation: .content, path: file.path, scope: semanticScope(root.path)))
        let local = read(file, root: root)
        #expect(result.pages?.map(\.text) == local.pages?.map(\.text))
        #expect(result.error == nil && result.pages?.first?.page == 1 && result.nextCursor == .init(page: 1))
        #expect(result.pages?.first?.text == "项目 INV-682914\ncached field\nTable & body\n")
        #expect(result.pages?.first?.segmentKind == "pptx-slide" && result.version != nil)
        let second = read(file, root: root, cursor: result.nextCursor)
        #expect(second.pages?.first?.page == 2 && second.pages?.first?.text == "secondslidezebra\n")
        #expect(second.nextCursor == nil)
        #expect(SemanticFileStore.documentRecipe(file.path).contains(SemanticPresentationText.recipe))
        if !stored, let destination = ProcessInfo.processInfo.environment["TYPEFLUX_GUL405_PPTX_EVIDENCE"] {
            let folder = URL(fileURLWithPath: destination)
            try FileManager.default.copyItem(at: file, to: folder.appendingPathComponent("synthetic-body.pptx"))
            try JSONEncoder().encode(result).write(to: folder.appendingPathComponent("native-pptx-result.json"))
        }
    }

    // swiftlint:disable:next function_body_length
    @Test func `long Unicode body resumes across worker and store restart without reencoding committed vectors`() throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let repeated = String(repeating: "项目 résumé 😀 notes & review ", count: 4500)
        let body = "<a:r><a:t>firstword " + repeated.replacingOccurrences(of: "&", with: "&amp;")
            + " tailpptxzebra</a:t></a:r>"
        let file = try fixture(root, document(body),
                               second: document("<a:r><a:t>secondslidezebra</a:t></a:r>"))
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
            tail = tail || response.pages!.first!.text.contains("tailpptxzebra")
            batches += 1
            guard let next = response.nextCursor, next.page == 0 else {
                complete.append(contentsOf: response.pages!.first!.text.utf8); break
            }
            complete.append(contentsOf: response.pages!.first!.text.utf8.prefix(Int(next.offset - cursor.offset)))
            try #require(next.offset > cursor.offset); cursor = next
        } while batches < 20
        #expect(tail && batches > 2)
        #expect(String(data: complete, encoding: .utf8) == "firstword " + repeated + " tailpptxzebra\n")
        let store = try SemanticFileStore(url: root.appendingPathComponent("index.sqlite"))
        let reader = PPTXReader(native: true), encoder = SemanticFixtureEncoder()
        let token = AskSearchCancellation()
        encoder.after = { if encoder.calls == 2 { token.cancel() } }
        #expect(throws: CancellationError.self) {
            try SemanticFileIndexer.run(scope: semanticScope(root.path), store: store, reader: reader,
                encoder: encoder, cancelled: { token.isCancelled }, progress: { _ in })
        }
        let partial = try #require(try store.job(file.path))
        #expect(partial.state == .partial && partial.cursor.offset > 0)
        let reopened = try SemanticFileStore(url: store.url)
        let resumed = PPTXReader(native: true), resumedEncoder = SemanticFixtureEncoder()
        _ = try SemanticFileIndexer.reconcile(paths: [], scope: semanticScope(root.path), store: reopened,
            reader: resumed, encoder: resumedEncoder, cancelled: { false }, progress: { _ in })
        #expect(resumed.cursors.first == partial.cursor)
        #expect(try reopened.job(file.path)?.state == .done)
        let hits = try reopened.lexicalSearch(text: "tailpptxzebra", query: .init("tailpptxzebra"), type: .all,
            scope: semanticScope(root.path), limit: 5, cancelled: { false })
        #expect(hits.first?.path == file.path && hits.first?.evidence?.segmentKind == "pptx-slide")
        #expect(hits.first?.evidence?.page == 1 && (hits.first?.evidence?.startOffset ?? 0) > 0)
        let secondHits = try reopened.lexicalSearch(text: "secondslidezebra",
            query: .init("secondslidezebra"), type: .all,
            scope: semanticScope(root.path), limit: 5, cancelled: { false })
        #expect(secondHits.first?.evidence?.page == 2)
        #expect(hits.first?.evidence?.text.contains("tailpptxzebra") == true)
        let calls = resumedEncoder.calls
        _ = try SemanticFileIndexer.run(scope: semanticScope(root.path), store: reopened, reader: resumed,
            encoder: resumedEncoder, cancelled: { false }, progress: { _ in })
        #expect(resumedEncoder.calls == calls)
    }

    @Test func `cross slide restart keeps committed first slide vectors`() throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let file = try fixture(root, document("<a:r><a:t>firstslidezebra</a:t></a:r>"),
                               second: document("<a:r><a:t>lastslidezebra</a:t></a:r>"))
        let store = try SemanticFileStore(url: root.appendingPathComponent("index.sqlite"))
        let reader = PPTXReader(), encoder = SemanticFixtureEncoder(), token = AskSearchCancellation()
        reader.after = { if reader.cursors.count == 2 { token.cancel() } }
        #expect(throws: CancellationError.self) {
            try SemanticFileIndexer.run(scope: semanticScope(root.path), store: store, reader: reader,
                encoder: encoder, cancelled: { token.isCancelled }, progress: { _ in })
        }
        #expect(try store.job(file.path)?.cursor == .init(page: 1) && encoder.calls == 1)
        let reopened = try SemanticFileStore(url: store.url)
        let resumed = PPTXReader(), resumedEncoder = SemanticFixtureEncoder()
        _ = try SemanticFileIndexer.reconcile(paths: [], scope: semanticScope(root.path), store: reopened,
            reader: resumed, encoder: resumedEncoder, cancelled: { false }, progress: { _ in })
        #expect(resumed.cursors == [.init(page: 1)] && resumedEncoder.calls == 1)
        let hits = try reopened.lexicalSearch(text: "lastslidezebra", query: .init("lastslidezebra"), type: .all,
            scope: semanticScope(root.path), limit: 5, cancelled: { false })
        #expect(try reopened.job(file.path)?.state == .done && hits.first?.evidence?.page == 2)
    }

    @Test func `completed ODT era discovery adds PPTX and preserves compatible vectors`() throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let file = try fixture(root, document("<a:r><a:t>newpptxzebra</a:t></a:r>"))
        let plain = root.appendingPathComponent("unchanged.txt")
        try Data("compatibletextzebra".utf8).write(to: plain)
        let store = try SemanticFileStore(url: root.appendingPathComponent("index.sqlite"))
        let scope = semanticScope(root.path), reader = PPTXReader(), encoder = SemanticFixtureEncoder()
        _ = try SemanticFileIndexer.reconcile(paths: [plain.path], scope: scope, store: store, reader: reader,
            encoder: encoder, cancelled: { false }, progress: { _ in })
        let calls = encoder.calls
        let oldFormats = SemanticFilePolicy.extensions.subtracting(["pptx"]).sorted()
        let groups = [scope.roots, scope.excludedPaths, scope.excludedFolderNames.sorted(),
                      scope.excludedExtensions.sorted(), scope.blocked, [String(scope.includeHidden)], oldFormats]
        let oldKey = String(data: try JSONEncoder().encode(groups), encoding: .utf8)!
        let oldScanKey = String(data: try JSONEncoder().encode(groups + [["/"]]), encoding: .utf8)!
        try store.lock.withLock {
            try store.execute("INSERT INTO scan_checkpoint VALUES(?,?,?)", [oldKey, 100, "pptx-fixture"])
            try store.execute("INSERT INTO scan_scope VALUES(?)", [oldScanKey])
            try store.execute("INSERT INTO scan_directories VALUES(?,'done')", [root.path])
        }
        #expect(try store.completedEventID(scope: scope, volumeSignature: "pptx-fixture") == nil)
        _ = try SemanticFileIndexer.run(scope: scope, store: store, reader: reader, encoder: encoder,
            cancelled: { false }, progress: { _ in })
        #expect(try store.job(file.path)?.state == .done && encoder.calls == calls + 1)
        #expect(SemanticFileStore.documentRecipe(plain.path) == SemanticFileStore.documentProvenance)
    }

    @Test(arguments: ["cancel", "replace", "permission"])
    func `cancellation replacement and permission revocation prevent publication`(action: String) throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let file = try fixture(root, document("<a:r><a:t>notpublishedzebra</a:t></a:r>"))
        let store = try SemanticFileStore(url: root.appendingPathComponent("index.sqlite"))
        let reader = PPTXReader(), encoder = SemanticFixtureEncoder()
        let token = AskSearchCancellation()
        reader.after = {
            if action == "replace" {
                try? Data(document("<a:r><a:t>replacement</a:t></a:r>").utf8).write(to: file)
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

    @Test(arguments: ["xml", "dtd", "external", "escape", "duplicate", "missing", "encrypted", "zip64", "crc"])
    func `invalid packages persist fixed reasons across explicit retry and recover after version changes`(kind: String) throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let xml = kind == "xml" ? "<broken>" : kind == "dtd"
            ? "<!DOCTYPE x [<!ENTITY x SYSTEM 'http://127.0.0.1:9/must-not-load'>]>" + document("<a:r><a:t>&x;</a:t></a:r>")
            : document("<a:r><a:t>healthy</a:t></a:r>")
        let target = kind == "external" ? "http://127.0.0.1:9/must-not-load" : "../../../../must-not-load.xml"
        let relation = "<Relationship Id='first' Type='\(SemanticPresentationText.relationship)/slide' Target='\(target)' \(kind == "external" ? "TargetMode='External'" : "")/>"
        let relations = ["external", "escape", "duplicate", "missing"].contains(kind)
            ? "<Relationships xmlns='\(SemanticPresentationText.package)'>"
                + (kind == "missing" ? "" : relation) + (kind == "duplicate" ? relation : "") + "</Relationships>" : nil
        let file = try fixture(root, xml, relations: relations)
        var data = try Data(contentsOf: file)
        let nameRange = try #require(data.range(of: Data("ppt/slides/slide2.xml".utf8), options: .backwards))
        let central = nameRange.lowerBound - 46
        if kind == "encrypted" {
            data[central + 8] |= 1
        } else if kind == "zip64" {
            data.replaceSubrange(central + 24 ..< central + 28, with: [255, 255, 255, 255])
        } else if kind == "crc" { data[central + 16] ^= 1 }
        try data.write(to: file)
        let store = try SemanticFileStore(url: root.appendingPathComponent("index.sqlite"))
        let reader = PPTXReader(), encoder = SemanticFixtureEncoder()
        let reason = kind == "encrypted" ? "password-required" : ["dtd", "escape", "zip64"].contains(kind)
            ? "unsupported-document" : "unreadable-content"
        for _ in 0..<2 {
            _ = try SemanticFileIndexer.reconcile(paths: [file.path], scope: semanticScope(root.path), store: store,
                reader: reader, encoder: encoder, cancelled: { false }, progress: { _ in })
            #expect(try store.job(file.path)?.state == .failed && store.job(file.path)?.reason == reason)
        }
        #expect(encoder.calls == 0 && reader.cursors.count == 2)
        let repaired = try fixture(root, document("<a:r><a:t>repairedpptxzebra</a:t></a:r>"))
        try Data(contentsOf: repaired).write(to: file)
        _ = try SemanticFileIndexer.reconcile(paths: [file.path], scope: semanticScope(root.path), store: store,
            reader: reader, encoder: encoder, cancelled: { false }, progress: { _ in })
        #expect(try store.job(file.path)?.state == .done && encoder.calls == 1)
    }

    @Test func `empty slides invalid cursors and strict namespaces remain deterministic`() throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let empty = try fixture(root, document(""))
        #expect(read(empty, root: root).pages?.first?.text == "\n")
        #expect(read(empty, root: root, cursor: .init(page: 1)).pages?.isEmpty == true)
        let file = try fixture(root, document("<a:r><a:t>汉字</a:t></a:r>"))
        for cursor in [SemanticContentCursor(page: 2), .init(page: 1, offset: 1), .init(offset: 1), .init(offset: 99)] {
            #expect(read(file, root: root, cursor: cursor).error == EINVAL)
        }
        let strict = document("<a:r><a:t>strictzebra</a:t></a:r>")
            .replacingOccurrences(of: "http://schemas.openxmlformats.org/", with: "http://purl.oclc.org/ooxml/")
            .replacingOccurrences(of: "/2006", with: "")
        #expect(read(try fixture(root, strict), root: root).pages?.first?.text == "strictzebra\n")
        #expect(read(try fixture(root, "<sld/>"), root: root).error == EILSEQ)
    }
}
