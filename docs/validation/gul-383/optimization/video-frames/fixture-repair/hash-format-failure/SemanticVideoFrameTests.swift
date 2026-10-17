import AVFoundation
import CryptoKit
import Foundation
import ImageIO
import SQLite3
import Testing
@testable import Typeflux

private final class VideoCheckpointReader: AskFileReading, @unchecked Sendable {
    let native = AskFileReader()
    var afterFrame: ((AskFileReadResponse) throws -> Void)?
    var direct = true
    var resumes: [SemanticMediaCursor] = []

    func read(_ request: AskFileReadRequest, isCancelled: () -> Bool) throws -> AskFileReadResponse {
        try native.read(request, isCancelled: isCancelled)
    }

    func stream(_ request: AskFileReadRequest, isCancelled: () -> Bool,
                receive: (AskFileReadResponse) -> Bool) throws {
        if let cursor = request.mediaCursor {
            resumes.append(cursor)
        }
        func deliver(_ frame: AskFileReadResponse) throws {
            if isCancelled() {
                throw CancellationError()
            }
            guard receive(frame) else { throw AskFileReadError.cancelled }
            try afterFrame?(frame)
        }
        if direct {
            try deliver(SemanticMediaExtractor.extract(request, mounts: .init(excluded: []), emit: deliver))
        } else {
            try native.stream(request, isCancelled: isCancelled) { frame in
                do { try deliver(frame); return true } catch { return false }
            }
        }
    }
}

private final class VideoColorEncoder: SemanticMediaEmbedding {
    var times: [Double] = []
    func embed(_ input: SemanticMediaInput, cancelled: () -> Bool) throws -> [Float] {
        if cancelled() {
            throw CancellationError()
        }
        times.append(input.time!)
        let source = try #require(CGImageSourceCreateWithURL(URL(fileURLWithPath: input.path) as CFURL, nil))
        let small = try SemanticVideoFrames.thumbnail(#require(CGImageSourceCreateImageAtIndex(source, 0, nil)))
        // Fixed, deterministic vectors prove the decoded frame's identity and search plumbing only.
        var vector = [Float](repeating: 0, count: SemanticFilePolicy.dimension)
        vector[small[2] > small[0] ? 0 : 1] = 1
        return vector
    }

    func release() {}
}

@Suite("Video short scenes, duplicate progress and actual decode times", .serialized)
struct SemanticVideoFrameTests {
    private func record(_ name: String, _ value: [String: Any]) throws {
        guard let folder = ProcessInfo.processInfo.environment["TYPEFLUX_GUL405_EVIDENCE"] else { return }
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: folder).appendingPathComponent(name + ".json"))
    }

    /// Reuse the real MOVs frozen in PR638, avoiding hardware encoder readiness during tests.
    /// The short scene is six seconds at 10 fps, including a 0.7 s blue slide and green EOF frame.
    private func movie(_ root: URL, name: String = "short-scene") throws -> URL {
        let expected = try #require([
            "short-scene": "7db4b38eca51b68f458481fee84c1aa5a3e119e5e29d9faf166a035bbd99ddd2",
            "static-scene": "263f17d7cdaae6f671ded7c07a83ca22429151f5f0a1f05414fa4bdbbf31093e",
            "longer-audio": "902e4d62bc5f6b745963c89766e680b917a8cd1104c9ef733f698b31d73195ec"
        ][name])
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/validation/gul-383/optimization/video-frames/\(name).mov")
        try #require(SHA256.hash(data: Data(contentsOf: source)).description == expected,
                     "Frozen MOV fixture hash changed: \(name)")
        let url = root.appendingPathComponent(UUID().uuidString + ".mov")
        try FileManager.default.copyItem(at: source, to: url)
        return url
    }

    private func request(_ file: URL, root: URL, cursor: SemanticMediaCursor = .init()) throws -> AskFileReadRequest {
        let scratch = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        return .init(operation: .media, path: file.path, scope: semanticScope(root.path),
                     scratch: scratch.path, mediaCursor: cursor)
    }

    @Test func `short scene and EOF tail survive real decode and persisted query`() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let file = try movie(root), reader = VideoCheckpointReader(), media = VideoColorEncoder()
        let store = try SemanticFileStore(url: root.appendingPathComponent("index.sqlite"))
        let metadata = try reader.read(.init(operation: .content, path: file.path,
                                             scope: semanticScope(root.path), readText: false), isCancelled: { false })
        var requests: [Double] = [], actual: [Double] = []
        reader.afterFrame = { response in
            if let value = response.videoProgress {
                requests.append(value.next); actual.append(value.actual)
            }
        }
        #expect(try SemanticFileIndexer.indexMedia(file.path, metadata: metadata, scope: semanticScope(root.path),
                                                   store: store, reader: reader, encoder: SemanticFixtureEncoder(),
                                                   media: media,
                                                   cancelled: { false }, waitForIdle: {}))
        #expect(media.times == [0, 1.5, 2, 5.9])
        #expect(actual.count == 13 && actual.last == 5.9 && requests.last == 6)
        let reopened = try SemanticFileStore(url: store.url)
        var queryVector = [Float](repeating: 0, count: SemanticFilePolicy.dimension); queryVector[0] = 1
        let hits = try reopened.search(vector: queryVector, text: "blue scene", query: .init("blue scene"),
                                       type: .all, scope: semanticScope(root.path), limit: 5, cancelled: { false })
        #expect(hits.first?.path == file.path && hits.first?.evidence?.time == 1.5)
        #expect(hits.first?.evidence?.segmentKind == "video-frame")
        #expect(try reopened.mediaUnchanged(path: file.path, metadata: metadata))
        try record("decoded-query", ["fixture_sha256": SHA256.hash(data: Data(contentsOf: file)).description,
                                     "encoded_actual_times": media.times, "decoded_actual_times": actual,
                                     "next_requests": requests,
                                     "query_hit_time": hits.first?.evidence?.time ?? -1, "fixed_vectors": true])
    }

    @Test(arguments: [false, true])
    func `cancel or document preemption resumes duplicate run without reencoding`(preempt: Bool) async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let file = try movie(root), reader = VideoCheckpointReader(), media = VideoColorEncoder()
        let store = try SemanticFileStore(url: root.appendingPathComponent("index.sqlite"))
        let metadata = try reader.read(.init(operation: .content, path: file.path,
                                             scope: semanticScope(root.path), readText: false), isCancelled: { false })
        var stop = false
        reader.afterFrame = {
            if $0.videoProgress?.next == 1 {
                stop = true
            }
        }
        #expect(throws: (any Error).self) {
            try SemanticFileIndexer.indexMedia(file.path, metadata: metadata, scope: semanticScope(root.path),
                                               store: store, reader: reader, encoder: SemanticFixtureEncoder(),
                                               media: media,
                                               cancelled: { !preempt && stop }, waitForIdle: {
                                                   if preempt, stop {
                                                       throw SemanticWorkBudget.Interrupted()
                                                   }
                                               })
        }
        #expect(try media.times == [0] && (store.counts().chunks) == 0)
        let generation = try store.beginMediaJob(path: file.path, metadata: metadata)
        let cursor = try store.mediaCursor(path: file.path, generation: generation)
        #expect(cursor.nextOrdinal == 1 && cursor.videoProgress?.next == 1)
        #expect(cursor.videoProgress?.reference.count == 1024)
        if preempt {
            let doc = root.appendingPathComponent("priority.txt").path
            try store.replace(path: doc, modified: Date(), bytes: 10,
                              chunks: [.init(text: "priorityzebra", page: nil)], vectors: [semanticVector()])
            #expect(try store.lexicalSearch(text: "priorityzebra", query: .init("priorityzebra"), type: .all,
                                            scope: semanticScope(root.path), limit: 5, cancelled: { false })
                    .map(\.path) == [doc])
        }
        reader.afterFrame = nil; reader.direct = false
        let reopened = try SemanticFileStore(url: store.url)
        #expect(try SemanticFileIndexer.indexMedia(file.path, metadata: metadata, scope: semanticScope(root.path),
                                                   store: reopened, reader: reader, encoder: SemanticFixtureEncoder(),
                                                   media: media,
                                                   cancelled: { false }, waitForIdle: {}))
        #expect(reader.resumes.last == cursor && media.times == [0, 1.5, 2, 5.9])
        try record("resume-\(preempt)", ["saved_next": #require(cursor.videoProgress?.next),
                                         "encoded_times": media.times, "reference_bytes": 1024, "IPC_resume": true,
                                         "preempt": preempt])
    }

    @Test func `static and near duplicates do not infer again and completed cursor does no decode`() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let file = try movie(root, name: "static-scene")
        var frames = 0, progress: [SemanticVideoProgress] = []
        let final = try SemanticMediaExtractor.extract(request(file, root: root), mounts: .init(excluded: [])) {
            if $0.media != nil {
                frames += 1
            }
            if let value = $0.videoProgress {
                progress.append(value)
            }
        }
        #expect(final.error == nil && frames == 1 && progress.count == 13 && progress.last?.complete == true)
        var resume = SemanticMediaCursor(); resume.nextOrdinal = 1; resume.videoProgress = progress.last
        var resumed = 0
        let end = try SemanticMediaExtractor.extract(request(file, root: root, cursor: resume),
                                                     mounts: .init(excluded: [])) {
            if $0.videoProgress != nil || $0.media != nil {
                resumed += 1
            }
        }
        #expect(end.error == nil && end.mediaSegments == 1 && resumed == 0)
        let ref = Data(repeating: 100, count: 1024)
        #expect(SemanticVideoFrames.duplicate(ref, Data(repeating: 102, count: 1024)))
        #expect(!SemanticVideoFrames.duplicate(ref, Data(repeating: 103, count: 1024)))
        var peak = ref; peak[0] = 113
        #expect(!SemanticVideoFrames.duplicate(ref, peak))
        #expect(!SemanticVideoFrames.duplicate(ref, Data()))
        try record("static", ["sample_attempts": progress.count, "encoded_frames": frames,
                              "complete_resume_decodes": resumed, "threshold_mean": 2, "threshold_peak": 12])
    }

    @Test func `video track stops at its own end instead of longer audio timeline`() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let output = try movie(root, name: "longer-audio")
        let exported = AVURLAsset(url: output)
        let video = try #require(exported.tracks(withMediaType: .video).first)
        #expect(exported.duration.seconds > video.timeRange.end.seconds)
        var times: [Double] = [], saved: SemanticVideoProgress?
        try SemanticVideoFrames.extract(exported, folder: root, cursor: nil) { response in
            if let time = response.media?.time {
                times.append(time)
            }
            if let progress = response.videoProgress {
                saved = progress
            }
        }
        #expect(times == [0, 1.5, 2, 5.9])
        #expect(saved?.complete == true)
        try record("track-range", ["actual_times": times, "asset_duration": exported.duration.seconds,
                                   "video_end": video.timeRange.end.seconds, "complete": saved?.complete == true])
    }

    // swiftlint:disable:next function_body_length
    @Test func `recipe upgrade is video only and invalid progress rolls back vector`() throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try SemanticFileStore(url: root.appendingPathComponent("index.sqlite"))
        let metadata = AskFileReadResponse(fileSize: 10, modified: Date(timeIntervalSince1970: 1), version: "v1")
        for name in ["tone.wav", "picture.gif", "scan.pdf", "movie.mov"] {
            let path = root.appendingPathComponent(name).path
            if name.hasSuffix("pdf") {
                try store.replace(path: path, modified: #require(metadata.modified), bytes: 10,
                                  chunks: [.init(text: "pdf", page: 0)], vectors: [semanticVector()]); continue
            }
            let gen = try store.beginMediaJob(path: path, metadata: metadata)
            try store.saveMediaSegment(path: path, generation: gen, ordinal: 0,
                                       input: .init(
                                           kind: name.hasSuffix("wav") ? .audio : .image,
                                           path: "fixture",
                                           time: 0,
                                           endTime: 1
                                       ),
                                       vector: semanticVector())
            #expect(try store.commitMediaJob(path: path, generation: gen, metadata: metadata, segments: 1))
        }
        try store.lock.withLock {
            try store.execute("UPDATE jobs SET recipe=? WHERE path LIKE '%.mov'", [SemanticFileStore.mediaProvenance])
        }
        let reopened = try SemanticFileStore(url: store.url)
        try reopened.lock.withLock {
            let row = try reopened.statement("SELECT path,priority FROM work_queue ORDER BY path")
            defer { sqlite3_finalize(row) }
            #expect(sqlite3_step(row) == SQLITE_ROW && reopened.string(row, 0).hasSuffix("movie.mov"))
            #expect(sqlite3_column_int(row, 1) == 3 && sqlite3_step(row) == SQLITE_DONE)
        }
        let path = root.appendingPathComponent("pending.mov").path
        let first = try reopened.beginMediaJob(path: path, metadata: metadata)
        var changed = metadata; changed.version = "v2"
        let second = try reopened.beginMediaJob(path: path, metadata: changed)
        let progress = SemanticVideoProgress(next: 0.5, actual: 0, reference: Data(repeating: 0, count: 1024))
        try reopened.saveVideoProgress(path: path, generation: first, progress: progress)
        #expect(try reopened.mediaCursor(path: path, generation: second).videoProgress == nil)
        var invalid = progress; invalid.next = .infinity
        #expect(throws: SemanticFileStore.Failure.self) {
            try reopened.saveMediaSegment(path: path, generation: second, ordinal: 0,
                                          input: .init(kind: .image, path: "fixture", time: 0, endTime: 0),
                                          vector: semanticVector(), videoProgress: invalid)
        }
        #expect(try !reopened.hasMediaSegment(path: path, generation: second, ordinal: 0))
        try reopened.saveVideoProgress(path: path, generation: second, progress: progress)
        var regressed = progress; regressed.next = 0
        #expect(throws: SemanticFileStore.Failure.self) {
            try reopened.saveVideoProgress(path: path, generation: second, progress: regressed)
        }
        #expect(try reopened.mediaCursor(path: path, generation: second).videoProgress == progress)
        #expect(throws: (any Error).self) {
            try SemanticVideoFrames.extract(AVURLAsset(url: root.appendingPathComponent("absent.mov")),
                                            folder: root, cursor: invalid) { _ in }
        }
    }
}
