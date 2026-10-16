import AppKit
import Darwin
import XCTest
import TypefluxMediaProtocol
import TypefluxMediaRuntime
@testable import Typeflux

@MainActor private final class SilentPlaybackEngine: MediaPlaybackEngine {
    var commands: [MediaPlaybackMessage.Kind] = []
    var loads = 0, stops = 0
    var failure = false
    var value = MediaPlaybackState(phase: .paused, elapsed: 0, duration: 2)
    func load(_ url: URL) async throws { loads += 1; if failure { throw MediaFailure.unreadable } }
    func perform(_ command: MediaPlaybackMessage) async throws -> MediaPlaybackState {
        commands.append(command.kind)
        if failure { throw MediaFailure.unavailable }
        switch command.kind {
        case .play: if value.phase == .ended { value.elapsed = 0 }; value.phase = .playing
        case .pause: value.phase = .paused
        case .seek: value.elapsed = (command.fraction ?? 0) * value.duration; if value.elapsed == value.duration { value.phase = .ended }
        default: break
        }
        return value
    }
    func stop() { stops += 1 }
}
private final class PlaybackReaper: @unchecked Sendable {
    let lock = NSLock(), returned = DispatchSemaphore(value: 0)
    private var callback: (@Sendable () -> Void)?
    private var directory: String?
    var ready: Bool { lock.withLock { callback != nil } }
    var path: String? { lock.withLock { directory } }
    func install(_ request: ManagedProcess.Request) {
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN)); _ = fcntl(request.directoryDescriptor, F_GETPATH, &path)
        lock.withLock { callback = request.onReaped; directory = String(cString: path) }
    }
    func reap() { lock.withLock { callback }?() }
}

@MainActor final class ClipboardPlaybackIsolationTests: XCTestCase {
    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<600 { if condition() { return }; try await Task.sleep(for: .milliseconds(5)) }; XCTFail("Playback did not retire")
    }
    private func sockets() throws -> (MediaPlaybackSocket, MediaPlaybackSocket) {
        var pair: [Int32] = [-1, -1]; guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { throw MediaFailure.unavailable }
        return (try MediaPlaybackSocket(owning: pair[0]), try MediaPlaybackSocket(owning: pair[1]))
    }
    private func exchange(_ message: MediaPlaybackMessage, socket: MediaPlaybackSocket) async throws -> MediaPlaybackMessage {
        try await Task.detached {
            try socket.send(message, deadline: .now.advanced(by: .seconds(2)))
            return try socket.receive(deadline: .now.advanced(by: .seconds(2)))
        }.value
    }
    private func fixture() throws -> (URL, URL) {
        let root = try AskAttachmentFixture.directory()
        let file = try ClipboardTestSupport.makeAudioFile(named: "silent.wav", in: root, seconds: 1)
        return (root, file)
    }
    private func silentRunner(_ engine: SilentPlaybackEngine) -> ClipboardPlaybackProcess.Runner {
        { request, cancelled in
            let socket = try MediaPlaybackSocket(owning: dup(request.ipcDescriptor!))
            request.onStarted?()
            let done = DispatchSemaphore(value: 0)
            Task { @MainActor in
                await MediaPlaybackServer(engine: engine).serve(socket: socket, input: URL(fileURLWithPath: "/private/synthetic.wav"))
                done.signal()
            }
            while done.wait(timeout: .now() + 0.01) == .timedOut { if cancelled() { socket.stop() } }
            request.onReaped?()
            return .init(termination: .exited(0), exitCode: 0, stdout: "", stderr: "", outputTruncated: false)
        }
    }
    func testMessageRejectsMixedPayloadVersionsBoundsAndNonfiniteTimes() throws {
        let id = UUID()
        for kind in [MediaPlaybackMessage.Kind.load, .play, .pause, .status] {
            var value = MediaPlaybackMessage(id: id, sequence: 1, kind: kind); try value.validate()
            value.fraction = 0; XCTAssertThrowsError(try value.validate())
        }
        for fraction in [Double.nan, .infinity, -0.1, 1.1] { XCTAssertThrowsError(try MediaPlaybackMessage(id: id, sequence: 1, kind: .seek, fraction: fraction).validate()) }
        XCTAssertThrowsError(try MediaPlaybackMessage(id: id, sequence: 1, kind: .seek).validate())
        try MediaPlaybackMessage(id: id, sequence: 1, kind: .seek, fraction: 1).validate()
        var reply = MediaPlaybackMessage(id: id, sequence: 1, kind: .reply, state: .init(phase: .paused, elapsed: 0, duration: 2))
        try reply.validate(); reply.version = 2; XCTAssertThrowsError(try reply.validate()); reply.version = 1
        for number in [0, Int.max] { reply.sequence = number; XCTAssertThrowsError(try reply.validate()) }; reply.sequence = 1
        reply.fraction = 0; XCTAssertThrowsError(try reply.validate()); reply.fraction = nil
        reply.kind = .play; XCTAssertThrowsError(try reply.validate()); reply.kind = .reply; reply.state = nil; XCTAssertThrowsError(try reply.validate())
        for state in [MediaPlaybackState(phase: .ended, elapsed: 0, duration: 2), .init(phase: .paused, elapsed: .nan, duration: 2), .init(phase: .playing, elapsed: 3, duration: 2), .init(phase: .paused, elapsed: 0, duration: 0), .init(phase: .paused, elapsed: 0, duration: 86401)] { XCTAssertThrowsError(try state.validate()) }
    }
    func testServerOrderedControlsAreSilentUntilExplicitPlayAndStopOnEOF() async throws {
        let (host, child) = try sockets(), engine = SilentPlaybackEngine(), id = UUID()
        let task = Task { await MediaPlaybackServer(engine: engine).serve(socket: child, input: URL(fileURLWithPath: "/private/unused")) }
        var seq = 0
        for kind in [MediaPlaybackMessage.Kind.load, .status, .play, .pause, .seek, .play] {
            seq += 1
            let result = try await exchange(.init(id: id, sequence: seq, kind: kind, fraction: kind == .seek ? 1 : nil), socket: host)
            XCTAssertEqual(result.sequence, seq); XCTAssertEqual(result.id, id)
            if seq == 2 { XCTAssertEqual(engine.commands, [.load, .status]); XCTAssertEqual(result.state?.phase, .paused) }
            if kind == .seek { XCTAssertEqual(result.state?.phase, .ended) }
            if seq == 6 { XCTAssertEqual(result.state?.elapsed, 0) }
        }
        host.stop(); await task.value; XCTAssertEqual(engine.loads, 1); XCTAssertEqual(engine.stops, 1)
    }
    func testChildLifetimeAndWatchdogDoNotRestartAnEngine() async throws {
        let (host, child) = try sockets(), engine = SilentPlaybackEngine()
        var ticks = 0
        let server = MediaPlaybackServer(engine: engine, lifetime: .zero, watchdog: { ticks += 1 })
        await server.serve(socket: child, input: URL(fileURLWithPath: "/private/unused"))
        XCTAssertEqual(engine.loads, 0); XCTAssertEqual(engine.stops, 1); XCTAssertEqual(ticks, 0); host.stop()
        let (second, peer) = try sockets(), next = SilentPlaybackEngine()
        let task = Task { await MediaPlaybackServer(engine: next, watchdog: { ticks += 1 }).serve(socket: peer, input: URL(fileURLWithPath: "/private/unused")) }
        _ = try await exchange(.init(id: UUID(), sequence: 1, kind: .load), socket: second)
        XCTAssertGreaterThanOrEqual(ticks, 2); second.stop(); await task.value
        XCTAssertEqual(next.loads, 1); XCTAssertEqual(next.stops, 1)
    }
    func testServerRejectsReplayWrongIdentityAndNativeFailureWithoutRestart() async throws {
        for mode in 0..<4 {
            let (host, child) = try sockets(), engine = SilentPlaybackEngine(), id = UUID()
            let task = Task { await MediaPlaybackServer(engine: engine).serve(socket: child, input: URL(fileURLWithPath: "/private/unused")) }
            _ = try await exchange(.init(id: id, sequence: 1, kind: .load), socket: host)
            if mode == 3 { engine.failure = true }
            let request = MediaPlaybackMessage(id: mode == 1 ? UUID() : id, sequence: mode == 0 ? 1 : 2, kind: mode == 2 ? .load : .status)
            if mode == 3 { let reply = try await exchange(request, socket: host); XCTAssertEqual(reply.kind, .failed); XCTAssertNil(reply.state) }
            else { do { _ = try await exchange(request, socket: host); XCTFail("Invalid control accepted") } catch {} }
            await task.value; host.stop(); XCTAssertEqual(engine.loads, 1); XCTAssertEqual(engine.stops, 1)
        }
    }
    func testSocketRejectsOversizedInvalidAndExpiredFramesAndStopsBlockedRead() async throws {
        for payload in [Data([0, 0, 8, 1]), Data([0, 0, 0, 1, 255])] {
            let (host, child) = try sockets()
            _ = payload.withUnsafeBytes { Darwin.write(child.descriptor, $0.baseAddress!, $0.count) }
            do { _ = try await Task.detached { try host.receive(deadline: .now.advanced(by: .seconds(1))) }.value; XCTFail() } catch {}
            host.stop(); child.stop()
        }
        let (host, child) = try sockets()
        XCTAssertThrowsError(try host.receive(deadline: .now.advanced(by: .seconds(-1))))
        let pending = Task.detached { try host.receive(deadline: .now.advanced(by: .seconds(10))) }
        host.stop(); host.stop(); do { _ = try await pending.value; XCTFail() } catch {}; child.stop()
        XCTAssertThrowsError(try MediaPlaybackSocket(owning: -1))
    }
    func testProcessUsesPrivateCopyAndRejectsSourceMutationBeforeCommand() async throws {
        let (root, file) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let original = try Data(contentsOf: file), pool = ClipboardPlaybackPool(), engine = SilentPlaybackEngine()
        let client = try await ClipboardPlaybackProcess.open(file, pool: pool, run: silentRunner(engine))
        let state = try await client.request(.load); XCTAssertEqual(state.phase, .paused)
        _ = try await client.request(.play); XCTAssertEqual(engine.commands.filter { $0 == .play }.count, 1)
        try original.dropLast().write(to: file, options: .atomic)
        do { _ = try await client.request(.pause); XCTFail("Changed original accepted") } catch {}
        try await wait { pool.activeCount == 0 }; XCTAssertEqual(engine.commands, [.load, .play]); XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }
    func testRetirementKeepsTwoSlotsAndCopiesUntilReaped() async throws {
        let (root, file) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let pool = ClipboardPlaybackPool(), reapers = [PlaybackReaper(), PlaybackReaper()]
        var clients: [ClipboardPlaybackProcess] = []
        for reaper in reapers {
            clients.append(try await ClipboardPlaybackProcess.open(file, pool: pool, run: { request, _ in
                request.onStarted?(); reaper.install(request); reaper.returned.wait()
                return .init(termination: .timedOut, exitCode: -1, stdout: "", stderr: "", outputTruncated: false)
            }))
        }
        try await wait { reapers.allSatisfy(\.ready) }
        reapers.forEach { $0.returned.signal() }
        XCTAssertEqual(pool.activeCount, 2)
        for reaper in reapers { XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(reaper.path))) }
        do { _ = try await ClipboardPlaybackProcess.open(file, pool: pool); XCTFail("Third slot admitted") } catch {}
        clients.forEach { $0.stop() }; XCTAssertEqual(pool.activeCount, 2)
        pool.preventNewWork(); reapers.forEach { $0.reap() }; try await wait { pool.activeCount == 0 }
        for reaper in reapers { XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(reaper.path))) }
        do { _ = try await ClipboardPlaybackProcess.open(file, pool: pool); XCTFail("Shutdown admitted") } catch {}
        await pool.shutdown()
    }
    func testReapedChildrenCannotFreeAdmissionWhileHostExchangesRemainBlocked() async throws {
        let pool = ClipboardPlaybackPool()
        let (_, first) = try pool.reserve(), (_, second) = try pool.reserve()
        let barriers = [ClipboardPlaybackRetirement(first), ClipboardPlaybackRetirement(second)]
        for (barrier, lease) in zip(barriers, [first, second]) {
            try barrier.beginRequest(); lease.started(); lease.reaped(); barrier.processReturned()
            XCTAssertThrowsError(try barrier.beginRequest(), "No request may start after process retirement")
        }
        XCTAssertEqual(pool.activeCount, 2); XCTAssertThrowsError(try pool.reserve())
        barriers[0].endRequest(); try await wait { pool.activeCount == 1 }
        barriers[1].endRequest(); try await wait { pool.activeCount == 0 }
        barriers[1].processReturned(); await pool.shutdown()
    }
    func testInvalidSourceLimitsAndCancellationRefuseBeforeLaunch() async throws {
        let (root, file) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let pool = ClipboardPlaybackPool()
        for url in [URL(string: "https://example.invalid/a.wav")!, root.appendingPathComponent("missing.wav"), root, root.appendingPathComponent("bad.xyz")] {
            do { _ = try await ClipboardPlaybackProcess.open(url, pool: pool); XCTFail() } catch {}
        }
        let linked = root.appendingPathComponent("linked.wav"); try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: file)
        XCTAssertThrowsError(try ClipboardPlaybackSource(linked))
        let huge = root.appendingPathComponent("huge.wav")
        let fd = Darwin.open(huge.path, O_CREAT | O_WRONLY, 0o600); XCTAssertGreaterThanOrEqual(fd, 0)
        XCTAssertEqual(ftruncate(fd, 512 * 1024 * 1024 + 1), 0); close(fd)
        do { _ = try await ClipboardPlaybackProcess.open(huge, pool: pool); XCTFail() } catch {}
        do { _ = try await ClipboardPlaybackProcess.open(file, pool: pool, timeout: .nan); XCTFail() } catch {}
        let task = Task { try await ClipboardPlaybackProcess.open(file, pool: pool) }; task.cancel()
        do { _ = try await task.value; XCTFail() } catch {}
        try await wait { pool.activeCount == 0 }
    }
    func testRealHelperLoadsSeeksAndPausesWithoutEverPlaying() async throws {
        let (root, file) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let pool = ClipboardPlaybackPool()
        let folder = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/playback-validation")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let client = try await ClipboardPlaybackProcess.open(file, pool: pool, run: { request, cancelled in
            var request = request; request.environment["LLVM_PROFILE_FILE"] = folder.appendingPathComponent("helper-%p.profraw").path
            return try ManagedProcess().runBlocking(request, isCancelled: cancelled)
        })
        let ready = try await client.request(.load); XCTAssertEqual(ready.phase, .paused); XCTAssertEqual(ready.duration, 1, accuracy: 0.01)
        let seek = try await client.request(.seek, fraction: 0.5); XCTAssertEqual(seek.elapsed, 0.5, accuracy: 0.05)
        _ = try await client.request(.pause)
        let status = try await client.request(.status); XCTAssertEqual(status.phase, .paused)
        client.stop(); try await wait { pool.activeCount == 0 }
    }
    func testMaliciousReplyAndCancelledInFlightCommandAreNeverReplayed() async throws {
        let (root, file) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let pool = ClipboardPlaybackPool()
        let bad = try await ClipboardPlaybackProcess.open(file, pool: pool, run: { request, _ in
            let socket = try MediaPlaybackSocket(owning: dup(request.ipcDescriptor!))
            request.onStarted?(); defer { socket.stop(); request.onReaped?() }
            let input = try socket.receive(deadline: .now.advanced(by: .seconds(2)))
            try socket.send(.init(id: UUID(), sequence: input.sequence, kind: .reply,
                                 state: .init(phase: .paused, elapsed: 0, duration: 1)), deadline: .now.advanced(by: .seconds(2)))
            return .init(termination: .exited(0), exitCode: 0, stdout: "", stderr: "", outputTruncated: false)
        })
        do { _ = try await bad.request(.load); XCTFail("Wrong session accepted") } catch {}
        try await wait { pool.activeCount == 0 }
        let hangPool = ClipboardPlaybackPool()
        let hanging = try await ClipboardPlaybackProcess.open(file, pool: hangPool, run: { request, cancelled in
            var request = request; request.executable = "/bin/sh"; request.arguments = ["-c", "trap '' TERM; sleep 5"]
            return try ManagedProcess().runBlocking(request, isCancelled: cancelled)
        })
        let operation = Task { try await hanging.request(.status) }
        try await Task.sleep(for: .milliseconds(30))
        do { _ = try await hanging.request(.play); XCTFail("Concurrent command admitted") } catch {}
        operation.cancel(); do { _ = try await operation.value; XCTFail("Cancelled published state") } catch {}
        await hangPool.shutdown(); XCTAssertEqual(hangPool.activeCount, 0)
    }
    func testHarmlessCrashHangAndLaunchFailureRetireWithoutReplay() async throws {
        let (root, file) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        for command in ["kill -KILL $$", "trap '' TERM; sleep 5", "exit 3"] {
            let pool = ClipboardPlaybackPool()
            let client = try await ClipboardPlaybackProcess.open(file, pool: pool, timeout: 0.08, run: { request, cancelled in
                var request = request; request.executable = "/bin/sh"; request.arguments = ["-c", command]
                return try ManagedProcess().runBlocking(request, isCancelled: cancelled)
            })
            do { _ = try await client.request(.status); XCTFail() } catch {}
            client.stop(); try await wait { pool.activeCount == 0 }
        }
        let pool = ClipboardPlaybackPool()
        let client = try await ClipboardPlaybackProcess.open(file, pool: pool, executable: root.appendingPathComponent("absent"))
        do { _ = try await client.request(.load); XCTFail() } catch {}
        try await wait { pool.activeCount == 0 }
    }
}
