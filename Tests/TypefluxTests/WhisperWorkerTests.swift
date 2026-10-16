import Darwin
import Foundation
@testable import Typeflux
import TypefluxInferenceProtocol
import TypefluxInferenceRuntime
import XCTest

final class WhisperWorkerTests: XCTestCase {
    private let configuration = InferenceConfiguration(model: "fixture", modelFolder: "/fixture/models/small")

    func testBundledAndDevelopmentHelperLocations() {
        XCTAssertEqual(WhisperWorkerClient.executableURL(appExecutable: URL(fileURLWithPath: "/build/Typeflux")).path,
                       "/build/TypefluxInferenceHelper")
        XCTAssertEqual(WhisperWorkerClient.executableURL(appExecutable: URL(fileURLWithPath: "/App.app/Contents/MacOS/Typeflux")).path,
                       "/App.app/Contents/Helpers/TypefluxInferenceHelper")
    }

    func testFailedAudioRequestRetainsPrivateCopyUntilConfirmedReaping() async throws {
        let pool = WhisperWorkerPool(), fixture = WhisperProcessFixture(delayReaping: true, fail: true)
        let client = try WhisperWorkerClient(configuration: configuration, pool: pool, run: fixture.run)
        var request = InferenceMessage(kind: .prepare); request.configuration = configuration
        _ = try await client.request(request)
        let audio = try makeAudio()
        defer { try? FileManager.default.removeItem(at: audio) }
        do {
            _ = try await client.transcribe(audio: audio, lowEnergy: true, prompt: "private vocabulary", language: "zh") { _ in }
            XCTFail()
        } catch {}
        let sent = try XCTUnwrap(fixture.engine.lastRequest)
        let copy = try XCTUnwrap(sent.audioPath)
        XCTAssertNotEqual(copy, audio.path)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: copy)), Data("fixture audio".utf8))
        XCTAssertEqual(sent.prompt, "private vocabulary")
        XCTAssertEqual(sent.language, "zh")
        XCTAssertTrue(sent.lowEnergy)
        fixture.reap(); await waitForEmpty(pool)
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy))
    }

    func testFacadeFailureIsLocalizedAndCannotSubmitASecondOperation() async throws {
        let pool = WhisperWorkerPool(), fixture = WhisperProcessFixture(fail: true)
        let transcriber = WhisperKitTranscriber(modelName: "fixture", pool: pool) {
            try WhisperWorkerClient(configuration: $0, pool: $1, run: fixture.run)
        }
        let audio = try makeAudio()
        defer { try? FileManager.default.removeItem(at: audio) }
        for _ in 0..<2 {
            do { _ = try await transcriber.transcribe(audioFile: .init(fileURL: audio, duration: 1)); XCTFail() }
            catch { XCTAssertTrue(error is LocalInferenceUnavailable) }
        }
        XCTAssertEqual(fixture.launches, 1)
        transcriber.stop(); await waitForEmpty(pool)
    }

    func testFacadePreparesOnceReusesModelAndDeliversOneFinalPerRequest() async throws {
        let pool = WhisperWorkerPool(), fixture = WhisperProcessFixture()
        let transcriber = WhisperKitTranscriber(modelName: "fixture", modelFolder: "/fixture/models/small", pool: pool) {
            try WhisperWorkerClient(configuration: $0, pool: $1, run: fixture.run)
        }
        XCTAssertEqual(transcriber.resolvedModelFolderPath, "/fixture/models/small")
        try await transcriber.prepare()
        XCTAssertEqual(transcriber.resolvedModelFolderPath, "/fixture/models/small")
        let audio = try makeAudio()
        defer { try? FileManager.default.removeItem(at: audio) }
        let updates = WhisperUpdates()
        let text = try await transcriber.transcribeStream(audioFile: .init(fileURL: audio, duration: 1),
                                                         profile: .lowEnergyRetry, prompt: "vocabulary") {
            updates.append($0)
        }
        XCTAssertEqual(text, "final")
        XCTAssertEqual(updates.finalCount, 1)
        XCTAssertGreaterThan(updates.count, 1)
        let second = try await transcriber.transcribe(audioFile: .init(fileURL: audio, duration: 1))
        XCTAssertEqual(second, "final")
        XCTAssertEqual(fixture.engine.prepares, 1)
        XCTAssertEqual(fixture.launches, 1)
        transcriber.stop()
        await waitForEmpty(pool)
        do { try await transcriber.prepare(); XCTFail() } catch {}
    }

    func testOwnerStopsPendingAndFutureFactories() async throws {
        let pool = WhisperWorkerPool(), fixture = WhisperProcessFixture()
        let owner = WhisperWorkerOwner()
        owner.stop()
        let client = try WhisperWorkerClient(configuration: configuration, pool: pool, run: fixture.run)
        XCTAssertThrowsError(try owner.install(client))
        client.stop(); await waitForEmpty(pool)
    }

    func testAudioInputFailureDoesNotLaunchInferenceOrLeakOperationSlot() async throws {
        let pool = WhisperWorkerPool(), fixture = WhisperProcessFixture()
        let client = try WhisperWorkerClient(configuration: configuration, pool: pool, run: fixture.run)
        do {
            _ = try await client.transcribe(audio: URL(fileURLWithPath: "/no-such-recording"), lowEnergy: false,
                                            prompt: nil, language: nil) { _ in }
            XCTFail()
        } catch {}
        let reply = try await client.request(.init(kind: .probe))
        XCTAssertEqual(reply.kind, .ready)
        client.stop(); await waitForEmpty(pool)
    }

    func testOnlyTwoChildrenAndModelFilesStayLeasedUntilConfirmedReaping() async throws {
        let pool = WhisperWorkerPool(), first = WhisperProcessFixture(delayReaping: true)
        let second = WhisperProcessFixture(delayReaping: true)
        let a = try WhisperWorkerClient(configuration: configuration, pool: pool, run: first.run)
        let b = try WhisperWorkerClient(configuration: configuration, pool: pool, run: second.run)
        _ = try await a.request(.init(kind: .probe)); _ = try await b.request(.init(kind: .probe))
        XCTAssertThrowsError(try WhisperWorkerClient(configuration: configuration, pool: pool, run: first.run))
        XCTAssertThrowsError(try pool.checkUnused(URL(fileURLWithPath: "/fixture")))
        XCTAssertThrowsError(try pool.checkUnused(URL(fileURLWithPath: "/fixture/models/small/child")))
        try pool.checkUnused(URL(fileURLWithPath: "/other"))
        a.stop(); b.stop()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(pool.activeCount, 2)
        first.reap(); second.reap()
        await waitForEmpty(pool)
        try pool.checkUnused(URL(fileURLWithPath: "/fixture"))
    }

    func testPoolShutdownFencesAdmissionAndStopsOwnedChildren() async throws {
        let pool = WhisperWorkerPool(), fixture = WhisperProcessFixture()
        let client = try WhisperWorkerClient(configuration: configuration, pool: pool, run: fixture.run)
        _ = try await client.request(.init(kind: .probe))
        await pool.shutdown()
        XCTAssertEqual(pool.activeCount, 0)
        XCTAssertThrowsError(try WhisperWorkerClient(configuration: configuration, pool: pool, run: fixture.run))
        do { _ = try await client.request(.init(kind: .probe)); XCTFail() } catch {}
    }

    func testPoolFailureBudgetSurvivesFacadeReplacementAndDoubleRelease() throws {
        let pool = WhisperWorkerPool(uptime: { 100 })
        let id = try pool.reserve(paths: [], stop: {})
        pool.release(id, failed: true)
        pool.release(id, failed: false)
        XCTAssertThrowsError(try pool.reserve(paths: [], stop: {}))
    }

    func testMalformedReplyAndWrongGenerationStopWithoutReplay() async throws {
        for mismatch in [false, true] {
            let pool = WhisperWorkerPool()
            let client = try WhisperWorkerClient(configuration: configuration, pool: pool) { request in
                let peer = try InferenceSocket(owning: dup(try XCTUnwrap(request.ipcDescriptor)))
                request.onStarted?()
                defer { peer.stop(); request.onReaped?() }
                let incoming = try peer.receive(deadline: .now.advanced(by: .seconds(1)))
                var reply = InferenceMessage(id: mismatch ? UUID() : incoming.id, kind: .ready)
                reply.sequence = mismatch ? 0 : 15
                try peer.send(reply, deadline: .now.advanced(by: .seconds(1)))
                // Wait for the owner to reject the response before collection.
                _ = try? peer.receive(deadline: .now.advanced(by: .seconds(1)))
                return .init(termination: .exited(0), exitCode: 0, stdout: "", stderr: "", outputTruncated: false)
            }
            do { _ = try await client.request(.init(kind: .probe)); XCTFail() } catch {
                XCTAssertEqual(error as? InferenceFailure, .protocolViolation)
            }
            await waitForEmpty(pool)
            XCTAssertThrowsError(try pool.reserve(paths: [], stop: {}))
        }
    }

    func testCancelledRequestStopsChildAndSuppressesLateResult() async throws {
        let pool = WhisperWorkerPool(), fixture = WhisperProcessFixture()
        let client = try WhisperWorkerClient(configuration: configuration, pool: pool, run: fixture.run)
        var request = InferenceMessage(kind: .prepare); request.configuration = configuration
        _ = try await client.request(request)
        let audio = try makeAudio()
        defer { try? FileManager.default.removeItem(at: audio) }
        let task = Task { try await client.transcribe(audio: audio, lowEnergy: false, prompt: nil, language: nil) { _ in } }
        try await Task.sleep(for: .milliseconds(30))
        task.cancel()
        do { _ = try await task.value; XCTFail() } catch {}
        await waitForEmpty(pool)
    }

    func testEngineFailureDoesNotRetryAndConcurrentRequestIsBusy() async throws {
        let pool = WhisperWorkerPool(), fixture = WhisperProcessFixture()
        let client = try WhisperWorkerClient(configuration: configuration, pool: pool, run: fixture.run)
        var request = InferenceMessage(kind: .prepare); request.configuration = configuration
        _ = try await client.request(request)
        let audio = try makeAudio()
        defer { try? FileManager.default.removeItem(at: audio) }
        let task = Task { try await client.transcribe(audio: audio, lowEnergy: false, prompt: nil, language: nil) { _ in } }
        try await Task.sleep(for: .milliseconds(30))
        do { _ = try await client.request(.init(kind: .probe)); XCTFail() } catch {
            XCTAssertEqual(error as? InferenceFailure, .busy)
        }
        _ = try await task.value
        client.stop(); await waitForEmpty(pool)
        let failingPool = WhisperWorkerPool(), failing = WhisperProcessFixture(fail: true)
        let failedClient = try WhisperWorkerClient(configuration: configuration, pool: failingPool, run: failing.run)
        _ = try await failedClient.request(request)
        do {
            _ = try await failedClient.transcribe(audio: audio, lowEnergy: false, prompt: nil, language: nil) { _ in }
            XCTFail()
        } catch { XCTAssertEqual(error as? InferenceFailure, .engineFailed) }
        await waitForEmpty(failingPool)
        XCTAssertEqual(failing.launches, 1)
    }

    func testLaunchFailureAndInvalidTimeoutAreBoundedAndRedacted() async throws {
        let pool = WhisperWorkerPool()
        XCTAssertThrowsError(try WhisperWorkerClient(configuration: configuration, pool: pool, timeout: .infinity))
        let client = try WhisperWorkerClient(configuration: configuration, pool: pool,
                                             executable: URL(fileURLWithPath: "/nonexistent-helper"), timeout: 0.1)
        do { _ = try await client.request(.init(kind: .probe)); XCTFail() } catch {
            XCTAssertFalse(error.localizedDescription.contains("nonexistent"))
        }
        await waitForEmpty(pool)
    }

    func testRealBundledHelperProbeAndMissingResourcesWithoutLoadingAModel() async throws {
        let working = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let profiles = working.appendingPathComponent(".build/inference-validation")
        try FileManager.default.createDirectory(at: profiles, withIntermediateDirectories: true)
        let app = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".app")
        defer { try? FileManager.default.removeItem(at: app) }
        let executable = WhisperWorkerClient.executableURL
        let directory = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        defer { close(directory) }
        let copy = try await ManagedProcess().run(.init(executable: "/bin/bash", arguments: [
            working.appendingPathComponent("scripts/copy_inference_helper.sh").path,
            executable.deletingLastPathComponent().path, app.path
        ], environment: ["PATH": "/usr/bin:/bin"], directoryDescriptor: directory, timeout: 5))
        XCTAssertEqual(copy.termination, .exited(0))
        let helper = app.appendingPathComponent("Contents/Helpers/TypefluxInferenceHelper")
        for resourcesPresent in [true, false] {
            let (parent, child) = try inferenceSocketPair()
            let request = ManagedProcess.Request(executable: helper.path, arguments: ["--ipc-fd", "100"],
                environment: ["PATH": "/usr/bin:/bin", "LLVM_PROFILE_FILE": profiles.appendingPathComponent("helper-%p.profraw").path],
                directoryDescriptor: directory, timeout: 5, outputLimit: 1024,
                immediateCleanupOnExit: true, ipcDescriptor: child.descriptor)
            let process = Task.detached { try await ManagedProcess().run(request) }
            if resourcesPresent {
                try parent.send(.init(kind: .probe), deadline: .now.advanced(by: .seconds(2)))
                let reply = try parent.receive(deadline: .now.advanced(by: .seconds(2)))
                XCTAssertEqual(reply.kind, .ready)
                // Reject a wrong-direction frame and allow normal exit/profile flush.
                try parent.send(.init(kind: .ready), deadline: .now.advanced(by: .seconds(2)))
            } else {
                XCTAssertThrowsError(try parent.receive(deadline: .now.advanced(by: .seconds(2))))
            }
            let result = try await process.value
            XCTAssertEqual(result.termination, .exited(0))
            parent.stop(); child.stop()
            if resourcesPresent {
                try FileManager.default.removeItem(at: app.appendingPathComponent("Contents/Helpers/swift-transformers_Hub.bundle"))
            }
        }
    }

    func testRealCrashingAndHangingChildrenCannotTakeDownTheHost() async throws {
        for code in ["ulimit -c 0; kill -KILL $$", "trap '' TERM; sleep 10"] {
            let pool = WhisperWorkerPool()
            let client = try WhisperWorkerClient(configuration: configuration, pool: pool, timeout: 0.1) { original in
                var request = original
                request.executable = "/bin/sh"; request.arguments = ["-c", code]
                return try await ManagedProcess().run(request)
            }
            let start = ContinuousClock.now
            do { _ = try await client.request(.init(kind: .probe)); XCTFail() } catch {}
            XCTAssertLessThan(start.duration(to: .now), .seconds(2))
            await waitForEmpty(pool)
        }
    }

    private func makeAudio() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        try Data("fixture audio".utf8).write(to: url)
        return url
    }

    private func waitForEmpty(_ pool: WhisperWorkerPool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<400 {
            if pool.activeCount == 0 { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Worker was not collected", file: file, line: line)
    }
}

private final class WhisperUpdates: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [TranscriptionSnapshot] = []
    func append(_ value: TranscriptionSnapshot) { lock.withLock { values.append(value) } }
    var count: Int { lock.withLock { values.count } }
    var finalCount: Int { lock.withLock { values.filter(\.isFinal).count } }
}

private final class WhisperProcessFixture: @unchecked Sendable {
    let engine: InferenceFixtureEngine
    private let lock = NSLock()
    private var count = 0
    private let delayReaping: Bool
    private var reaper: (@Sendable () -> Void)?
    init(delayReaping: Bool = false, fail: Bool = false) {
        self.delayReaping = delayReaping; engine = InferenceFixtureEngine(fail: fail)
    }
    var launches: Int { lock.withLock { count } }
    func reap() { lock.withLock { reaper }?() }
    func run(_ request: ManagedProcess.Request) async throws -> ManagedProcess.Result {
        let peer = try InferenceSocket(owning: dup(try XCTUnwrap(request.ipcDescriptor)))
        lock.withLock { count += 1; reaper = request.onReaped }
        request.onStarted?()
        await InferenceServer(engine: engine).serve(socket: peer)
        if !delayReaping { request.onReaped?() }
        return .init(termination: Task.isCancelled ? .cancelled : .exited(0), exitCode: 0,
                     stdout: "", stderr: "", outputTruncated: false)
    }
}
