import AVFoundation
import CryptoKit
import Foundation
import SQLite3
import Testing
@testable import Typeflux

private final class EmbeddedAudioReader: AskFileReading, @unchecked Sendable {
    let native = AskFileReader()
    var afterFrame: ((AskFileReadResponse) -> Void)?
    var resumedVideoEvents = 0
    var cursors: [SemanticMediaCursor] = []
    func read(_ request: AskFileReadRequest, isCancelled: () -> Bool) throws -> AskFileReadResponse {
        try native.read(request, isCancelled: isCancelled)
    }
    func stream(_ request: AskFileReadRequest, isCancelled: () -> Bool,
                receive: (AskFileReadResponse) -> Bool) throws {
        if let cursor = request.mediaCursor { cursors.append(cursor) }
        try native.stream(request, isCancelled: isCancelled) { response in
            if request.mediaCursor?.videoProgress?.complete == true, response.videoProgress != nil {
                resumedVideoEvents += 1
            }
            let accepted = receive(response)
            afterFrame?(response)
            return accepted && !isCancelled()
        }
    }
}

@Suite("Embedded video audio windows and independent durable progress", .serialized)
struct SemanticVideoAudioTests {
    private func movie(_ root: URL, _ name: String) throws -> URL {
        let expected = try #require([
            "boundary": "42b34419df706743fb4d01407bb18e374ef32b103e7a35b0095ee2d030d8d424",
            "silent-prefix": "d211e41c03d2a55a8065d0ffd85d5aa844418309aaafd4841c635ab2494771e0",
            "offset": "4a17cb3025822da60b934e0e2d7e1ff63ccb3aa4210a4387a4ca3194cae5cb37"
        ][name])
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/validation/gul-383/optimization/video-audio/\(name).mov")
        #expect(try SHA256.hash(data: Data(contentsOf: source)).map { String(format: "%02x", $0) }.joined() == expected)
        let file = root.appendingPathComponent(name + ".mov")
        try FileManager.default.copyItem(at: source, to: file)
        return file
    }

    private func record(_ name: String, _ value: [String: Any]) throws {
        guard let folder = ProcessInfo.processInfo.environment["TYPEFLUX_GUL405_EVIDENCE"] else { return }
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: folder).appendingPathComponent(name + ".json"))
    }

    @Test(arguments: ["boundary", "silent-prefix", "offset"])
    func realTrackWindowsHaveOverlapSilenceEOFAndTimeline(name: String) throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let file = try movie(root, name), scratch = root.appendingPathComponent("scratch")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var windows: [SemanticMediaInput] = [], saved: SemanticAudioProgress?, video: SemanticVideoProgress?
        let final = try SemanticMediaExtractor.extract(.init(operation: .media, path: file.path,
            scope: semanticScope(root.path), scratch: scratch.path), mounts: .init(excluded: [])) {
            if let input = $0.media, input.kind == .audio { windows.append(input) }
            if let progress = $0.audioProgress { saved = progress }
            if let progress = $0.videoProgress { video = progress }
        }
        let starts: [Double] = name == "offset" ? [7.5, 32.5] : name == "boundary" ? [0, 25] : [25, 50]
        let end = name == "offset" ? 38.5 : 65.0
        #expect(final.error == nil && video?.complete == true)
        #expect(windows.map(\.time) == starts.map(Optional.some))
        #expect(windows.map(\.endTime) == starts.map { Optional(min($0 + 30, end)) })
        #expect(saved == .init(next: end, covered: end))
        for window in windows {
            let data = try Data(contentsOf: URL(fileURLWithPath: window.path))
            #expect(data.count == 44 + Int(((window.endTime! - window.time!) * 16000).rounded()) * 4)
        }
        if name == "boundary" {
            let data = try Data(contentsOf: URL(fileURLWithPath: windows[1].path)).dropFirst(44)
            let active = data.withUnsafeBytes { raw in
                (0 ..< raw.count / 4).filter {
                    abs(Float(bitPattern: raw.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self))) > 1e-7
                }.count
            }
            #expect(active > 31000, "the 25-second window retains both sides of the 30-second boundary")
        }
        var replayEvents = 0
        let cursor = SemanticMediaCursor(nextOrdinal: final.mediaSegments!, audioUntil: end,
                                          audioCoveredUntil: end, videoProgress: video)
        let replay = try SemanticMediaExtractor.extract(.init(operation: .media, path: file.path,
            scope: semanticScope(root.path), scratch: scratch.path, mediaCursor: cursor), mounts: .init(excluded: [])) {
            if $0.media != nil || $0.videoProgress != nil { replayEvents += 1 }
        }
        #expect(replay.error == nil && replayEvents == 0)
        try record("embedded-\(name)", ["starts": starts, "ends": windows.map { $0.endTime! },
            "covered": end, "eof_decodes_or_encodes": replayEvents, "real_MOV_PCM": true])
    }

    @Test(arguments: [false, true], ["boundary", "silent-prefix"])
    // swiftlint:disable:next function_body_length
    func realIPCCancelAndDocumentPreemptionResumeWithoutRepeatingFrames(preempt: Bool, name: String) throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let file = try movie(root, name), reader = EmbeddedAudioReader()
        let store = try SemanticFileStore(url: root.appendingPathComponent("index.sqlite"))
        let metadata = try reader.read(.init(operation: .content, path: file.path,
            scope: semanticScope(root.path), readText: false), isCancelled: { false })
        let media = SemanticFixtureMediaEncoder()
        var audio: [Double] = [], images = 0, stop = false
        media.before = { input in
            if input.kind == .audio { audio.append(input.time!) } else { images += 1 }
        }
        reader.afterFrame = { if $0.audioProgress?.next == 25 { stop = true } }
        #expect(throws: (any Error).self) {
            try SemanticFileIndexer.indexMedia(file.path, metadata: metadata, scope: semanticScope(root.path),
                store: store, reader: reader, encoder: SemanticFixtureEncoder(), media: media,
                cancelled: { stop && !preempt }, waitForIdle: {
                    if stop && preempt { throw SemanticWorkBudget.Interrupted() }
                })
        }
        #expect(try store.counts().chunks == 0)
        let generation = try store.beginMediaJob(path: file.path, metadata: metadata)
        let cursor = try store.mediaCursor(path: file.path, generation: generation)
        #expect(cursor.audioUntil == 25 && cursor.audioCoveredUntil == 30 && cursor.videoProgress?.complete == true)
        #expect(cursor.videoFrames == 1 && cursor.nextOrdinal == (name == "boundary" ? 2 : 1))
        if preempt {
            let document = root.appendingPathComponent("priority.txt").path
            try store.replace(path: document, modified: Date(), bytes: 10,
                chunks: [.init(text: "priorityzebra", page: nil)], vectors: [semanticVector()])
            #expect(try store.lexicalSearch(text: "priorityzebra", query: .init("priorityzebra"), type: .all,
                scope: semanticScope(root.path), limit: 5, cancelled: { false }).map(\.path) == [document])
        }
        reader.afterFrame = nil
        let reopened = try SemanticFileStore(url: store.url)
        #expect(try SemanticFileIndexer.indexMedia(file.path, metadata: metadata, scope: semanticScope(root.path),
            store: reopened, reader: reader, encoder: SemanticFixtureEncoder(), media: media,
            cancelled: { false }, waitForIdle: {}))
        #expect(audio == (name == "boundary" ? [0, 25] : [25, 50]))
        #expect(images == 1 && reader.resumedVideoEvents == 0 && reader.cursors.last == cursor)
        #expect(try reopened.mediaUnchanged(path: file.path, metadata: metadata))
        let hits = try reopened.search(vector: semanticVector(), text: "audio recording",
            query: .init("audio recording"),
            type: .all, scope: semanticScope(root.path), limit: 5, cancelled: { false })
        #expect(hits.first?.path == file.path && hits.first?.evidence?.segmentKind == "audio-window")
        #expect(hits.first?.evidence?.time == (name == "boundary" ? 0 : 25))
        try reopened.lock.withLock {
            let row = try reopened.statement("""
                SELECT time,end_time,provenance FROM chunks WHERE modality='audio' ORDER BY time
                """)
            defer { sqlite3_finalize(row) }
            var ranges: [[Double]] = []
            while sqlite3_step(row) == SQLITE_ROW {
                ranges.append([sqlite3_column_double(row, 0), sqlite3_column_double(row, 1)])
                #expect(reopened.string(row, 2) == SemanticFileStore.audioProvenance)
            }
            #expect(ranges == (name == "boundary" ? [[0, 30], [25, 55]] : [[25, 55], [50, 65]]))
        }
        try record("embedded-resume-\(name)-\(preempt)", ["audio_times": audio, "total_image_encodes": images,
            "resumed_video_decodes": reader.resumedVideoEvents, "next": cursor.audioUntil,
            "covered": cursor.audioCoveredUntil, "real_IPC_both_runs": true, "preemption": preempt])
    }

    @Test func cancellationAtAudioEOFCannotPublishAndResumeDoesNoMoreMediaWork() throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let file = try movie(root, "boundary"), reader = EmbeddedAudioReader()
        let store = try SemanticFileStore(url: root.appendingPathComponent("index.sqlite"))
        let metadata = try reader.read(.init(operation: .content, path: file.path,
            scope: semanticScope(root.path), readText: false), isCancelled: { false })
        var stop = false
        let media = SemanticFixtureMediaEncoder()
        reader.afterFrame = { if $0.audioProgress?.next == 65 { stop = true } }
        #expect(throws: CancellationError.self) {
            try SemanticFileIndexer.indexMedia(file.path, metadata: metadata, scope: semanticScope(root.path),
                store: store, reader: reader, encoder: SemanticFixtureEncoder(), media: media,
                cancelled: { stop }, waitForIdle: {})
        }
        #expect(try store.counts().chunks == 0 && media.calls == 3)
        let generation = try store.beginMediaJob(path: file.path, metadata: metadata)
        let cursor = try store.mediaCursor(path: file.path, generation: generation)
        #expect(cursor.audioUntil == 65 && cursor.videoProgress?.complete == true)
        reader.afterFrame = nil
        let reopened = try SemanticFileStore(url: store.url)
        #expect(try SemanticFileIndexer.indexMedia(file.path, metadata: metadata, scope: semanticScope(root.path),
            store: reopened, reader: reader, encoder: SemanticFixtureEncoder(), media: media,
            cancelled: { false }, waitForIdle: {}))
        #expect(media.calls == 3 && reader.resumedVideoEvents == 0)
        try record("embedded-EOF-cancel", ["unpublished_after_cancel": true,
            "total_encodes_before_after": [3, media.calls], "resumed_frame_decodes": reader.resumedVideoEvents])
    }

    // swiftlint:disable:next function_body_length
    @Test func recipeMigrationReusesPublishedAndPartialFramesButRejectsOldAudio() throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try SemanticFileStore(url: root.appendingPathComponent("index.sqlite"))
        let metadata = AskFileReadResponse(fileSize: 10, modified: Date(timeIntervalSince1970: 1), version: "v1")
        let path = root.appendingPathComponent("old.mov").path
        let gen = try store.beginMediaJob(path: path, metadata: metadata)
        let video = SemanticVideoProgress(next: 6, actual: 5.9,
            reference: Data(repeating: 1, count: 1024), complete: true)
        try store.saveMediaSegment(path: path, generation: gen, ordinal: 0,
            input: .init(kind: .image, path: "fixture", time: 0, endTime: 0), vector: semanticVector(),
            videoProgress: video)
        try store.saveMediaSegment(path: path, generation: gen, ordinal: 1,
            input: .init(kind: .audio, path: "fixture", time: 0, endTime: 30), vector: semanticVector(1))
        #expect(try store.commitMediaJob(path: path, generation: gen, metadata: metadata, segments: 2))
        try store.lock.withLock {
            try store.execute("UPDATE jobs SET recipe=? WHERE path=?", [SemanticFileStore.videoProvenance, path])
            try store.execute("UPDATE chunks SET provenance=? WHERE modality='audio'",
                [SemanticFileStore.mediaProvenance])
        }
        let reopened = try SemanticFileStore(url: store.url)
        let hits = try reopened.search(vector: semanticVector(), text: "video", query: .init("video"), type: .all,
            scope: semanticScope(root.path), limit: 5, cancelled: { false })
        #expect(hits.first?.evidence?.segmentKind == "video-frame")
        let incompatible = try reopened.search(vector: semanticVector(1), text: "audio", query: .init("audio"),
            type: .all, scope: semanticScope(root.path), limit: 5, cancelled: { false })
        #expect(incompatible.isEmpty, "legacy non-overlapping video audio cannot mix with the new audio recipe")
        #expect(try !reopened.mediaUnchanged(path: path, metadata: metadata))
        let replacement = try reopened.beginMediaJob(path: path, metadata: metadata)
        let cursor = try reopened.mediaCursor(path: path, generation: replacement)
        #expect(cursor.nextOrdinal == 1 && cursor.videoProgress?.complete == true && cursor.audioUntil == 0)
        let pending = root.appendingPathComponent("partial.mov").path
        let pendingGen = try reopened.beginMediaJob(path: pending, metadata: metadata)
        try reopened.saveMediaSegment(path: pending, generation: pendingGen, ordinal: 0,
            input: .init(kind: .image, path: "fixture", time: 0, endTime: 0), vector: semanticVector(),
            videoProgress: video)
        try reopened.saveMediaSegment(path: pending, generation: pendingGen, ordinal: 1,
            input: .init(kind: .audio, path: "fixture", time: 0, endTime: 30), vector: semanticVector(),
            audioProgress: .init(next: 30.0, covered: 30.0))
        try reopened.lock.withLock {
            try reopened.execute("UPDATE media_jobs SET recipe=? WHERE path=?",
                [SemanticFileStore.videoProvenance, pending])
        }
        let upgradedGen = try reopened.beginMediaJob(path: pending, metadata: metadata)
        #expect(upgradedGen != pendingGen)
        try reopened.saveAudioProgress(path: pending, generation: pendingGen,
            progress: .init(next: 65.0, covered: 65.0))
        try reopened.saveMediaSegment(path: pending, generation: pendingGen, ordinal: 1,
            input: .init(kind: .audio, path: "fixture", time: 0, endTime: 30), vector: semanticVector())
        #expect(try !reopened.hasMediaSegment(path: pending, generation: upgradedGen, ordinal: 1))
        let migrated = try reopened.mediaCursor(path: pending, generation: upgradedGen)
        #expect(migrated.nextOrdinal == 1 && migrated.videoProgress == video && migrated.audioUntil == 0)
        var changed = metadata; changed.version = "v2"
        let fresh = try reopened.beginMediaJob(path: path, metadata: changed)
        #expect(try reopened.mediaCursor(path: path, generation: fresh).nextOrdinal == 0)
    }
}
