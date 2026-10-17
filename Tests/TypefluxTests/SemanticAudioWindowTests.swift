import CryptoKit
import Foundation
import SQLite3
import Testing
@testable import Typeflux

private final class AudioCheckpointReader: AskFileReading, @unchecked Sendable {
    let native = AskFileReader()
    var afterFrame: ((AskFileReadResponse) throws -> Void)?
    var resumes: [SemanticMediaCursor] = []
    var direct = true

    func read(_ request: AskFileReadRequest, isCancelled: () -> Bool) throws -> AskFileReadResponse {
        try native.read(request, isCancelled: isCancelled)
    }

    func stream(_ request: AskFileReadRequest, isCancelled: () -> Bool,
                receive: (AskFileReadResponse) -> Bool) throws {
        if let cursor = request.mediaCursor { resumes.append(cursor) }
        var stopped = false
        func deliver(_ frame: AskFileReadResponse) throws {
            if isCancelled() { throw CancellationError() }
            guard receive(frame) else { stopped = true; throw AskFileReadError.cancelled }
            try afterFrame?(frame)
        }
        if direct {
            let final = try SemanticMediaExtractor.extract(request, mounts: .init(excluded: []), emit: deliver)
            if !stopped { try deliver(final) }
        } else {
            try native.stream(request, isCancelled: isCancelled) { frame in
                do { try deliver(frame); return true } catch { return false }
            }
        }
    }
}

@Suite("Audio overlap, conservative silence and durable checkpoints", .serialized)
struct SemanticAudioWindowTests {
    private func record(_ name: String, _ value: [String: Any]) throws {
        guard let folder = ProcessInfo.processInfo.environment["TYPEFLUX_GUL405_EVIDENCE"] else { return }
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: folder).appendingPathComponent(name + ".json"))
    }

    private func audio(_ root: URL, seconds: Double, amplitude: Double = 0.1,
                       active: Range<Double>? = nil) throws -> URL {
        let file = root.appendingPathComponent(UUID().uuidString + ".wav")
        let samples = (0 ..< Int(seconds * 16000)).map { index -> Float in
            let time = Double(index) / 16000
            return active.map({ !$0.contains(time) }) == true ? 0 : Float(sin(Double(index) * 0.17) * amplitude)
        }
        try samples.withUnsafeBytes { try SemanticMediaExtractor.wave(Data($0), to: file) }
        return file
    }

    private func extract(_ file: URL, root: URL, cursor: SemanticMediaCursor = .init()) throws
        -> ([SemanticMediaInput], [SemanticAudioProgress]) {
        let scratch = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var pieces: [SemanticMediaInput] = [], progress: [SemanticAudioProgress] = []
        let final = try SemanticMediaExtractor.extract(.init(operation: .media, path: file.path,
            scope: semanticScope(root.path), scratch: scratch.path, mediaCursor: cursor), mounts: .init(excluded: [])) {
            if let media = $0.media { pieces.append(media) }
            if let next = $0.audioProgress { progress.append(next) }
        }
        try #require(final.error == nil)
        return (pieces, progress)
    }

    @Test(arguments: [0.125, 30.0, 31.0, 55.0, 56.0, 65.0])
    func realDecodedWindowsHaveStableOverlapAndNoDuplicateTail(seconds: Double) throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let file = try audio(root, seconds: seconds)
        let (pieces, progress) = try extract(file, root: root)
        let starts = seconds <= 30 ? [0.0] : seconds <= 55 ? [0, 25] : [0, 25, 50]
        #expect(pieces.map(\.time) == starts.map(Optional.some))
        #expect(pieces.map(\.endTime) == starts.map { Optional(min($0 + 30, seconds)) })
        #expect(progress.last == .init(next: seconds, covered: seconds))
        for piece in pieces {
            let pcm = try Data(contentsOf: URL(fileURLWithPath: piece.path))
            #expect(pcm.count == 44 + Int(((piece.endTime! - piece.time!) * 16000).rounded()) * 4)
            let first = pcm.withUnsafeBytes { Float(bitPattern: $0.loadUnaligned(fromByteOffset: 44, as: UInt32.self)) }
            let expected = Float(sin((piece.time! * 16000).rounded() * 0.17) * 0.1)
            #expect(abs(first - expected) < 1e-6, "decoded PCM agrees with the reported window start")
        }
        let (atEOF, _) = try extract(file, root: root,
            cursor: .init(audioUntil: seconds, audioCoveredUntil: seconds))
        #expect(atEOF.isEmpty)
        try record("decoded-\(seconds)", ["seconds": seconds, "starts": pieces.map { $0.time! },
            "ends": pieces.map { $0.endTime! }, "fixture_sha256": SHA256.hash(data: try Data(contentsOf: file))
                .map { String(format: "%02x", $0) }.joined(), "eof_replay_segments": atEOF.count])
    }

    @Test func boundaryContentIsWholeInOverlapAndQuietContentIsKept() throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let boundary = try audio(root, seconds: 56, active: 29 ..< 31)
        let (pieces, progress) = try extract(boundary, root: root)
        #expect(pieces.map(\.time) == [0, 25])
        #expect(progress.last?.covered == 56)
        let complete = try Data(contentsOf: URL(fileURLWithPath: pieces[1].path)).dropFirst(44)
        let activeSamples = complete.withUnsafeBytes { bytes in
            (0 ..< bytes.count / 4).filter {
                abs(Float(bitPattern: bytes.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self))) > 1e-7
            }.count
        }
        #expect(activeSamples > 31000, "the overlap retains both sides of the 30-second boundary")
        let quiet = try audio(root, seconds: 31, amplitude: 1e-5)
        #expect(try extract(quiet, root: root).0.count == 2)
        let silent = try audio(root, seconds: 65, amplitude: 0)
        let (none, silenceProgress) = try extract(silent, root: root)
        #expect(none.isEmpty && silenceProgress.map(\.next) == [25, 50, 65, 65])
        #expect(!SemanticAudioWindows.isSilent(withUnsafeBytes(of: Float.nan) { Data($0) }))
        try record("silence-boundary", ["boundary_starts": pieces.map { $0.time! },
            "whole_boundary_active_samples": activeSamples, "silent_progress": silenceProgress.map(\.next),
            "quiet_amplitude": 1e-5, "quiet_segments": 2, "silence_peak_threshold": 1e-7])
    }

    @Test(arguments: [false, true])
    func cancellationAndRestartReuseCommittedWindowsAndSilentProgress(silentPrefix: Bool) throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let file = try audio(root, seconds: 65, active: silentPrefix ? 52 ..< 54 : 0 ..< 32)
        let url = root.appendingPathComponent("index.sqlite"), reader = AudioCheckpointReader()
        let store = try SemanticFileStore(url: url), token = AskSearchCancellation()
        let metadata = try reader.read(.init(operation: .content, path: file.path,
            scope: semanticScope(root.path), readText: false), isCancelled: { false })
        let media = SemanticFixtureMediaEncoder()
        var times: [Double] = []
        media.before = { times.append($0.time!) }
        reader.afterFrame = { frame in if frame.audioProgress != nil { token.cancel() } }
        #expect(throws: CancellationError.self) {
            try SemanticFileIndexer.indexMedia(file.path, metadata: metadata, scope: semanticScope(root.path),
                store: store, reader: reader, encoder: SemanticFixtureEncoder(), media: media,
                cancelled: { token.isCancelled }, waitForIdle: {})
        }
        #expect(try store.counts().chunks == 0)
        let generation = try store.beginMediaJob(path: file.path, metadata: metadata)
        let checkpoint = try store.mediaCursor(path: file.path, generation: generation)
        #expect(checkpoint.audioUntil == 25 && checkpoint.audioCoveredUntil == 30)
        #expect(checkpoint.nextOrdinal == (silentPrefix ? 0 : 1))
        let reopened = try SemanticFileStore(url: url)
        reader.afterFrame = nil; reader.direct = false
        #expect(try SemanticFileIndexer.indexMedia(file.path, metadata: metadata, scope: semanticScope(root.path),
            store: reopened, reader: reader, encoder: SemanticFixtureEncoder(), media: media,
            cancelled: { false }, waitForIdle: {}))
        #expect(times == (silentPrefix ? [25, 50] : [0, 25]))
        #expect(reader.resumes.last == checkpoint)
        try record("resume-\(silentPrefix)", ["next_window": checkpoint.audioUntil,
            "covered_until": checkpoint.audioCoveredUntil, "encoded_times": times,
            "saved_ordinal": checkpoint.nextOrdinal, "real_subprocess_resume": true])
        #expect(try reopened.job(file.path)?.state == .done)
        #expect(try reopened.mediaUnchanged(path: file.path, metadata: metadata))
        let hits = try reopened.search(vector: semanticVector(), text: "boundary", query: .init("boundary"),
            type: .all, scope: semanticScope(root.path), limit: 5, cancelled: { false })
        #expect(hits.map(\.path) == [file.path])
        #expect(hits.first?.evidence?.time != nil)
        try reopened.lock.withLock {
            let row = try reopened.statement("SELECT time,end_time FROM chunks WHERE path=? ORDER BY time")
            defer { sqlite3_finalize(row) }; reopened.bind(row, [file.path])
            var ranges: [[Double]] = []
            while sqlite3_step(row) == SQLITE_ROW {
                ranges.append([sqlite3_column_double(row, 0), sqlite3_column_double(row, 1)])
            }
            #expect(ranges == (silentPrefix ? [[25, 55], [50, 65]] : [[0, 30], [25, 55]]))
        }
    }

    @Test func documentPriorityInterruptionResumesWithoutReencodingCommittedAudio() throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let file = try audio(root, seconds: 65), reader = AudioCheckpointReader()
        let store = try SemanticFileStore(url: root.appendingPathComponent("index.sqlite"))
        let metadata = try reader.read(.init(operation: .content, path: file.path,
            scope: semanticScope(root.path), readText: false), isCancelled: { false })
        let media = SemanticFixtureMediaEncoder()
        var interrupt = false, yielded = false, times: [Double] = []
        media.before = { times.append($0.time!) }
        reader.afterFrame = { if $0.media != nil { interrupt = true } }
        #expect(throws: SemanticWorkBudget.Interrupted.self) {
            try SemanticFileIndexer.indexMedia(file.path, metadata: metadata, scope: semanticScope(root.path),
                store: store, reader: reader, encoder: SemanticFixtureEncoder(), media: media,
                cancelled: { false }, waitForIdle: {
                    if interrupt { yielded = true; throw SemanticWorkBudget.Interrupted() }
                })
        }
        #expect(yielded && times == [0])
        let document = root.appendingPathComponent("new-document.txt").path
        try store.replace(path: document, modified: Date(), bytes: 10,
            chunks: [.init(text: "priorityzebra", page: nil)], vectors: [semanticVector()])
        #expect(try store.lexicalSearch(text: "priorityzebra", query: .init("priorityzebra"), type: .all,
            scope: semanticScope(root.path), limit: 5, cancelled: { false }).map(\.path) == [document])
        reader.afterFrame = nil
        let reopened = try SemanticFileStore(url: store.url)
        #expect(try SemanticFileIndexer.indexMedia(file.path, metadata: metadata, scope: semanticScope(root.path),
            store: reopened, reader: reader, encoder: SemanticFixtureEncoder(), media: media,
            cancelled: { false }, waitForIdle: {}))
        #expect(times == [0, 25, 50])
        #expect(reader.resumes.last?.audioUntil == 25)
        try record("document-priority", ["encoded_times": times, "document_search_during_pause": true,
            "resume_window": 25, "interruption": "SemanticWorkBudget.Interrupted"] )
    }

    @Test func silentTailAndAllSilentAudioFinishWithoutRepeatedInference() throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        for active in [0 ..< 1.0, 100 ..< 101.0] {
            let file = try audio(root, seconds: 80, active: active)
            let store = try SemanticFileStore(url: root.appendingPathComponent(UUID().uuidString + ".sqlite"))
            let reader = AudioCheckpointReader(), media = SemanticFixtureMediaEncoder()
            let metadata = try reader.read(.init(operation: .content, path: file.path,
                scope: semanticScope(root.path), readText: false), isCancelled: { false })
            #expect(try SemanticFileIndexer.indexMedia(file.path, metadata: metadata, scope: semanticScope(root.path),
                store: store, reader: reader, encoder: SemanticFixtureEncoder(), media: media,
                cancelled: { false }, waitForIdle: {}))
            #expect(media.calls == (active.lowerBound == 0 ? 1 : 0))
            #expect(try store.mediaUnchanged(path: file.path, metadata: metadata))
            #expect(try store.job(file.path)?.state == .done)
            if media.calls == 0 { #expect(try store.job(file.path)?.reason == "audio-silent") }
        }
    }

    @Test func audioRecipeMigrationIsSelectiveAndStaleGenerationsCannotAdvance() throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("index.sqlite"), store = try SemanticFileStore(url: url)
        let metadata = AskFileReadResponse(fileSize: 10, modified: Date(timeIntervalSince1970: 1), version: "v1")
        for name in ["tone.wav", "picture.gif", "movie.mov"] {
            let path = root.appendingPathComponent(name).path
            let gen = try store.beginMediaJob(path: path, metadata: metadata)
            try store.saveMediaSegment(path: path, generation: gen, ordinal: 0,
                input: .init(kind: name.hasSuffix("wav") ? .audio : .image, path: "fixture", time: 0, endTime: 1),
                vector: semanticVector())
            #expect(try store.commitMediaJob(path: path, generation: gen, metadata: metadata, segments: 1))
        }
        try store.lock.withLock {
            try store.execute("UPDATE jobs SET recipe=? WHERE path LIKE '%.wav'", [SemanticFileStore.mediaProvenance])
        }
        let reopened = try SemanticFileStore(url: url)
        try reopened.lock.withLock {
            let row = try reopened.statement("SELECT path FROM work_queue ORDER BY path")
            defer { sqlite3_finalize(row) }
            #expect(sqlite3_step(row) == SQLITE_ROW)
            #expect(reopened.string(row, 0) == root.appendingPathComponent("tone.wav").path)
            #expect(sqlite3_step(row) == SQLITE_DONE)
        }
        let path = root.appendingPathComponent("pending.wav").path
        let first = try reopened.beginMediaJob(path: path, metadata: metadata)
        var changed = metadata; changed.version = "v2"
        let second = try reopened.beginMediaJob(path: path, metadata: changed)
        #expect(first != second)
        try reopened.saveAudioProgress(path: path, generation: first, progress: .init(next: 25.0, covered: 30.0))
        #expect(try reopened.mediaCursor(path: path, generation: second).audioUntil == 0)
        #expect(throws: SemanticFileStore.Failure.self) {
            try reopened.saveMediaSegment(path: path, generation: second, ordinal: 0,
                input: .init(kind: .audio, path: "fixture", time: 0, endTime: 30), vector: semanticVector(),
                audioProgress: .init(next: 31.0, covered: 30.0))
        }
        #expect(try !reopened.hasMediaSegment(path: path, generation: second, ordinal: 0))
        #expect(throws: (any Error).self) { try SemanticAudioWindows(cursor: .init(audioUntil: .infinity)) }
        #expect(throws: (any Error).self) {
            var windows = try SemanticAudioWindows(cursor: .init())
            try windows.append(Data([1]), folder: root) { _ in }
        }
    }
}
