// swiftlint:disable file_length
import AppKit
import SwiftUI
import Darwin
import Foundation
import Testing
@testable import Typeflux

private final class XLSXReader: AskFileReading {
    var cursors: [SemanticContentCursor] = []
    var after: (() -> Void)?
    private let native: AskFileReader?
    init(native: Bool = false) { self.native = native ? AskFileReader() : nil }
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

@Suite("XLSX worksheet order and durable continuation", .serialized, .exclusiveUIState)
// swiftlint:disable:next type_body_length
struct SemanticSpreadsheetTextTests {
    private func document(_ cells: String) -> String {
        "<worksheet xmlns='http://schemas.openxmlformats.org/spreadsheetml/2006/main'><sheetData><row r='1'>" + cells + "</row></sheetData></worksheet>"
    }

    private func fixture(_ root: URL, _ xml: String, second: String? = nil, stored: Bool = false,
                         workbook: String? = nil, relations: String? = nil, strings: String? = nil) throws -> URL {
        let source = root.appendingPathComponent(".package-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: source) }
        let extra = second == nil ? "" : "<sheet name='Second' sheetId='1' link:id='second'/>"
        let order = workbook ?? """
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"
          xmlns:link="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
        <sheets><sheet name="项目" sheetId="99" link:id="first"/>\(extra)</sheets></workbook>
        """
        let extraLink = second == nil ? "" : "<Relationship Id='second' Type='\(SemanticPresentationText.relationship)/worksheet' Target='/xl/worksheets/sheet10.xml'/>"
        let sharedLink = strings == nil ? "" : "<Relationship Id='strings' Type='\(SemanticPresentationText.relationship)/sharedStrings' Target='strings.xml'/>"
        let links = relations ?? """
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        \(extraLink)\(sharedLink)<Relationship Id="unused" Type="external" TargetMode="External" Target="http://127.0.0.1:9/must-not-load"/>
        <Relationship Id="first" Type="\(SemanticPresentationText.relationship)/worksheet" Target="worksheets/../worksheets/sheet2.xml"/>
        </Relationships>
        """
        var files = ["xl/worksheets/sheet2.xml": xml, "xl/workbook.xml": order,
                     "xl/_rels/workbook.xml.rels": links,
                     "[Content_Types].xml": """
                     <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
                     <Default Extension="xml" ContentType="application/xml"/>
                     <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
                     <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
                     <Override PartName="/xl/worksheets/sheet2.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
                     </Types>
                     """,
                     "_rels/.rels": "<Relationships xmlns='http://schemas.openxmlformats.org/package/2006/relationships'><Relationship Id='rId1' Type='\(SemanticPresentationText.relationship)/officeDocument' Target='xl/workbook.xml'/></Relationships>"]
        if let second { files["xl/worksheets/sheet10.xml"] = second }
        if let strings { files["xl/strings.xml"] = strings }
        let optionalParts = [("/xl/worksheets/sheet10.xml", "worksheet"), ("/xl/strings.xml", "sharedStrings")]
        for (path, kind) in optionalParts where files[String(path.dropFirst())] != nil {
            files["[Content_Types].xml"] = files["[Content_Types].xml"]?.replacingOccurrences(of: "</Types>",
                with: "<Override PartName='\(path)' ContentType='application/vnd.openxmlformats-officedocument.spreadsheetml.\(kind)+xml'/></Types>")
        }
        for (path, text) in files {
            let url = source.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        let file = root.appendingPathComponent("body-" + UUID().uuidString + ".xlsx")
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
    func `native reader resolves shared inline and cached values in workbook order`(stored: Bool) throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let cells = """
        <c r='A1' t='s'><v>1</v></c><c r='B1' t='inlineStr'><is><r><t><![CDATA[Inline & body]]></t></r><rPh><t>ignoredphonetic</t></rPh></is></c>
        <c r='C1'><f>WEBSERVICE("http://127.0.0.1:9/must-not-load")</f><v>42</v></c>
        <c r='D1' t='str'><f>unexecutedformula</f><v>cachedzebra</v></c><c r='E1'><f>uncachedformula</f></c><c r='Z999' s='1'/>
        <c r='F1' t='b'><v>1</v></c><c r='G1' t='e'><v>#DIV/0!</v></c><c r='H1' t='s'><v>1</v></c>
        """
        let strings = "<sst xmlns='\(SemanticSpreadsheetText.namespace)'><si><t>unusedstring</t></si><si><r><t><![CDATA[INV-]]></t></r><r><t>682914 项目</t></r><rPh><t>ignoredphonetic</t></rPh></si></sst>"
        let file = try fixture(root, document(cells),
            second: document("<c r='A1' t='inlineStr'><is><t>secondsheetzebra</t></is></c>"),
            stored: stored, strings: strings)
        let child = AskFileReader(); defer { child.stop() }
        let result = try child.read(.init(operation: .content, path: file.path, scope: semanticScope(root.path)))
        let local = read(file, root: root)
        #expect(result.pages?.map(\.text) == local.pages?.map(\.text))
        #expect(result.error == nil && result.pages?.first?.page == 1 && result.nextCursor == .init(page: 1))
        let expected = "[1:项目!A1]\tINV-682914 项目\n[1:项目!B1]\tInline & body\n[1:项目!C1]\t42\n"
            + "[1:项目!D1]\tcachedzebra\n[1:项目!F1]\t1\n[1:项目!G1]\t#DIV/0!\n"
            + "[1:项目!H1]\tINV-682914 项目\n"
        #expect(result.pages?.first?.text == expected)
        #expect(result.pages?.first?.segmentKind == "xlsx-sheet" && result.version != nil)
        let second = read(file, root: root, cursor: result.nextCursor)
        #expect(second.pages?.first?.text == "[2:Second!A1]\tsecondsheetzebra\n" && second.nextCursor == nil)
        #expect(SemanticFileStore.documentRecipe(file.path).contains(SemanticSpreadsheetText.recipe))
        #expect(result.pages?.first?.text.contains("formula") == false)
        #expect(result.pages?.first?.text.contains("unusedstring") == false)
        let store = try SemanticFileStore(url: root.appendingPathComponent("index.sqlite"))
        try store.beginRun(reason: .filesystem, configuration: "xlsx-fixture")
        #expect(try store.runDiagnostics()?.extractionGeneration.contains(SemanticSpreadsheetText.recipe) == true)
        _ = try SemanticFileIndexer.run(scope: semanticScope(root.path), store: store, reader: XLSXReader(native: true),
            encoder: SemanticFixtureEncoder(), cancelled: { false }, progress: { _ in })
        for word in ["INV-682914", "cachedzebra", "secondsheetzebra"] {
            let hits = try store.lexicalSearch(text: word, query: .init(word), type: .all,
                scope: semanticScope(root.path), limit: 5, cancelled: { false })
            #expect(hits.first?.path == file.path && hits.first?.evidence?.segmentKind == "xlsx-sheet")
            #expect(hits.first?.evidence?.pageLocalizationKey == "semantic.sheet")
            #expect(hits.first?.evidence?.page == (word == "secondsheetzebra" ? 2 : 1)
                && hits.first?.evidence?.version == result.version)
        }
        if !stored, let destination = ProcessInfo.processInfo.environment["TYPEFLUX_GUL405_XLSX_EVIDENCE"] {
            let folder = URL(fileURLWithPath: destination)
            try FileManager.default.copyItem(at: file, to: folder.appendingPathComponent("synthetic-body.xlsx"))
            try JSONEncoder().encode(result).write(to: folder.appendingPathComponent("native-xlsx-result.json"))
        }
    }

    // swiftlint:disable:next function_body_length
    @Test func `long Unicode body resumes across worker and store restart without reencoding committed vectors`() throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let repeated = String(repeating: "项目 résumé 😀 notes & review ", count: 4500)
        let strings = "<sst xmlns='\(SemanticSpreadsheetText.namespace)'><si><t>firstword "
            + repeated.replacingOccurrences(of: "&", with: "&amp;") + " tailxlsxzebra</t></si></sst>"
        let file = try fixture(root, document("<c r='A1' t='s'><v>0</v></c>"),
            second: document("<c r='A1' t='inlineStr'><is><t>secondsheetzebra</t></is></c>"), strings: strings)
        let splitScalar = Int64("[1:项目!A1]\tfirstword ".utf8.count + 1)
        #expect(read(file, root: root, cursor: .init(offset: splitScalar)).error == EINVAL)
        let first = read(file, root: root)
        var cursor = try #require(first.nextCursor), batches = 1, tail = false
        var complete = Data(first.pages!.first!.text.utf8.prefix(Int(cursor.offset)))
        let child = AskFileReader(); defer { child.stop() }
        repeat {
            let response = try child.read(.init(operation: .content, path: file.path,
                scope: semanticScope(root.path), cursor: cursor))
            try #require(response.error == nil)
            #expect(response.version == first.version && response.pages?.first?.offset == cursor.offset)
            #expect(response.pages!.first!.text.utf8.count <= 32768)
            tail = tail || response.pages!.first!.text.contains("tailxlsxzebra")
            batches += 1
            guard let next = response.nextCursor, next.page == 0 else {
                complete.append(contentsOf: response.pages!.first!.text.utf8); break
            }
            complete.append(contentsOf: response.pages!.first!.text.utf8.prefix(Int(next.offset - cursor.offset)))
            try #require(next.offset > cursor.offset); cursor = next
        } while batches < 20
        #expect(tail && batches > 2)
        #expect(String(data: complete, encoding: .utf8) == "[1:项目!A1]\tfirstword " + repeated + " tailxlsxzebra\n")
        let store = try SemanticFileStore(url: root.appendingPathComponent("index.sqlite"))
        let reader = XLSXReader(native: true), encoder = SemanticFixtureEncoder()
        let token = AskSearchCancellation()
        encoder.after = { if encoder.calls == 2 { token.cancel() } }
        #expect(throws: CancellationError.self) {
            try SemanticFileIndexer.run(scope: semanticScope(root.path), store: store, reader: reader,
                encoder: encoder, cancelled: { token.isCancelled }, progress: { _ in })
        }
        let partial = try #require(try store.job(file.path))
        #expect(partial.state == .partial && partial.cursor.offset > 0)
        let reopened = try SemanticFileStore(url: store.url)
        let resumed = XLSXReader(native: true), resumedEncoder = SemanticFixtureEncoder()
        _ = try SemanticFileIndexer.reconcile(paths: [], scope: semanticScope(root.path), store: reopened,
            reader: resumed, encoder: resumedEncoder, cancelled: { false }, progress: { _ in })
        #expect(resumed.cursors.first == partial.cursor)
        #expect(try reopened.job(file.path)?.state == .done)
        let hits = try reopened.lexicalSearch(text: "tailxlsxzebra", query: .init("tailxlsxzebra"), type: .all,
            scope: semanticScope(root.path), limit: 5, cancelled: { false })
        #expect(hits.first?.path == file.path && hits.first?.evidence?.segmentKind == "xlsx-sheet")
        #expect(hits.first?.evidence?.page == 1 && (hits.first?.evidence?.startOffset ?? 0) > 0)
        let secondHits = try reopened.lexicalSearch(text: "secondsheetzebra",
            query: .init("secondsheetzebra"), type: .all,
            scope: semanticScope(root.path), limit: 5, cancelled: { false })
        #expect(secondHits.first?.evidence?.text.contains("[2:Second!A1]") == true)
        #expect(hits.first?.evidence?.text.contains("tailxlsxzebra") == true)
        let calls = resumedEncoder.calls
        _ = try SemanticFileIndexer.run(scope: semanticScope(root.path), store: reopened, reader: resumed,
            encoder: resumedEncoder, cancelled: { false }, progress: { _ in })
        #expect(resumedEncoder.calls == calls)
    }

    // swiftlint:disable:next function_body_length
    @Test func `two thousand independent shared strings finish with default deadlines and durable restart`() throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let texts = (0..<2000).map { "sharedrow\($0) " + String(repeating: "ordinary spreadsheet value ", count: 3) + "项目 😀" }
        let rows = texts.indices.map {
            "<row r='\($0 + 1)'><c r='A\($0 + 1)' t='s'><v>\($0)</v></c></row>"
        }.joined()
        let worksheet = "<worksheet xmlns='\(SemanticSpreadsheetText.namespace)'><sheetData>"
            + rows + "</sheetData></worksheet>"
        let strings = "<sst xmlns='\(SemanticSpreadsheetText.namespace)'>"
            + texts.map { "<si><t>\($0)</t></si>" }.joined() + "</sst>"
        let file = try fixture(root, worksheet, strings: strings)
        let child = AskFileReader(); defer { child.stop() }
        var cursor: SemanticContentCursor?, complete = Data(), timings: [Double] = [], restarted = false
        repeat {
            let started = ProcessInfo.processInfo.systemUptime
            let response = try child.read(.init(operation: .content, path: file.path,
                scope: semanticScope(root.path), cursor: cursor))
            timings.append(ProcessInfo.processInfo.systemUptime - started)
            try #require(response.error == nil)
            let page = try #require(response.pages?.first)
            #expect(page.text.utf8.count <= 32768 && page.segmentKind == "xlsx-sheet")
            let old = cursor?.offset ?? 0
            let count = response.nextCursor.map { Int($0.offset - old) } ?? page.text.utf8.count
            complete.append(contentsOf: page.text.utf8.prefix(count))
            if let next = response.nextCursor { try #require(next.offset > old) }
            cursor = response.nextCursor
            if !restarted { child.stop(); restarted = true }
        } while cursor != nil
        let expected = texts.indices.map { "[1:项目!A\($0 + 1)]\t\(texts[$0])\n" }.joined()
        #expect(String(data: complete, encoding: .utf8) == expected)
        #expect(timings.count > 2 && timings.dropFirst().allSatisfy { $0 < 5 })
        let store = try SemanticFileStore(url: root.appendingPathComponent("index.sqlite"))
        let reader = XLSXReader(native: true), encoder = SemanticFixtureEncoder(), token = AskSearchCancellation()
        encoder.after = { if encoder.calls == 2 { token.cancel() } }
        #expect(throws: CancellationError.self) {
            try SemanticFileIndexer.run(scope: semanticScope(root.path), store: store, reader: reader,
                encoder: encoder, cancelled: { token.isCancelled }, progress: { _ in })
        }
        let partial = try #require(try store.job(file.path))
        let count = try store.counts().chunks
        #expect(partial.state == .partial && partial.cursor.offset > 0)
        let reopened = try SemanticFileStore(url: store.url), resumed = XLSXReader(native: true)
        let resumedEncoder = SemanticFixtureEncoder()
        _ = try SemanticFileIndexer.reconcile(paths: [], scope: semanticScope(root.path), store: reopened,
            reader: resumed, encoder: resumedEncoder, cancelled: { false }, progress: { _ in })
        let resumedCount = try reopened.counts().chunks
        #expect(resumed.cursors.first == partial.cursor && resumedCount > count)
        #expect(try reopened.job(file.path)?.state == .done)
        let hits = try reopened.lexicalSearch(text: "sharedrow1999", query: .init("sharedrow1999"), type: .all,
            scope: semanticScope(root.path), limit: 5, cancelled: { false })
        #expect(hits.first?.path == file.path)
        if let folder = ProcessInfo.processInfo.environment["TYPEFLUX_GUL405_XLSX_REPAIR_EVIDENCE"] {
            let destination = URL(fileURLWithPath: folder)
            try FileManager.default.copyItem(at: file, to: destination.appendingPathComponent("shared-2000.xlsx"))
            try JSONEncoder().encode(timings).write(to: destination.appendingPathComponent("shared-2000-seconds.json"))
        }
    }

    @Test func `cross sheet restart keeps committed first sheet vectors`() throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let file = try fixture(root, document("<c r='A1' t='inlineStr'><is><t>firstsheetzebra</t></is></c>"),
                               second: document("<c r='A1' t='inlineStr'><is><t>lastsheetzebra</t></is></c>"))
        let store = try SemanticFileStore(url: root.appendingPathComponent("index.sqlite"))
        let reader = XLSXReader(), encoder = SemanticFixtureEncoder(), token = AskSearchCancellation()
        reader.after = { [weak reader] in if reader?.cursors.count == 2 { token.cancel() } }
        #expect(throws: CancellationError.self) {
            try SemanticFileIndexer.run(scope: semanticScope(root.path), store: store, reader: reader,
                encoder: encoder, cancelled: { token.isCancelled }, progress: { _ in })
        }
        #expect(try store.job(file.path)?.cursor == .init(page: 1) && encoder.calls == 1)
        let reopened = try SemanticFileStore(url: store.url)
        let resumed = XLSXReader(), resumedEncoder = SemanticFixtureEncoder()
        _ = try SemanticFileIndexer.reconcile(paths: [], scope: semanticScope(root.path), store: reopened,
            reader: resumed, encoder: resumedEncoder, cancelled: { false }, progress: { _ in })
        #expect(resumed.cursors == [.init(page: 1)] && resumedEncoder.calls == 1)
        let hits = try reopened.lexicalSearch(text: "lastsheetzebra", query: .init("lastsheetzebra"), type: .all,
            scope: semanticScope(root.path), limit: 5, cancelled: { false })
        #expect(try reopened.job(file.path)?.state == .done)
        #expect(hits.first?.evidence?.text.contains("[2:Second!A1]") == true)
    }

    @Test func `completed PPTX era discovery adds XLSX and preserves compatible vectors`() throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let file = try fixture(root, document("<c r='A1' t='inlineStr'><is><t>newxlsxzebra</t></is></c>"))
        let plain = root.appendingPathComponent("unchanged.txt")
        try Data("compatibletextzebra".utf8).write(to: plain)
        let store = try SemanticFileStore(url: root.appendingPathComponent("index.sqlite"))
        let scope = semanticScope(root.path), reader = XLSXReader(), encoder = SemanticFixtureEncoder()
        _ = try SemanticFileIndexer.reconcile(paths: [plain.path], scope: scope, store: store, reader: reader,
            encoder: encoder, cancelled: { false }, progress: { _ in })
        let calls = encoder.calls
        let oldFormats = SemanticFilePolicy.extensions.subtracting(["xlsx"]).sorted()
        let groups = [scope.roots, scope.excludedPaths, scope.excludedFolderNames.sorted(),
                      scope.excludedExtensions.sorted(), scope.blocked, [String(scope.includeHidden)], oldFormats]
        let oldKey = String(data: try JSONEncoder().encode(groups), encoding: .utf8)!
        let oldScanKey = String(data: try JSONEncoder().encode(groups + [["/"]]), encoding: .utf8)!
        try store.lock.withLock {
            try store.execute("INSERT INTO scan_checkpoint VALUES(?,?,?)", [oldKey, 100, "xlsx-fixture"])
            try store.execute("INSERT INTO scan_scope VALUES(?)", [oldScanKey])
            try store.execute("INSERT INTO scan_directories VALUES(?,'done')", [root.path])
        }
        #expect(try store.completedEventID(scope: scope, volumeSignature: "xlsx-fixture") == nil)
        _ = try SemanticFileIndexer.run(scope: scope, store: store, reader: reader, encoder: encoder,
            cancelled: { false }, progress: { _ in })
        #expect(try store.job(file.path)?.state == .done && encoder.calls == calls + 1)
        #expect(SemanticFileStore.documentRecipe(plain.path) == SemanticFileStore.documentProvenance)
    }

    @Test(arguments: ["cancel", "replace", "permission"])
    func `cancellation replacement and permission revocation prevent publication`(action: String) throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let file = try fixture(root, document("<c r='A1' t='inlineStr'><is><t>notpublishedzebra</t></is></c>"))
        let store = try SemanticFileStore(url: root.appendingPathComponent("index.sqlite"))
        let reader = XLSXReader(), encoder = SemanticFixtureEncoder()
        let token = AskSearchCancellation()
        reader.after = {
            if action == "replace" {
                try? Data(document("<c r='A1' t='inlineStr'><is><t>replacement</t></is></c>").utf8).write(to: file)
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
            ? "<!DOCTYPE x [<!ENTITY x SYSTEM 'http://127.0.0.1:9/must-not-load'>]>" + document("<c r='A1' t='inlineStr'><is><t>&x;</t></is></c>")
            : document("<c r='A1' t='inlineStr'><is><t>healthy</t></is></c>")
        let target = kind == "external" ? "http://127.0.0.1:9/must-not-load" : "../../../../must-not-load.xml"
        let relation = "<Relationship Id='first' Type='\(SemanticPresentationText.relationship)/worksheet' Target='\(target)' \(kind == "external" ? "TargetMode='External'" : "")/>"
        let relations = ["external", "escape", "duplicate", "missing"].contains(kind)
            ? "<Relationships xmlns='\(SemanticPresentationText.package)'>"
                + (kind == "missing" ? "" : relation) + (kind == "duplicate" ? relation : "") + "</Relationships>" : nil
        let file = try fixture(root, xml, relations: relations)
        var data = try Data(contentsOf: file)
        let nameRange = try #require(data.range(of: Data("xl/worksheets/sheet2.xml".utf8), options: .backwards))
        let central = nameRange.lowerBound - 46
        if kind == "encrypted" {
            data[central + 8] |= 1
        } else if kind == "zip64" {
            data.replaceSubrange(central + 24 ..< central + 28, with: [255, 255, 255, 255])
        } else if kind == "crc" { data[central + 16] ^= 1 }
        try data.write(to: file)
        let store = try SemanticFileStore(url: root.appendingPathComponent("index.sqlite"))
        let reader = XLSXReader(), encoder = SemanticFixtureEncoder()
        let reason = kind == "encrypted" ? "password-required" : ["dtd", "escape", "zip64"].contains(kind)
            ? "unsupported-document" : "unreadable-content"
        for _ in 0..<2 {
            _ = try SemanticFileIndexer.reconcile(paths: [file.path], scope: semanticScope(root.path), store: store,
                reader: reader, encoder: encoder, cancelled: { false }, progress: { _ in })
            #expect(try store.job(file.path)?.state == .failed && store.job(file.path)?.reason == reason)
        }
        #expect(encoder.calls == 0 && reader.cursors.count == 2)
        let repaired = try fixture(root, document("<c r='A1' t='inlineStr'><is><t>repairedxlsxzebra</t></is></c>"))
        try Data(contentsOf: repaired).write(to: file)
        _ = try SemanticFileIndexer.reconcile(paths: [file.path], scope: semanticScope(root.path), store: store,
            reader: reader, encoder: encoder, cancelled: { false }, progress: { _ in })
        #expect(try store.job(file.path)?.state == .done && encoder.calls == 1)
    }

    @Test(arguments: ["missing", "invalid", "range", "external", "dtd", "duplicate"])
    func `shared string failures never index reference numbers`(kind: String) throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let reference = kind == "invalid" ? "not-an-index" : kind == "range" ? "99" : "0"
        let strings = "<sst xmlns='\(SemanticSpreadsheetText.namespace)'><si><t>safe</t></si></sst>"
        var links: String?
        if kind == "external" || kind == "duplicate" {
            let shared = "<Relationship Id='s' Type='\(SemanticPresentationText.relationship)/sharedStrings' Target='http://127.0.0.1:9/must-not-load' TargetMode='External'/>"
            let duplicate = "<Relationship Id='first' Type='\(SemanticPresentationText.relationship)/sharedStrings' Target='strings.xml'/>"
            links = "<Relationships xmlns='\(SemanticPresentationText.package)'><Relationship Id='first' Type='\(SemanticPresentationText.relationship)/worksheet' Target='worksheets/sheet2.xml'/>"
                + (kind == "external" ? shared : duplicate) + "</Relationships>"
        }
        let body = kind == "dtd" ? "<!DOCTYPE x [<!ENTITY x 'x'>]>" + strings : strings
        let file = try fixture(root, document("<c r='A1' t='s'><v>\(reference)</v></c>"),
            relations: links, strings: kind == "missing" ? nil : body)
        let response = read(file, root: root)
        #expect(response.error == (kind == "dtd" ? ENOTSUP : EILSEQ) && response.pages == nil)
    }

    @Test func `empty sheets invalid cursors and strict namespaces remain deterministic`() throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        // A final body between the response limit and parser lookahead must still return a cursor.
        let nearLimit = String(repeating: "x", count: 32768 - "[1:项目!A1]\t".utf8.count)
        let boundary = try fixture(root, document("<c r='A1' t='inlineStr'><is><t>\(nearLimit)</t></is></c>"))
        let firstBoundary = read(boundary, root: root)
        let nextBoundary = try #require(firstBoundary.nextCursor)
        let lastBoundary = read(boundary, root: root, cursor: nextBoundary)
        #expect(firstBoundary.pages?.first?.text.utf8.count == 32768)
        let joined = Data(firstBoundary.pages!.first!.text.utf8.prefix(Int(nextBoundary.offset)))
            + Data(lastBoundary.pages!.first!.text.utf8)
        #expect(String(data: joined, encoding: .utf8) == "[1:项目!A1]\t" + nearLimit + "\n")
        #expect(lastBoundary.nextCursor == nil)
        let empty = try fixture(root, document(""))
        #expect(read(empty, root: root).pages?.first?.text == "")
        #expect(AskFileHit.Evidence(text: "PDF", page: 1).pageLocalizationKey == "semantic.page")
        #expect(read(empty, root: root, cursor: .init(page: 1)).pages?.isEmpty == true)
        let file = try fixture(root, document("<c r='A1' t='inlineStr'><is><t>汉字</t></is></c>"))
        let invalid = [SemanticContentCursor(page: 2), .init(page: 1, offset: 1),
                       .init(offset: 4), .init(offset: 99), .init(offset: Int64.max)]
        for cursor in invalid {
            #expect(read(file, root: root, cursor: cursor).error == EINVAL)
        }
        let strict = document("<c r='A1' t='inlineStr'><is><t>strictzebra</t></is></c>")
            .replacingOccurrences(of: "http://schemas.openxmlformats.org/", with: "http://purl.oclc.org/ooxml/")
            .replacingOccurrences(of: "/2006", with: "")
        #expect(read(try fixture(root, strict), root: root).pages?.first?.text == "[1:项目!A1]\tstrictzebra\n")
        #expect(read(try fixture(root, "<sld/>"), root: root).error == EILSEQ)
    }

    @Test @MainActor func `both result entries label worksheet ordinals without PDF page claims`() async throws {
        let language = AppLocalization.shared.language
        AppLocalization.shared.setLanguage(.simplifiedChinese)
        defer { AppLocalization.shared.setLanguage(language) }
        let evidence = AskFileHit.Evidence(text: "[2:预算!A1] cachedzebra", page: 2, segmentKind: "xlsx-sheet")
        let hit = AskFileHit(path: "/tmp/Synthetic.xlsx", name: "Synthetic.xlsx", kind: .file,
                             modified: Date(timeIntervalSince1970: 1), score: 1, evidence: evidence)
        let item = AskFileSearchPlugin.item(hit)
        #expect(item.subtitle.contains("工作表 2"))
        #expect(!item.subtitle.contains("第 2 页"))
        let results = try #require(AskQuickResults.assemble("cachedzebra", matches: [], hits: [hit], status: nil,
                                                           settings: .init()))
        let mixed = AskQuickResultsView(results: results, question: "cachedzebra", onRun: { _, _ in },
                                       onHighlight: { _ in })
        let views = [("xlsx-keyword", AnyView(AskPluginItemRow(item: item, symbol: "doc", selected: true,
            emphasized: true, height: AskPluginResultsView.itemHeight(item), onPick: {}))),
            ("xlsx-mixed", AnyView(mixed.contentMatch(hit, evidence: evidence, highlighted: false)))]
        _ = NSApplication.shared
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 640, height: 150), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil); window.close() }
        for (name, view) in views {
            for (scheme, appearance) in [(ColorScheme.light, NSAppearance.Name.aqua), (.dark, .darkAqua)] {
                window.appearance = NSAppearance(named: appearance)
                let host = NSHostingView(rootView: view.padding(12).frame(width: 640)
                    .fixedSize(horizontal: false, vertical: true).background(StudioTheme.background)
                    .environment(\.colorScheme, scheme))
                window.setContentSize(host.fittingSize); window.contentView = host; window.orderFront(nil)
                try await Task.sleep(for: .milliseconds(100)); host.layoutSubtreeIfNeeded()
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                #expect(bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0)
                if let folder = ProcessInfo.processInfo.environment["TYPEFLUX_GUL405_XLSX_EVIDENCE"],
                   let data = bitmap.representation(using: .png, properties: [:]) {
                    try data.write(to: URL(fileURLWithPath: folder).appendingPathComponent(
                        "\(name)-\(scheme == .light ? "light" : "dark").png"))
                }
            }
        }
    }
}
