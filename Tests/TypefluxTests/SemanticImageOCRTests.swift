import CoreGraphics
import CoreText
import Foundation
import ImageIO
import Testing
@testable import Typeflux

private final class ImageOCRInterceptReader: AskFileReading {
    let reader = AskFileReader(timeout: 20)
    var dropText = false
    var changed: (() throws -> Void)?
    var denyMetadata = false
    deinit { reader.stop() }
    func read(_ request: AskFileReadRequest, isCancelled: () -> Bool) throws -> AskFileReadResponse {
        if denyMetadata {
            return .init(error: EACCES)
        }
        return try reader.read(request, isCancelled: isCancelled)
    }

    func stream(_ request: AskFileReadRequest, isCancelled: () -> Bool,
                receive: (AskFileReadResponse) -> Bool) throws {
        var actionError: Error?
        try reader.stream(request, isCancelled: isCancelled) { response in
            if response.pages != nil {
                do { try changed?() } catch { actionError = error; return false }
                if dropText {
                    return true
                }
            }
            var response = response
            if response.more != true, dropText {
                response.error = EIO
            }
            return receive(response)
        }
        if let actionError {
            throw actionError
        }
    }
}

@Suite("Screenshot OCR complements visual search", .serialized)
// This integration suite keeps the native fixture and recovery scenarios together.
// swiftlint:disable:next type_body_length
struct SemanticImageOCRTests {
    private func fixture(_ root: URL, ext: String = "png", blank: Bool = false) throws -> URL {
        let file = root.appendingPathComponent("error." + ext)
        let context = try #require(CGContext(data: nil, width: 1200, height: 600, bitsPerComponent: 8,
                                             bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1200, height: 600))
        if !blank {
            for (index, line) in ["Connection failed", "Error ERR-739204", "Request ID REQ-482917"].enumerated() {
                context.textPosition = CGPoint(x: 40, y: 450 - index * 110)
                let value = NSAttributedString(string: line, attributes: [
                    NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName(
                        "Helvetica" as CFString,
                        46,
                        nil
                    ),
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)
                ])
                CTLineDraw(CTLineCreateWithAttributedString(value), context)
            }
        }
        let destination = try #require(CGImageDestinationCreateWithURL(file as CFURL,
                                                                       (ext == "png" ? "public.png" :
                                                                           "public.jpeg") as CFString, 1, nil))
        try CGImageDestinationAddImage(destination, #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))
        return file
    }

    // swiftlint:disable:next function_parameter_count
    private func index(_ file: URL, _ root: URL, _ store: SemanticFileStore, _ reader: AskFileReading,
                       _ media: SemanticFixtureMediaEncoder, _ encoder: SemanticFixtureEncoder,
                       cancelled: () -> Bool = { false }) throws -> SemanticFileStore.JobState {
        try SemanticFileIndexer.index(file.path, scope: semanticScope(root.path), store: store, reader: reader,
                                      encoder: encoder, media: media, cancelled: cancelled, checkpoint: {},
                                      waitForIdle: {})
    }

    @Test(arguments: ["png", "jpeg"])
    func `real worker OCR persists identifiers source offsets and independent visual vectors`(ext: String) throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let file = try fixture(root, ext: ext), url = root.appendingPathComponent("index.sqlite")
        var store = try SemanticFileStore(url: url)
        let reader = AskFileReader(timeout: 20), media = SemanticFixtureMediaEncoder(),
            encoder = SemanticFixtureEncoder()
        defer { reader.stop() }
        #expect(try index(file, root, store, reader, media, encoder) == .done)
        store = try SemanticFileStore(url: url)
        let hits = try store.lexicalSearch(text: "ERR-739204", query: .init("ERR-739204"), type: .image,
                                           scope: semanticScope(root.path), limit: 5, cancelled: { false })
        let evidence = try #require(hits.first?.evidence)
        #expect(evidence.text.contains("ERR-739204") && evidence.segmentKind == "image-ocr")
        #expect(evidence.chunkID != nil && evidence.startOffset == 0 && evidence.endOffset != nil)
        #expect(try store.counts().chunks >= 2)
        #expect(try store.job(file.path)?.version == evidence.version)
        #expect(evidence.version?.contains(":") == true)
        let calls = encoder.calls
        #expect(try index(file, root, store, reader, media, encoder) == .done)
        #expect(media.calls == 1 && encoder.calls == calls)
        let visual = try store.search(vector: semanticVector(), text: "landscape", query: .init("landscape"),
                                      type: .image, scope: semanticScope(root.path), limit: 5, cancelled: { false })
        #expect(!visual.isEmpty)
        let other = semanticVector(1)
        try store.lock.withLock {
            try store.execute("UPDATE chunks SET vector=? WHERE path=? AND modality='image'",
                              [other.withUnsafeBytes { Data($0) }, file.path])
        }
        let textSemantic = try store.search(vector: semanticVector(), text: "outage", query: .init("outage"),
                                            type: .image, scope: semanticScope(root.path), limit: 5,
                                            cancelled: { false })
        #expect(textSemantic.first?.evidence?.segmentKind == "image-ocr",
                "text vectors must survive media provenance filtering and use the text calibration bucket")
        let visualSemantic = try store.search(vector: other, text: "landscape", query: .init("landscape"),
                                              type: .image, scope: semanticScope(root.path), limit: 5,
                                              cancelled: { false })
        #expect(visualSemantic.first?.evidence?.segmentKind == "image")
        if let folder = ProcessInfo.processInfo.environment["TYPEFLUX_GUL405_EVIDENCE"] {
            try Data(contentsOf: file)
                .write(to: URL(fileURLWithPath: folder).appendingPathComponent("synthetic-error." + ext))
            try JSONSerialization.data(withJSONObject: ["text": evidence.text, "source": evidence.segmentKind ?? "",
                                                        "visual_calls": media.calls, "text_calls": encoder.calls],
                                       options: [
                                           .sortedKeys,
                                           .prettyPrinted
                                       ])
                                       .write(to: URL(fileURLWithPath: folder)
                                           .appendingPathComponent("ocr-" + ext + ".json"))
        }
    }

    @Test func `upgrade and cancellation reuse the committed visual across store restart`() throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let file = try fixture(root), url = root.appendingPathComponent("index.sqlite")
        var store = try SemanticFileStore(url: url)
        let metadata = AskFileWorkerCommand.handle(.init(operation: .content, path: file.path,
                                                         scope: semanticScope(root.path), readText: false))
        let generation = try store.beginMediaJob(path: file.path, metadata: metadata)
        try store.saveMediaSegment(path: file.path, generation: generation, ordinal: 0,
                                   input: .init(kind: .image, path: "fixture"), vector: semanticVector())
        #expect(try store.commitMediaJob(path: file.path, generation: generation, metadata: metadata, segments: 1))
        try store.lock.withLock { try store.execute("UPDATE jobs SET recipe=? WHERE path=?",
                                                    [SemanticFileStore.mediaProvenance, file.path]) }
        store = try SemanticFileStore(url: url)
        #expect(try store.nextWork(.image) == file.path)
        let media = SemanticFixtureMediaEncoder(), encoder = SemanticFixtureEncoder(), token = AskSearchCancellation()
        encoder.after = { token.cancel() }
        let reader = AskFileReader(timeout: 20); defer { reader.stop() }
        #expect(throws: CancellationError.self) {
            try index(file, root, store, reader, media, encoder, cancelled: { token.isCancelled })
        }
        #expect(try media.calls == 0 && store.counts().chunks == 1)
        encoder.after = nil
        store = try SemanticFileStore(url: url)
        #expect(try index(file, root, store, reader, media, encoder) == .done)
        #expect(media.calls == 0)
        var scope = semanticScope(root.path); scope.excludedPaths = [file.path]
        #expect(try SemanticFileIndexer.index(
            file.path,
            scope: scope,
            store: store,
            reader: reader,
            encoder: encoder,
            media: media,
            cancelled: { false },
            checkpoint: {},
            waitForIdle: {}
        ) == .skipped)
        #expect(try store.counts().chunks == 0)
    }

    @Test func `OCR failure retains visual search and succeeds on targeted retry`() throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let file = try fixture(root), store = try SemanticFileStore(url: root.appendingPathComponent("index.sqlite"))
        let reader = ImageOCRInterceptReader(), media = SemanticFixtureMediaEncoder(),
            encoder = SemanticFixtureEncoder()
        reader.dropText = true
        #expect(try index(file, root, store, reader, media, encoder) == .skipped)
        #expect(try store.job(file.path)?.reason == "image-ocr-failed" && store.counts().chunks == 1)
        #expect(try !store.search(vector: semanticVector(), text: "landscape", query: .init("landscape"),
                                  type: .image, scope: semanticScope(root.path), limit: 5, cancelled: { false })
                .isEmpty)
        reader.dropText = false
        #expect(try index(file, root, store, reader, media, encoder) == .done)
        #expect(media.calls == 1, "retry must adopt the already published visual")
    }

    @Test(arguments: [false, true])
    func `replacement or permission withdrawal after OCR cannot publish`(deny: Bool) throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let file = try fixture(root), store = try SemanticFileStore(url: root.appendingPathComponent("index.sqlite"))
        let reader = ImageOCRInterceptReader(), media = SemanticFixtureMediaEncoder(),
            encoder = SemanticFixtureEncoder()
        reader.changed = {
            if deny {
                reader.denyMetadata = true
            } else {
                try Data("replacement".utf8).write(to: file)
            }
        }
        #expect(try index(file, root, store, reader, media, encoder) == .skipped)
        #expect(try store.counts().chunks == 0)
        #expect(try store.job(file.path)?.reason == (deny ? "permission-denied" : "media-missing-or-changed"))
        reader.changed = nil
    }

    @Test func `private text batches resume without encoding and stale generations cannot write`() throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let file = try fixture(root), url = root.appendingPathComponent("index.sqlite")
        let metadata = AskFileWorkerCommand.handle(.init(operation: .content, path: file.path,
                                                         scope: semanticScope(root.path), readText: false))
        var store = try SemanticFileStore(url: url)
        let generation = try store.beginMediaJob(path: file.path, metadata: metadata)
        let chunks = SemanticChunk.make([.init(text: "ERR-739204", offset: 0, segmentKind: "image-ocr")])
        #expect(try !store.hasMediaText(path: file.path, generation: generation, chunks: chunks))
        try store.saveMediaText(path: file.path, generation: generation, chunks: chunks, vectors: [semanticVector()])
        store = try SemanticFileStore(url: url)
        #expect(try store.hasMediaText(path: file.path, generation: generation, chunks: chunks))
        #expect(try !store.hasMediaText(path: file.path, generation: "stale", chunks: chunks))
        #expect(throws: SemanticFileStore.Failure.self) {
            try store.saveMediaText(path: file.path, generation: generation, chunks: chunks, vectors: [[]])
        }
        try store.saveMediaText(path: file.path, generation: "stale", chunks: chunks, vectors: [semanticVector()])
        #expect(try store.hasMediaText(path: file.path, generation: generation, chunks: chunks))
        #expect(try store.counts().chunks == 0, "staged OCR must remain private")
    }

    @Test func `blank image preserves visual search and corrupt image has a fixed retryable reason`() throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let file = try fixture(root, blank: true),
            store = try SemanticFileStore(url: root.appendingPathComponent("index.sqlite"))
        let reader = AskFileReader(timeout: 20), media = SemanticFixtureMediaEncoder(),
            encoder = SemanticFixtureEncoder()
        defer { reader.stop() }
        #expect(try index(file, root, store, reader, media, encoder) == .done)
        #expect(try media.calls == 1 && encoder.calls == 0 && store.counts().chunks == 1)
        #expect(try store.job(file.path)?.reason == "image-no-text")
        try Data("broken".utf8).write(to: file)
        #expect(try index(file, root, store, reader, media, encoder) == .skipped)
        #expect(try store.job(file.path)?.reason == "media-extraction-failed")
        _ = try fixture(root)
        #expect(try index(file, root, store, reader, media, encoder) == .done)
    }

    @Test func `direct worker OCR covers native failure and resumes private text without inference`() throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let file = try fixture(root), url = root.appendingPathComponent("index.sqlite")
        var store = try SemanticFileStore(url: url)
        let metadata = AskFileWorkerCommand.handle(.init(operation: .content, path: file.path,
                                                         scope: semanticScope(root.path), readText: false))
        let generation = try store.beginMediaJob(path: file.path, metadata: metadata)
        let scratch = root.appendingPathComponent(".typeflux-media-cache/" + generation)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let request = AskFileReadRequest(operation: .media, path: file.path, scope: semanticScope(root.path),
                                         scratch: scratch.path)
        var pages: [SemanticPage] = []
        let normal = try SemanticMediaExtractor.extract(request, mounts: .init(excluded: [])) { response in
            pages += response.pages ?? []
        }
        #expect(normal.error == nil && pages.first?.text.contains("ERR-739204") == true)
        let chunks = SemanticChunk.make(pages)
        try store.saveMediaSegment(path: file.path, generation: generation, ordinal: 0,
                                   input: .init(kind: .image, path: "fixture"), vector: semanticVector())
        try store.saveMediaText(path: file.path, generation: generation, chunks: chunks,
                                vectors: chunks.map { _ in semanticVector() })
        store = try SemanticFileStore(url: url)
        let reader = AskFileReader(timeout: 20), media = SemanticFixtureMediaEncoder(),
            encoder = SemanticFixtureEncoder()
        defer { reader.stop() }
        #expect(try index(file, root, store, reader, media, encoder) == .done)
        #expect(media.calls == 0 && encoder.calls == 0, "committed private inputs are not encoded twice")
        try store.completeWork(file.path, more: false)
        #expect(try SemanticFileStore(url: url).nextWork(.image) == nil)
        // Actual native recognition is covered above; inject its exceptional result deterministically.
        let failedFolder = root.appendingPathComponent("failure")
        try FileManager.default.createDirectory(at: failedFolder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let failed = try SemanticMediaExtractor.extract(.init(
            operation: .media,
            path: file.path,
            scope: semanticScope(root.path),
            scratch: failedFolder.path
        ), mounts: .init(excluded: []),
        recognize: { _ in throw AskFileReadError.unavailable },
        emit: { _ in })
        #expect(failed.error == EIO && failed.mediaSegments == 1 && failed.fileSize == metadata.fileSize)
        let unsupported = root.appendingPathComponent("image.gif")
        try Data(contentsOf: file).write(to: unsupported)
        var other = request; other.path = unsupported.path; other.scratch = failedFolder.path
        #expect(try SemanticMediaExtractor.extract(other, mounts: .init(excluded: []), recognize: { _ in
            Issue.record("This slice must leave other formats on their existing visual path"); return []
        }, emit: { _ in }).error == nil)
    }

    @Test func `long recognition uses bounded overlapping batches without dropping its tail`() throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let file = try fixture(root)
        var frames: [AskFileReadResponse] = []
        try SemanticImageText.extract(file, recognize: { image in
            #expect(image.width <= 4096 && image.height <= 4096)
            return Array(repeating: "Synthetic long screenshot line", count: 3000) + ["TAIL-739204"]
        }, emit: { frames.append($0) })
        #expect(frames.count > 2 && frames.last?.pages?.first?.text.contains("TAIL-739204") == true)
        #expect(frames.allSatisfy { ($0.pages?.first?.text.utf8.count ?? 0) <= 32768 })
        #expect(frames.last?.pages?.first?.offset ?? 0 > 32768)
        #expect(throws: AskFileReadError.self) {
            try SemanticImageText.extract(file, recognize: { _ in throw AskFileReadError.unavailable }, emit: { _ in })
        }
    }
}
