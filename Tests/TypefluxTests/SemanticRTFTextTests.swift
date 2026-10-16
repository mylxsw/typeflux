import Darwin
import Foundation
import Testing
@testable import Typeflux

private final class RTFReader: AskFileReading {
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

@Suite("Offline RTF body and durable continuation", .serialized)
struct SemanticRTFTextTests {
    private func fixture(_ root: URL, _ text: String, ext: String = "rtf") throws -> URL {
        let file = root.appendingPathComponent("body-" + UUID().uuidString + "." + ext)
        try Data(text.utf8).write(to: file)
        return file
    }

    private func read(_ file: URL, root: URL, cursor: SemanticContentCursor? = nil) -> AskFileReadResponse {
        AskFileWorkerCommand.handle(.init(operation: .content, path: file.path,
                                         scope: semanticScope(root.path), cursor: cursor))
    }

    private func document(_ text: String) -> String {
        let units = text.utf16.map { unit -> String in
            if unit >= 32, unit < 127, ![92, 123, 125].contains(unit) { return String(UnicodeScalar(unit)!) }
            return "\\u\(Int(Int16(bitPattern: unit)))?"
        }.joined()
        return "{\\rtf1\\ansi\\uc1 " + units + "}"
    }

    @Test func `native reader extracts body without importing objects or link instructions`() throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let source = #"{\rtf1\ansi\ansicpg1252\deff0{\fonttbl{\f0\fnil\fcharset0 Arial;}}{"# +
            #"\colortbl;\red255\green0\blue0;}\f0\b Invoice\b0\tab INV-682914\par "# +
            #"\u27721?\u23383? \u-10179?\u-8704? r\'e9sum\'e9 \{ok\} \\{"# +
            #"\info hiddeninfo}{\pict hiddenimage}{\object hiddenobject}{\*"# +
            #"\unknown hiddendestination}{\field{\*"# +
            #"\fldinst HYPERLINK "http://127.0.0.1:9/no-load"}{\fldrslt visible link}}{"# +
            #"\v hiddenbody}\line second\cell column\row end}"#
        let file = try fixture(root, source)
        let child = AskFileReader(timeout: 15); defer { child.stop() }
        let result = try child.read(.init(operation: .content, path: file.path, scope: semanticScope(root.path)))
        let expected = "Invoice\tINV-682914\n汉字 😀 résumé {ok} \\visible link\nsecond\tcolumn\nend"
        #expect(result.error == nil && result.nextCursor == nil && result.pages?.first?.text == expected)
        #expect(read(file, root: root).pages?.first?.text == expected)
        #expect(result.pages?.first?.segmentKind == "rtf-body" && result.pages?.first?.page == nil)
        #expect(SemanticFilePolicy.allows(file.path) && SemanticMediaPriority.of(file.path) == .document)
        #expect(SemanticFileStore.documentRecipe(file.path).contains(SemanticRTFText.recipe))
        if let destination = ProcessInfo.processInfo.environment["TYPEFLUX_GUL405_RTF_EVIDENCE"] {
            let folder = URL(fileURLWithPath: destination)
            try FileManager.default.copyItem(at: file, to: folder.appendingPathComponent("synthetic-body.rtf"))
            try JSONEncoder().encode(result).write(to: folder.appendingPathComponent("native-rtf-result.json"))
        }
    }

    @Test func `long Unicode body resumes across worker and store restart without reencoding committed vectors`() throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let repeated = String(repeating: "项目 résumé 😀 notes & review ", count: 4500)
        let file = try fixture(root, document("firstword " + repeated + " tailrtfzebra"))
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
            tail = tail || response.pages!.first!.text.contains("tailrtfzebra")
            batches += 1
            guard let next = response.nextCursor else {
                complete.append(contentsOf: response.pages!.first!.text.utf8); break
            }
            complete.append(contentsOf: response.pages!.first!.text.utf8.prefix(Int(next.offset - cursor.offset)))
            try #require(next.offset > cursor.offset); cursor = next
        } while batches < 20
        #expect(tail && batches > 2)
        #expect(String(data: complete, encoding: .utf8) == "firstword " + repeated + " tailrtfzebra")
        let store = try SemanticFileStore(url: root.appendingPathComponent("index.sqlite"))
        let reader = RTFReader(native: true), encoder = SemanticFixtureEncoder()
        let token = AskSearchCancellation()
        encoder.after = { if encoder.calls == 2 { token.cancel() } }
        #expect(throws: CancellationError.self) {
            try SemanticFileIndexer.run(scope: semanticScope(root.path), store: store, reader: reader,
                encoder: encoder, cancelled: { token.isCancelled }, progress: { _ in })
        }
        let partial = try #require(try store.job(file.path))
        #expect(partial.state == .partial && partial.cursor.offset > 0)
        let reopened = try SemanticFileStore(url: store.url)
        let resumed = RTFReader(native: true), resumedEncoder = SemanticFixtureEncoder()
        _ = try SemanticFileIndexer.reconcile(paths: [], scope: semanticScope(root.path), store: reopened,
            reader: resumed, encoder: resumedEncoder, cancelled: { false }, progress: { _ in })
        #expect(resumed.cursors.first == partial.cursor)
        #expect(try reopened.job(file.path)?.state == .done)
        let hits = try reopened.lexicalSearch(text: "tailrtfzebra", query: .init("tailrtfzebra"), type: .all,
            scope: semanticScope(root.path), limit: 5, cancelled: { false })
        #expect(hits.first?.path == file.path && hits.first?.evidence?.segmentKind == "rtf-body")
        #expect(hits.first?.evidence?.text.contains("tailrtfzebra") == true)
        let calls = resumedEncoder.calls
        _ = try SemanticFileIndexer.run(scope: semanticScope(root.path), store: reopened, reader: resumed,
            encoder: resumedEncoder, cancelled: { false }, progress: { _ in })
        #expect(resumedEncoder.calls == calls)
    }

    @Test func `completed HTML era discovery adds RTF and preserves compatible vectors`() throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let file = try fixture(root, document("newrtfzebra"))
        let plain = root.appendingPathComponent("unchanged.txt")
        try Data("compatibletextzebra".utf8).write(to: plain)
        let store = try SemanticFileStore(url: root.appendingPathComponent("index.sqlite"))
        let scope = semanticScope(root.path), reader = RTFReader(), encoder = SemanticFixtureEncoder()
        _ = try SemanticFileIndexer.reconcile(paths: [plain.path], scope: scope, store: store, reader: reader,
            encoder: encoder, cancelled: { false }, progress: { _ in })
        let calls = encoder.calls
        let oldFormats = SemanticFilePolicy.extensions.subtracting(["rtf"]).sorted()
        let groups = [scope.roots, scope.excludedPaths, scope.excludedFolderNames.sorted(),
                      scope.excludedExtensions.sorted(), scope.blocked, [String(scope.includeHidden)], oldFormats]
        let oldKey = String(data: try JSONEncoder().encode(groups), encoding: .utf8)!
        let oldScanKey = String(data: try JSONEncoder().encode(groups + [["/"]]), encoding: .utf8)!
        try store.lock.withLock {
            try store.execute("INSERT INTO scan_checkpoint VALUES(?,?,?)", [oldKey, 100, "rtf-fixture"])
            try store.execute("INSERT INTO scan_scope VALUES(?)", [oldScanKey])
            try store.execute("INSERT INTO scan_directories VALUES(?,'done')", [root.path])
        }
        #expect(try store.completedEventID(scope: scope, volumeSignature: "rtf-fixture") == nil)
        _ = try SemanticFileIndexer.run(scope: scope, store: store, reader: reader, encoder: encoder,
            cancelled: { false }, progress: { _ in })
        #expect(try store.job(file.path)?.state == .done && encoder.calls == calls + 1)
        #expect(SemanticFileStore.documentRecipe(plain.path) == SemanticFileStore.documentProvenance)
    }

    @Test(arguments: ["cancel", "replace", "permission"])
    func `cancellation replacement and permission revocation prevent publication`(action: String) throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let file = try fixture(root, document("notpublishedzebra"))
        let store = try SemanticFileStore(url: root.appendingPathComponent("index.sqlite"))
        let reader = RTFReader(), encoder = SemanticFixtureEncoder()
        let token = AskSearchCancellation()
        reader.after = {
            if action == "replace" {
                try? Data(document("replacement").utf8).write(to: file)
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

    @Test func `damaged and unsupported documents retain fixed reasons and recover on version retry`() throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        for (source, reason) in [(#"{\rtf1\ansi\ansicpg932 body}"#, "unsupported-document"),
                                 (#"{\rtf1\ansi truncated"#, "unreadable-content")] {
            let file = try fixture(root, source)
            let store = try SemanticFileStore(url: root.appendingPathComponent(UUID().uuidString + ".sqlite"))
            let reader = RTFReader(), encoder = SemanticFixtureEncoder()
            for _ in 0..<2 {
                _ = try SemanticFileIndexer.reconcile(paths: [file.path], scope: semanticScope(root.path), store: store,
                    reader: reader, encoder: encoder, cancelled: { false }, progress: { _ in })
                #expect(try store.job(file.path)?.state == .failed && store.job(file.path)?.reason == reason)
            }
            #expect(encoder.calls == 0)
            try Data(document("repairedrtfzebra").utf8).write(to: file)
            _ = try SemanticFileIndexer.reconcile(paths: [file.path], scope: semanticScope(root.path), store: store,
                reader: reader, encoder: encoder, cancelled: { false }, progress: { _ in })
            #expect(try store.job(file.path)?.state == .done && encoder.calls == 1)
        }
    }

    @Test func `chinese codepages font overrides Unicode scope and binary destinations decode offline`() throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let cases = [
            (#"{\rtf1\ansi\ansicpg936 \'d6\'d0\'ce\'c4}"#, "中文"),
            (#"{\rtf1\ansi\ansicpg950 \'a4\'a4\'a4\'e5}"#, "中文"),
            (#"{\rtf1\ansi\deff0{\fonttbl{\f0\fcharset0 Latin;}{\f1"# +
            #"\fcharset134 Chinese;}{\f2\cpg950 Traditional;}}\f1 \'d6\'d0\'ce\'c4\f2 "# +
            #"\'a4\'a4\plain \'e9}"#, "中文中é"),
            (#"{\rtf1\ansi\uc1 \u27721?{\uc2\u23383??}\u20013?{\uc0\u25991} \~\-\_\emdash"# +
            #"\endash\bullet\lquote\rquote\ldblquote\rdblquote}"#,
             "汉字中文 \u{a0}\u{ad}\u{2011}—–•‘’“”"),
            (#"{\rtf1 a{\pict\bin4 {}\\}b\v hidden\v0 c}"#, "abc"),
            (#"{\rtf1\uc1\u27721\~\u23383\'3f}"#, "汉字"),
            ("{\\rtf1 a\n\rb} \r\n", "ab"),
            (#"{\rtf1}"#, "")
        ]
        for (source, expected) in cases {
            let response = read(try fixture(root, source), root: root)
            #expect(response.error == nil && response.pages?.first?.text == expected)
        }
        let boundary = try fixture(root, #"{\rtf1 {\pict "# + String(repeating: "f", count: 20000) + "}tail}")
        #expect(read(boundary, root: root).pages?.first?.text == "tail")
        let raw = try fixture(root, "")
        // GBK U+4E57 uses a raw backslash trail, which must not become an RTF control.
        var rawBytes = Data(#"{\rtf1\ansicpg936 "#.utf8)
        rawBytes.append(contentsOf: [0x81, 0x5C, 0xD6, 0xD0, 0xCE, 0xC4, 0x7D])
        try rawBytes.write(to: raw)
        #expect(read(raw, root: root).pages?.first?.text == "乗中文")
        let file = try fixture(root, document("汉字"))
        for cursor in [SemanticContentCursor(page: 1), .init(offset: 1), .init(offset: 99), .init(offset: -1)] {
            #expect(read(file, root: root, cursor: cursor).error == EINVAL)
        }
    }

    @Test func `malformed syntax unsupported charsets and invalid Unicode fail deterministically`() throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        for source in ["", "plain", #"{\rtf12 bad}"#, #"{\rtf1 body}trailing"#, #"{\rtf1 \'zz}"#,
                       #"{\rtf1\bin99 short}"#, #"{\rtf1\bin-1 x}"#, #"{\rtf1\bin x}"#,
                       #"{\rtf1\uc-1 x}"#, #"{\rtf1\u99999?}"#, #"{\rtf1\u-10179?}"#,
                       #"{\rtf1\u-8704?}"#, #"{\rtf1\u-10179?\u-10179?}"#, #"{\rtf1\u-10179?x}"#,
                       #"{\rtf1\ansicpg936\'d6}"#, #"{\rtf1\u0?}"#,
                       #"{\rtf1\aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa}"#, #"{\rtf1\fs99999999999 x}"#,
                       "{\\rtf1\u{0}}", "{\\rtf1 tail\\"] {
            #expect(read(try fixture(root, source), root: root).error == EILSEQ)
        }
        for source in [#"{\rtf1\mac x}"#, #"{\rtf1\upr x}"#,
                       #"{\rtf1{\fonttbl{\f1\fcharset128 Japanese;}}\f1\'aa}"#,
                       "{\\rtf1" + String(repeating: "{", count: 256)] {
            #expect(read(try fixture(root, source), root: root).error == ENOTSUP)
        }
    }
}
