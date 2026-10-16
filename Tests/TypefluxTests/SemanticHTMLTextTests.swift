import Darwin
import Foundation
import Testing
@testable import Typeflux

private final class HTMLReader: AskFileReading {
    var cursors: [SemanticContentCursor] = []
    var after: (() -> Void)?
    func read(_ request: AskFileReadRequest, isCancelled: () -> Bool) throws -> AskFileReadResponse {
        if isCancelled() { throw CancellationError() }
        let response = AskFileWorkerCommand.handle(request)
        if request.operation == .content, request.readText {
            cursors.append(request.cursor ?? .init()); after?()
        }
        return response
    }
}

@Suite("Offline HTML body and durable continuation", .serialized)
struct SemanticHTMLTextTests {
    private func fixture(_ root: URL, _ text: String, ext: String = "html") throws -> URL {
        let file = root.appendingPathComponent("body-" + UUID().uuidString + "." + ext)
        try Data(text.utf8).write(to: file)
        return file
    }

    private func read(_ file: URL, root: URL, cursor: SemanticContentCursor? = nil) -> AskFileReadResponse {
        AskFileWorkerCommand.handle(.init(operation: .content, path: file.path,
                                         scope: semanticScope(root.path), cursor: cursor))
    }

    @Test(arguments: ["html", "htm"])
    func `native reader extracts offline body and ignores resources scripts metadata and objects`(ext: String) throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let file = try fixture(root, """
        <!doctype html><HTML><head><title>hidden title</title><style>p:before{content:'hiddenstyle'}</style>
        <link href="http://127.0.0.1:9/no-load"></head><body>
        <!-- hiddencomment --><h1>项目报销</h1><p>INV-682914 &amp; résumé &#x1F600; &#27721;&#23383;</p>
        <script src="http://127.0.0.1:9/no-load">if(a<b){document.write('hiddenjavascript')}; '</scriptx>';</SCRIPT >
        <template>hiddentemplate<template>hiddennested</template>hiddenagain</template>
        <iframe src="file:///must-not-open">hiddenframe</iframe><object data="file:///must-not-open">hiddenobject</object>
        <nav>hiddennav</nav><ul><li>approved</li></ul><p title="a > b">second<br>line</p>
        <img src="http://127.0.0.1:9/no-load"><a href="file:///must-not-open">visible link</a>
        </body></HTML>
        """, ext: ext)
        let child = AskFileReader(timeout: 15); defer { child.stop() }
        let result = try child.read(.init(operation: .content, path: file.path, scope: semanticScope(root.path)))
        #expect(result.error == nil && result.nextCursor == nil)
        #expect(result.pages?.first?.text == "# 项目报销\nINV-682914 & résumé 😀 汉字\n- approved\nsecond\nline\nvisible link")
        #expect(result.pages?.first?.segmentKind == "html-body" && result.pages?.first?.page == nil)
        #expect(SemanticFilePolicy.allows(file.path) && SemanticMediaPriority.of(file.path) == .document)
        #expect(SemanticFileStore.documentRecipe(file.path).contains(SemanticHTMLText.recipe))
        if ext == "html", let destination = ProcessInfo.processInfo.environment["TYPEFLUX_GUL405_HTML_EVIDENCE"] {
            let folder = URL(fileURLWithPath: destination)
            try FileManager.default.copyItem(at: file, to: folder.appendingPathComponent("synthetic-body.html"))
            try JSONEncoder().encode(result).write(to: folder.appendingPathComponent("native-html-result.json"))
        }
    }

    @Test func `long Unicode body resumes across worker and store restart without reencoding committed vectors`() throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let repeated = String(repeating: "项目 résumé &#x1F600; notes &amp; review ", count: 4500)
        let file = try fixture(root, "<p>firstword " + repeated
            + " tailhtmlzebra</p>")
        let first = read(file, root: root)
        var cursor = try #require(first.nextCursor), batches = 1, tail = false
        let child = AskFileReader(timeout: 15); defer { child.stop() }
        repeat {
            let response = try child.read(.init(operation: .content, path: file.path,
                scope: semanticScope(root.path), cursor: cursor))
            try #require(response.error == nil)
            #expect(response.version == first.version && response.pages?.first?.offset == cursor.offset)
            #expect(response.pages!.first!.text.utf8.count <= 32768)
            tail = tail || response.pages!.first!.text.contains("tailhtmlzebra")
            batches += 1
            guard let next = response.nextCursor else { break }
            try #require(next.offset > cursor.offset); cursor = next
        } while batches < 20
        #expect(tail && batches > 2)
        let store = try SemanticFileStore(url: root.appendingPathComponent("index.sqlite"))
        let reader = HTMLReader(), encoder = SemanticFixtureEncoder()
        let token = AskSearchCancellation()
        encoder.after = { if encoder.calls == 2 { token.cancel() } }
        #expect(throws: CancellationError.self) {
            try SemanticFileIndexer.run(scope: semanticScope(root.path), store: store, reader: reader,
                encoder: encoder, cancelled: { token.isCancelled }, progress: { _ in })
        }
        let partial = try #require(try store.job(file.path))
        #expect(partial.state == .partial && partial.cursor.offset > 0)
        let reopened = try SemanticFileStore(url: store.url)
        let resumed = HTMLReader(), resumedEncoder = SemanticFixtureEncoder()
        _ = try SemanticFileIndexer.reconcile(paths: [], scope: semanticScope(root.path), store: reopened,
            reader: resumed, encoder: resumedEncoder, cancelled: { false }, progress: { _ in })
        #expect(resumed.cursors.first == partial.cursor)
        #expect(try reopened.job(file.path)?.state == .done)
        let hits = try reopened.lexicalSearch(text: "tailhtmlzebra", query: .init("tailhtmlzebra"), type: .all,
            scope: semanticScope(root.path), limit: 5, cancelled: { false })
        #expect(hits.first?.path == file.path && hits.first?.evidence?.segmentKind == "html-body")
        #expect(hits.first?.evidence?.text.contains("tailhtmlzebra") == true)
        let calls = resumedEncoder.calls
        _ = try SemanticFileIndexer.run(scope: semanticScope(root.path), store: reopened, reader: resumed,
            encoder: resumedEncoder, cancelled: { false }, progress: { _ in })
        #expect(resumedEncoder.calls == calls)
    }

    @Test func `completed DOCX era discovery adds HTML and preserves compatible vectors`() throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let file = try fixture(root, "<p>newhtmlzebra</p>")
        let plain = root.appendingPathComponent("unchanged.txt")
        try Data("compatibletextzebra".utf8).write(to: plain)
        let store = try SemanticFileStore(url: root.appendingPathComponent("index.sqlite"))
        let scope = semanticScope(root.path), reader = HTMLReader(), encoder = SemanticFixtureEncoder()
        _ = try SemanticFileIndexer.reconcile(paths: [plain.path], scope: scope, store: store, reader: reader,
            encoder: encoder, cancelled: { false }, progress: { _ in })
        let calls = encoder.calls
        let oldFormats = SemanticFilePolicy.extensions.subtracting(["html", "htm"]).sorted()
        let groups = [scope.roots, scope.excludedPaths, scope.excludedFolderNames.sorted(),
                      scope.excludedExtensions.sorted(), scope.blocked, [String(scope.includeHidden)], oldFormats]
        let oldKey = String(data: try JSONEncoder().encode(groups), encoding: .utf8)!
        let oldScanKey = String(data: try JSONEncoder().encode(groups + [["/"]]), encoding: .utf8)!
        try store.lock.withLock {
            try store.execute("INSERT INTO scan_checkpoint VALUES(?,?,?)", [oldKey, 100, "html-fixture"])
            try store.execute("INSERT INTO scan_scope VALUES(?)", [oldScanKey])
            try store.execute("INSERT INTO scan_directories VALUES(?,'done')", [root.path])
        }
        #expect(try store.completedEventID(scope: scope, volumeSignature: "html-fixture") == nil)
        _ = try SemanticFileIndexer.run(scope: scope, store: store, reader: reader, encoder: encoder,
            cancelled: { false }, progress: { _ in })
        #expect(try store.job(file.path)?.state == .done && encoder.calls == calls + 1)
        #expect(SemanticFileStore.documentRecipe(plain.path) == SemanticFileStore.documentProvenance)
    }

    @Test(arguments: ["cancel", "replace", "permission"])
    func `cancellation replacement and permission revocation prevent publication`(action: String) throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let file = try fixture(root, "<p>notpublishedzebra</p>")
        let store = try SemanticFileStore(url: root.appendingPathComponent("index.sqlite"))
        let reader = HTMLReader(), encoder = SemanticFixtureEncoder()
        let token = AskSearchCancellation()
        reader.after = {
            if action == "replace" {
                try? Data("<p>replacement</p>".utf8).write(to: file)
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

    @Test func `bad encodings persist fixed reasons and explicit retry recovers`() throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        for (data, reason) in [(Data([0xFF, 0xFE, 60, 0]), "unsupported-document"),
                               (Data([60, 112, 62, 0xFF]), "unreadable-content"),
                               (Data([60, 112, 62, 0]), "unreadable-content")] {
            let file = try fixture(root, "")
            try data.write(to: file)
            let store = try SemanticFileStore(url: root.appendingPathComponent(UUID().uuidString + ".sqlite"))
            let reader = HTMLReader(), encoder = SemanticFixtureEncoder()
            for _ in 0..<2 {
                _ = try SemanticFileIndexer.reconcile(paths: [file.path], scope: semanticScope(root.path), store: store,
                    reader: reader, encoder: encoder, cancelled: { false }, progress: { _ in })
                #expect(try store.job(file.path)?.state == .failed && store.job(file.path)?.reason == reason)
            }
            #expect(encoder.calls == 0)
            try Data("<p>repairedhtmlzebra</p>".utf8).write(to: file)
            _ = try SemanticFileIndexer.reconcile(paths: [file.path], scope: semanticScope(root.path), store: store,
                reader: reader, encoder: encoder, cancelled: { false }, progress: { _ in })
            #expect(try store.job(file.path)?.state == .done && encoder.calls == 1)
        }
    }

    @Test func `empty malformed entities BOM buffer boundaries and invalid cursors remain bounded`() throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        for text in ["", "\u{feff}", "<script>unterminated", "<!--unterminated", "<p title='unterminated"] {
            let response = read(try fixture(root, text), root: root)
            #expect(response.error == nil && response.nextCursor == nil && response.pages?.first?.text == "")
        }
        #expect(read(try fixture(root, "<p>2 < 3 > 1</p><"), root: root).pages?.first?.text == "2 < 3 > 1\n<")
        let file = try fixture(root, "汉字")
        for cursor in [SemanticContentCursor(page: 1), .init(offset: 1), .init(offset: 99), .init(offset: -1)] {
            #expect(read(file, root: root, cursor: cursor).error == EINVAL)
        }
        let (title, offline) = AskLocalWebTools.htmlText("<head><title>Notes &amp; News</title></head>"
            + "<h1>Version&nbsp;2</h1><p>Fast &lt;and&gt; safe &#26032;&#x529f;&#x80fd;</p>")
        #expect(title == "Notes & News" && offline == "# Version 2\nFast <and> safe 新功能")
        #expect(AskLocalWebTools.decodeEntities("&#xZZ; &quot;a&quot; &apos;b&#39;") == "&#xZZ; \"a\" 'b'")
        let tricky = try fixture(root, "\u{feff}<p> &bad<template>hidden</template>&&amp; &#xZZ; &"
            + String(repeating: "x", count: 50) + " &#12; </p>")
        #expect(read(tricky, root: root).error == EILSEQ)
        let boundary = try fixture(root, "<p title='" + String(repeating: "x", count: 20000) + "'>" +
            "before<!--" + String(repeating: "-", count: 20000)
            + "-->after &bad<template>hidden</template>&&amp; &#xZZ; &" +
            String(repeating: "x", count: 50) + " &end</p><script>1 < 2</script>tail")
        let text = try #require(read(boundary, root: root).pages?.first?.text)
        #expect(text.hasPrefix("before after &bad && &#xZZ; &"))
        #expect(text.hasSuffix("&end\ntail") && !text.contains("hidden"))
    }
}
