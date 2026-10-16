import AVFoundation
import Darwin
import ImageIO
import XCTest
import TypefluxMediaProtocol
import TypefluxMediaRuntime
@testable import Typeflux

private final class EncodingState: @unchecked Sendable {
    let lock = NSLock(), gate = DispatchSemaphore(value: 0)
    var reapers: [@Sendable () -> Void] = []
    var calls = 0
    func started(_ request: ManagedProcess.Request) { request.onStarted?(); lock.withLock { calls += 1; reapers.append(request.onReaped!) } }
    var count: Int { lock.withLock { calls } }
    func reap() { let values = lock.withLock { let v = reapers; reapers = []; return v }; values.forEach { $0() } }
}

@MainActor final class RecordingEncodingIsolationTests: XCTestCase {
    private struct Fixture {
        let root: URL, files: ScreenRecordingFiles, source: URL, destination: URL
        init() throws {
            root = try AskAttachmentFixture.directory(); files = .init(root: root.appendingPathComponent("sessions"))
            let session = try files.createSession(options: .init())
            source = session.appendingPathComponent("source.mov"); destination = session.appendingPathComponent("result.mp4")
            try Data("original source".utf8).write(to: source)
        }
        var session: URL { source.deletingLastPathComponent() }
        func clean() { try? FileManager.default.removeItem(at: root) }
        func jobs() throws -> [URL] { try FileManager.default.contentsOfDirectory(at: session, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix(".encoding-") } }
    }
    nonisolated private static func reply(_ process: ManagedProcess.Request, bytes: Data = Data([0,0,0,20] + Array("ftypmp42payload".utf8))) throws -> ManagedProcess.Result {
        let request = try JSONDecoder().decode(MediaRecordingExport.self, from: process.stdin!)
        let output = openat(process.directoryDescriptor, request.outputName, O_CREAT | O_EXCL | O_WRONLY, 0o600)
        guard output >= 0 else { throw MediaFailure.unavailable }; defer { close(output) }
        _ = bytes.withUnsafeBytes { write(output, $0.baseAddress, bytes.count) }
        let event = MediaRecordingExportEvent(id: request.id, sequence: 1, kind: .completed, progress: 1, bytes: bytes.count)
        return .init(termination: .exited(0), exitCode: 0, stdout: String(decoding: try JSONEncoder().encode(event), as: UTF8.self) + "\n", stderr: "", outputTruncated: false)
    }
    private func encode(_ f: Fixture, worker: MediaWorker) async throws {
        try await ScreenRecordingEncoder(worker: worker).export(source: f.source, destination: f.destination, format: .mp4, trim: .init(start: 0, end: 1), progress: { _ in })
    }
    private func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<500 { if predicate() { return }; try await Task.sleep(for: .milliseconds(10)) }
        XCTFail("Encoding work did not settle")
    }
    func testRequestAndStreamRejectInvalidBoundsIdentitySequenceAndBackpressure() throws {
        XCTAssertEqual(try MediaRecordingExportDecoder.frameCount(30.01), 301)
        for value in [Double.nan, .infinity, 0, 30.02] { XCTAssertThrowsError(try MediaRecordingExportDecoder.frameCount(value)) }
        let request = MediaRecordingExport(format: .gif, start: 0, end: 30.01); try request.validate()
        for (start, end) in [(Double.nan, 1), (-1, 1), (0, Double.infinity), (1, 1), (0, 30.02)] {
            XCTAssertThrowsError(try MediaRecordingExport(format: .gif, start: start, end: end).validate())
        }
        let valid = MediaRecordingExportEvent(id: request.id, sequence: 1, kind: .completed, progress: 1, bytes: 12)
        try valid.validate(for: request, sequence: 1)
        for event in [MediaRecordingExportEvent(id: UUID(), sequence: 1, kind: .progress, progress: 0),
                      .init(id: request.id, sequence: 2, kind: .progress, progress: 0),
                      .init(id: request.id, sequence: 1, kind: .progress, progress: .nan),
                      .init(id: request.id, sequence: 1, kind: .completed, progress: 0.9, bytes: 12),
                      .init(id: request.id, sequence: 1, kind: .completed, progress: 1, bytes: 50_000_001),
                      .init(id: request.id, sequence: 1, kind: .failed, progress: 0, bytes: 1)] { XCTAssertThrowsError(try event.validate(for: request, sequence: 1)) }
        let line = String(decoding: try JSONEncoder().encode(valid), as: UTF8.self) + "\n"
        let stream = ScreenRecordingEncoder.Stream(request: request, progress: { _ in })
        stream.accept(String(line.prefix(10))); stream.accept(line); stream.accept(line)
        XCTAssertEqual(stream.completedBytes, 12); XCTAssertTrue(stream.isComplete(line)); XCTAssertFalse(stream.invalid)
        stream.accept(line + line); XCTAssertTrue(stream.invalid)
        for text in [String(repeating: "x", count: 1025), String(repeating: "x", count: MediaRecordingExport.streamBytes + 1), "{}\n"] {
            let bad = ScreenRecordingEncoder.Stream(request: request, progress: { _ in }); bad.accept(text); XCTAssertTrue(bad.invalid)
        }
        let regressing = ScreenRecordingEncoder.Stream(request: request, progress: { _ in })
        let a = MediaRecordingExportEvent(id: request.id, sequence: 1, kind: .progress, progress: 0.8)
        let b = MediaRecordingExportEvent(id: request.id, sequence: 2, kind: .progress, progress: 0.2)
        regressing.accept(String(decoding: try JSONEncoder().encode(a), as: UTF8.self) + "\n" + String(decoding: try JSONEncoder().encode(b), as: UTF8.self) + "\n")
        XCTAssertTrue(regressing.invalid)
    }
    func testValidatedCandidateTransfersOnceAndExistingPublicationCommitsOriginalAuthority() async throws {
        let f = try Fixture(); defer { f.clean() }
        let worker = MediaWorker(run: { process, _ in
            XCTAssertEqual(process.arguments, ["--recording-export"])
            return try Self.reply(process)
        })
        try await encode(f, worker: worker)
        XCTAssertTrue(try f.jobs().isEmpty); XCTAssertEqual(try Data(contentsOf: f.source), Data("original source".utf8))
        let output = f.root.appendingPathComponent("saved")
        let publication = try await f.files.preparePublication(f.destination, in: output, format: .mp4)
        let published = try publication.commit { true }
        XCTAssertEqual(try Data(contentsOf: published), try Data(contentsOf: f.destination))
        do { try await encode(f, worker: worker); XCTFail("Repeated target replaced") } catch {}
    }
    func testMissingAcknowledgementMalformedOutputAndSourceMutationRetainAllPossibleBytes() async throws {
        for mode in 0..<5 {
            let f = try Fixture(); defer { f.clean() }
            let worker = MediaWorker(run: { process, _ in
                let result = try Self.reply(process, bytes: mode == 1 ? Data(repeating: 3, count: 20) : Data([0,0,0,20] + Array("ftypmp42payload".utf8)))
                if mode == 0 { return .init(termination: .exited(1), exitCode: 1, stdout: "", stderr: "", outputTruncated: false) }
                if mode == 2 { try Data([9]).write(to: f.source) }
                if mode == 3 { try Data([8]).write(to: f.destination) }
                if mode == 4 { return .init(termination: .exited(0), exitCode: 0, stdout: result.stdout + "trailing", stderr: "", outputTruncated: false) }
                return result
            })
            do { try await encode(f, worker: worker); XCTFail("Unverified output accepted") } catch {}
            let job = try XCTUnwrap(f.jobs().first)
            XCTAssertTrue(FileManager.default.fileExists(atPath: job.appendingPathComponent("output.mp4").path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: job.appendingPathComponent("input.mov").path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: job.appendingPathComponent("request.json").path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: f.source.path))
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: job.path)[.posixPermissions] as? Int, 0o700)
        }
    }
    func testCancelledUncooperativeWorkKeepsTwoSlotsAndDiscardWaitsForActualReaping() async throws {
        let a = try Fixture(), b = try Fixture(), c = try Fixture(); defer { a.clean(); b.clean(); c.clean() }
        let state = EncodingState(), worker = MediaWorker(run: { process, _ in
            state.started(process); state.gate.wait(); return try Self.reply(process)
        })
        let first = Task { try await encode(a, worker: worker) }, second = Task { try await encode(b, worker: worker) }
        try await wait { state.count == 2 }; first.cancel(); second.cancel()
        a.files.discard(a.session); b.files.discard(b.session)
        do { try await encode(c, worker: worker); XCTFail("Occupied slots reused") } catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.source.path))
        state.gate.signal(); state.gate.signal(); _ = await first.result; _ = await second.result
        XCTAssertEqual(worker.activeCount, 2); XCTAssertTrue(FileManager.default.fileExists(atPath: a.source.path))
        state.reap(); try await wait { worker.activeCount == 0 && !FileManager.default.fileExists(atPath: a.session.path) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: b.session.path))
    }
    func testDiscardDoesNotDeleteReplacementDirectoryAndSameSourceRejectsConcurrentOwnership() throws {
        let f = try Fixture(); defer { f.clean() }
        var owner: ScreenRecordingEncodingOwnership? = try .init(f.session)
        XCTAssertThrowsError(try ScreenRecordingEncodingOwnership(f.session))
        f.files.discard(f.session)
        let moved = f.root.appendingPathComponent("moved")
        try FileManager.default.moveItem(at: f.session, to: moved)
        try FileManager.default.createDirectory(at: f.session, withIntermediateDirectories: false)
        owner = nil; withExtendedLifetime(owner) {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.session.path))
        f.files.discard(f.session); XCTAssertFalse(FileManager.default.fileExists(atPath: f.session.path))
        f.files.discard(f.session)
    }
    func testDeferredDiscardUsesCheckedCanonicalSessionDespiteAliasReplacement() throws {
        let f = try Fixture(); defer { f.clean() }
        let alias = f.root.appendingPathComponent("alias"), outside = f.root.appendingPathComponent("outside")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: f.files.root)
        let unrelated = outside.appendingPathComponent(f.session.lastPathComponent)
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
        var owner: ScreenRecordingEncodingOwnership? = try .init(f.session)
        ScreenRecordingFiles(root: alias).discard(alias.appendingPathComponent(f.session.lastPathComponent))
        try FileManager.default.removeItem(at: alias)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: outside)
        owner = nil; withExtendedLifetime(owner) {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.session.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }
    func testInputDestinationAttemptAndDirectoryBoundsRefuseBeforeDispatch() async throws {
        let worker = MediaWorker(run: { _, _ in XCTFail("Rejected input spawned"); throw MediaFailure.unavailable })
        for mode in 0..<5 {
            let f = try Fixture(); defer { f.clean() }
            switch mode {
            case 0:
                let fd = open(f.source.path, O_WRONLY); _ = ftruncate(fd, off_t(MediaRecordingExport.inputBytes + 1)); close(fd)
            case 1:
                try FileManager.default.removeItem(at: f.source); try FileManager.default.createSymbolicLink(at: f.source, withDestinationURL: f.destination)
            case 2: for i in 0..<4 { try FileManager.default.createDirectory(at: f.session.appendingPathComponent(".encoding-\(i)"), withIntermediateDirectories: false) }
            case 3: for i in 0..<1025 { try Data().write(to: f.session.appendingPathComponent("file\(i)")) }
            default: try Data([1]).write(to: f.destination)
            }
            do { try await encode(f, worker: worker); XCTFail("Invalid input accepted") } catch {}
        }
        let f = try Fixture(); defer { f.clean() }
        do { try await ScreenRecordingEncoder(worker: worker).export(source: f.source, destination: f.root.appendingPathComponent("elsewhere.mp4"), format: .mp4, trim: .init(start: 0, end: 1), progress: { _ in }); XCTFail("Outside candidate accepted") } catch {}
        let task = Task { try await encode(f, worker: worker) }; task.cancel(); _ = await task.result
    }
    func testOutputSymlinkLengthAndMissingFilesAreNeverAccepted() async throws {
        for mode in 0..<3 {
            let f = try Fixture(); defer { f.clean() }
            let worker = MediaWorker(run: { process, _ in
                let result = try Self.reply(process)
                let fd = process.directoryDescriptor
                if mode == 0 { _ = unlinkat(fd, "output.mp4", 0) }
                if mode == 1 {
                    _ = unlinkat(fd, "output.mp4", 0)
                    _ = symlinkat("input.mov", fd, "output.mp4")
                }
                if mode == 2 { let out = openat(fd, "output.mp4", O_WRONLY); _ = ftruncate(out, 1); close(out) }
                return result
            })
            do { try await encode(f, worker: worker); XCTFail("Invalid file accepted") }
            catch { XCTAssertEqual(error.localizedDescription, L("recording.encodingUnconfirmed")) }
            XCTAssertFalse(FileManager.default.fileExists(atPath: f.destination.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: f.source.path))
        }
    }
    func testSilentCrashAndDeadlineRetainInputAndUnknownOutputIdentity() async throws {
        for script in ["#!/bin/sh\nkill -KILL $$\n", "#!/bin/sh\nsleep 10\n"] {
            let f = try Fixture(); defer { f.clean() }
            let executable = f.root.appendingPathComponent("fault")
            try Data(script.utf8).write(to: executable); XCTAssertEqual(chmod(executable.path, 0o700), 0)
            let worker = MediaWorker(executable: executable, timeout: 0.1)
            do { try await encode(f, worker: worker); XCTFail("Fault succeeded") } catch {}
            XCTAssertEqual(try f.jobs().count, 1); XCTAssertTrue(FileManager.default.fileExists(atPath: f.source.path))
            await worker.shutdown(); XCTAssertEqual(worker.activeCount, 0)
        }
    }
    func testRealHelperMixedAudioEncodesWithoutPlayingAndRejectedTrimKeepsFiles() async throws {
        let f = try Fixture(); defer { f.clean() }
        try FileManager.default.removeItem(at: f.source)
        try await ScreenRecordingMediaTests.makeMovie(at: f.source, withAudio: true)
        let evidence = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/encoding-validation")
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        let worker = MediaWorker(timeout: 30, run: { request, cancelled in
            var request = request; request.environment["LLVM_PROFILE_FILE"] = evidence.appendingPathComponent("helper-%p.profraw").path
            return try ManagedProcess().runBlocking(request, isCancelled: cancelled)
        })
        try await encode(f, worker: worker)
        let asset = AVURLAsset(url: f.destination)
        let tracks = try await asset.loadTracks(withMediaType: .audio); XCTAssertEqual(tracks.count, 1)
        do { try await ScreenRecordingEncoder(worker: worker).export(source: f.source, destination: f.session.appendingPathComponent("invalid.mp4"), format: .mp4, trim: .init(start: 0, end: 100), progress: { _ in }); XCTFail("Beyond-source trim accepted") } catch {}
        XCTAssertEqual(try f.jobs().count, 1)
        await worker.shutdown()
    }
    func testRealHelperTrimOrientationGIFAndMalformedSourceRetainOriginal() async throws {
        let f = try Fixture(); defer { f.clean() }
        try FileManager.default.removeItem(at: f.source); try await ClipboardVideoPlaybackTests.movie(f.source)
        let evidence = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/encoding-validation")
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: evidence.appendingPathComponent("silent.mov"))
        try FileManager.default.copyItem(at: f.source, to: evidence.appendingPathComponent("silent.mov"))
        let worker = MediaWorker(timeout: 30, run: { request, cancelled in
            var request = request; request.environment["LLVM_PROFILE_FILE"] = evidence.appendingPathComponent("helper-%p.profraw").path
            return try ManagedProcess().runBlocking(request, isCancelled: cancelled)
        })
        try await encode(f, worker: worker)
        let asset = AVURLAsset(url: f.destination)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let transform = try await track.load(.preferredTransform)
        let size = try await track.load(.naturalSize)
        let displayed = CGRect(origin: .zero, size: size).applying(transform).size
        XCTAssertEqual(displayed.width, 32); XCTAssertEqual(displayed.height, 64)
        let gif = f.session.appendingPathComponent("result.gif")
        try await ScreenRecordingEncoder(worker: worker).export(source: f.source, destination: gif, format: .gif, trim: .init(start: 0.2, end: 1), progress: { _ in })
        let image = try XCTUnwrap(CGImageSourceCreateWithURL(gif as CFURL, nil)); XCTAssertEqual(CGImageSourceGetCount(image), 8)
        try Data("broken".utf8).write(to: f.source)
        do { try await ScreenRecordingEncoder(worker: worker).export(source: f.source, destination: f.session.appendingPathComponent("broken.mp4"), format: .mp4, trim: .init(start: 0, end: 1), progress: { _ in }); XCTFail("Malformed media accepted") } catch {}
        XCTAssertEqual(try Data(contentsOf: f.source), Data("broken".utf8)); XCTAssertEqual(try f.jobs().count, 1)
        await worker.shutdown()
    }
}
