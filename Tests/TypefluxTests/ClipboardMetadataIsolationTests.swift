import AppKit
import Darwin
import SwiftUI
import XCTest
import TypefluxMediaProtocol
import TypefluxMediaRuntime
@testable import Typeflux

private final class ClipboardMetadataBlock: @unchecked Sendable {
    let gate = DispatchSemaphore(value: 0), lock = NSLock()
    private var calls = 0
    var count: Int { lock.withLock { calls } }
    func run() throws -> ManagedProcess.Result { lock.withLock { calls += 1 }; gate.wait(); throw MediaFailure.unavailable }
}
private actor ClipboardMetadataPending {
    var calls = 0
    var continuation: CheckedContinuation<MediaClipboardResult, Error>?
    func read() async throws -> MediaClipboardResult { calls += 1; return try await withCheckedThrowingContinuation { continuation = $0 } }
    var started: Bool { continuation != nil }
    func resolve(_ value: MediaClipboardResult) { continuation?.resume(returning: value); continuation = nil }
}

@MainActor final class ClipboardMetadataIsolationTests: XCTestCase {
    private func directory() throws -> URL { try AskAttachmentFixture.directory() }
    private func worker() throws -> MediaWorker {
        let folder = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/clipboard-metadata-validation")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return MediaWorker(timeout: 10, run: { request, cancelled in
            var request = request; request.environment["LLVM_PROFILE_FILE"] = folder.appendingPathComponent("helper-%p.profraw").path
            return try ManagedProcess().runBlocking(request, isCancelled: cancelled)
        })
    }
    private func request(_ kind: MediaClipboardOptions.Kind) -> MediaRequest {
        var value = MediaRequest(operation: .clipboardMedia); value.clipboard = .init(kind: kind); return value
    }
    private func access(_ scope: AskImagePresentationScope) -> AskImagePresentationAccess {
        .init(scope: scope, epoch: scope.epoch, authorize: { true })
    }
    private var projectionRequest: ClipboardMediaInfoProvider.Request {
        .init(url: URL(fileURLWithPath: "/private/synthetic.pdf"), options: .init(kind: .pdf))
    }
    func testProtocolRejectsMissingMixedWrongIdentityAndUnboundedMetadata() throws {
        for kind in [MediaClipboardOptions.Kind.pdf, .duration, .waveform] {
            var value = request(kind)
            var response = MediaResponse(id: value.id)
            response.clipboard = kind == .pdf ? .init(pages: 3) : .init(duration: 601, waveform: kind == .waveform ? Array(repeating: 0, count: 180) : nil)
            try response.validate(for: value)
            let mutations: [(inout MediaResponse) -> Void] = [
                { $0.id = UUID() }, { $0.version = 99 }, { $0.clipboard = nil }, { $0.items = [.init(text: "x")] },
                { $0.failure = .unavailable }, { $0.preview = .init(rasters: []) }, { $0.normalization = .png },
                { $0.generatedImage = .init(mediaType: "image/png", width: 1, height: 1) }
            ]
            for mutate in mutations { var invalid = response; mutate(&invalid); XCTAssertThrowsError(try invalid.validate(for: value)) }
            value.preview = .init(width: 1, height: 1); XCTAssertThrowsError(try value.validate())
            value = request(kind); value.clipboard = nil; XCTAssertThrowsError(try value.validate())
        }
        XCTAssertThrowsError(try MediaClipboardOptions(kind: .pdf, container: .wav).validate())
        for value in [MediaClipboardResult(pages: 0), .init(pages: 1_000_001), .init(duration: 1, pages: 1), .init(pages: 1, waveform: [])] {
            XCTAssertThrowsError(try value.validate(for: .init(kind: .pdf)))
        }
        for duration in [Double.nan, .infinity, -1, 0, MediaAVLimits.maximumDuration + 1] {
            XCTAssertThrowsError(try MediaClipboardResult(duration: duration).validate(for: .init(kind: .duration)))
        }
        XCTAssertThrowsError(try MediaClipboardResult(duration: 1, waveform: []).validate(for: .init(kind: .duration)))
        for samples in [[Float](), [0], Array(repeating: Float.nan, count: 180), Array(repeating: 1.1, count: 180), Array(repeating: -0.1, count: 180)] {
            XCTAssertThrowsError(try MediaClipboardResult(duration: 1, waveform: samples).validate(for: .init(kind: .waveform)))
        }
        var legacy = MediaResponse(id: UUID()); legacy.clipboard = .init(pages: 1)
        var old = MediaRequest(id: legacy.id, operation: .image)
        XCTAssertThrowsError(try legacy.validate(for: old)); old.clipboard = .init(kind: .pdf); XCTAssertThrowsError(try old.validate())
    }

    func testPCMAdmissionAndPeakArithmeticAreBounded() throws {
        var value = MediaClipboardWaveformAccumulator(bars: Int.max, expectedSamples: Int.max)
        XCTAssertEqual(value.peaks.count, 180)
        for bytes in [-1, 1, Int.max, MediaAVLimits.chunkBytes + 4] { XCTAssertThrowsError(try value.admit(bytes: bytes)) }
        try value.admit(bytes: 0)
        for _ in 0..<6 { try value.admit(bytes: MediaAVLimits.chunkBytes) }
        XCTAssertThrowsError(try value.admit(bytes: 4))
        value.add([.nan, .infinity, -.infinity, -0.5]); XCTAssertEqual(value.levels()[0], 1)
        XCTAssertTrue(value.levels().allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 })
        for bars in [-1, 0, 181, Int.max] { XCTAssertEqual(ClipboardMediaInfoProvider.resample([0], to: bars), []) }
        XCTAssertEqual(ClipboardMediaInfoProvider.resample([.nan], to: 1), [])
        XCTAssertEqual(ClipboardMediaInfoProvider.resample(Array(repeating: 0, count: 181), to: 1), [])
    }

    func testRealHelperReadsPDFDurationAndWaveformAndRereadsChangedFile() async throws {
        let folder = try directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let worker = try worker(), provider = ClipboardMediaInfoProvider(worker: worker)
        let pdf = ClipboardTestSupport.makePDF(named: "sample.pdf", in: folder, pages: 2)
        let first = await provider.info(for: pdf, kind: .pdf); XCTAssertEqual(first?.pageCount, 2)
        _ = ClipboardTestSupport.makePDF(named: "sample.pdf", in: folder, pages: 4)
        let next = await provider.loadInfo(for: ClipboardTestSupport.entry(.pdf, filePaths: [pdf.path])); XCTAssertEqual(next?.pageCount, 4)
        let wav = try ClipboardTestSupport.makeAudioFile(named: "sound.wav", in: folder, seconds: 1)
        let duration = await provider.info(for: wav, kind: .video); XCTAssertEqual(duration?.duration ?? 0, 1, accuracy: 0.05)
        let levels = await provider.waveform(for: wav, bars: 180); XCTAssertEqual(levels?.count, 180)
        XCTAssertEqual(levels?.max() ?? 0, 1, accuracy: 0.001)
        let none = await provider.loadInfo(for: ClipboardTestSupport.entry(.text)); XCTAssertNil(none)
        XCTAssertNil(ClipboardMediaInfoProvider.Request.info(ClipboardTestSupport.entry(.document, filePaths: [wav.path])))
        await worker.shutdown()
    }

    func testRealHelperKeeps600SecondWindowInsteadOfPreview30Seconds() async throws {
        let folder = try directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let wav = folder.appendingPathComponent("long.wav")
        var pcm = Data(repeating: 0, count: 601 * 8000 * 2)
        // A pulse at 300s must be included; one after 600s must not change normalization.
        for second in [300, 600] {
            let amplitude: Int16 = second == 300 ? 1000 : 30000
            for i in 0..<8000 { let offset = (second * 8000 + i) * 2; pcm[offset] = UInt8(truncatingIfNeeded: amplitude); pcm[offset + 1] = UInt8(truncatingIfNeeded: amplitude >> 8) }
        }
        var wave = Data("RIFF".utf8)
        func append<T: FixedWidthInteger>(_ value: T) { var v = value.littleEndian; withUnsafeBytes(of: &v) { wave.append(contentsOf: $0) } }
        append(UInt32(pcm.count + 36)); wave.append(Data("WAVEfmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1)); append(UInt32(8000)); append(UInt32(16000)); append(UInt16(2)); append(UInt16(16)); wave.append(Data("data".utf8)); append(UInt32(pcm.count)); wave.append(pcm); try wave.write(to: wav)
        let worker = try worker(), provider = ClipboardMediaInfoProvider(worker: worker)
        let result = try await provider.load(try XCTUnwrap(ClipboardMediaInfoProvider.Request.waveform(wav)))
        XCTAssertEqual(result.duration, 601); let levels = try XCTUnwrap(result.waveform)
        XCTAssertEqual(levels.count, 180); XCTAssertGreaterThan(levels[90], 0.9); XCTAssertEqual(levels[179], 0)
        await worker.shutdown()
    }

    func testRealHelperMalformedInputsAndHostInputLimitsRetainOriginals() async throws {
        let folder = try directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let worker = try worker(), provider = ClipboardMediaInfoProvider(worker: worker)
        for kind in [MediaClipboardOptions.Kind.pdf, .duration, .waveform] {
            let file = folder.appendingPathComponent("bad.wav"), bytes = Data("broken".utf8); try bytes.write(to: file)
            do { _ = try await provider.load(.init(url: file, options: .init(kind: kind))); XCTFail() } catch {}
            XCTAssertEqual(try Data(contentsOf: file), bytes)
        }
        await worker.shutdown()
        let guarded = ClipboardMediaInfoProvider(worker: MediaWorker(run: { _, _ in XCTFail("Invalid source dispatched"); throw MediaFailure.unavailable }))
        let huge = folder.appendingPathComponent("huge.pdf"); FileManager.default.createFile(atPath: huge.path, contents: Data())
        let output = try FileHandle(forWritingTo: huge); try output.truncate(atOffset: 513 * 1024 * 1024); try output.close()
        for url in [huge, URL(string: "https://example.test/a.pdf")!, folder, folder.appendingPathComponent("missing"), URL(fileURLWithPath: "/" + String(repeating: "x", count: 4096))] {
            do { _ = try await guarded.load(.init(url: url, options: .init(kind: .pdf))); XCTFail() } catch {}
        }
    }

    func testCancellationKeepsTwoAdmissionsUntilWorkActuallyReturns() async throws {
        let folder = try directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("valid.pdf"); try Data("private".utf8).write(to: file)
        let block = ClipboardMetadataBlock(), worker = MediaWorker(run: { _, _ in try block.run() }), request = ClipboardMediaInfoProvider.Request(url: file, options: .init(kind: .pdf))
        let provider = ClipboardMediaInfoProvider(worker: worker)
        let one = Task { try await provider.load(request) }, two = Task { try await provider.load(request) }
        for _ in 0..<200 where block.count < 2 { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(block.count, 2); one.cancel(); two.cancel()
        do { _ = try await provider.load(request); XCTFail() } catch {}
        XCTAssertEqual(block.count, 2); block.gate.signal(); block.gate.signal()
        _ = try? await one.value; _ = try? await two.value; XCTAssertEqual(worker.activeCount, 0)
    }

    func testChangedSourceAfterChildResponseIsRejected() async throws {
        let folder = try directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("sample.pdf"); try Data("original".utf8).write(to: file)
        let worker = MediaWorker(run: { command, _ in
            let request = try JSONDecoder().decode(MediaRequest.self, from: try XCTUnwrap(command.stdin))
            var response = MediaResponse(id: request.id); response.clipboard = .init(pages: 1)
            try Data("replaced content".utf8).write(to: file)
            return .init(termination: .exited(0), exitCode: 0, stdout: String(decoding: try JSONEncoder().encode(response), as: UTF8.self), stderr: "", outputTruncated: false)
        })
        do { _ = try await ClipboardMediaInfoProvider(worker: worker).load(.init(url: file, options: .init(kind: .pdf))); XCTFail() } catch { XCTAssertEqual(error as? MediaFailure, .unreadable) }
        XCTAssertEqual(try Data(contentsOf: file), Data("replaced content".utf8))
    }

    func testHarmlessChildCrashAndHangCannotReplayOrDeleteSource() async throws {
        let folder = try directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("source.pdf"), bytes = Data("private source".utf8); try bytes.write(to: file)
        for body in ["kill -KILL $$", "trap '' TERM; while :; do sleep 1; done"] {
            let child = folder.appendingPathComponent(UUID().uuidString); try ("#!/bin/sh\n" + body + "\n").write(to: child, atomically: false, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: child.path)
            let worker = MediaWorker(executable: child, timeout: 0.1), provider = ClipboardMediaInfoProvider(worker: worker)
            do { _ = try await provider.load(.init(url: file, options: .init(kind: .pdf))); XCTFail() } catch {}
            await worker.shutdown(); XCTAssertEqual(worker.activeCount, 0); XCTAssertEqual(try Data(contentsOf: file), bytes)
        }
    }

    func testProjectionRetainsAttemptIdentityAndRejectsInvalidResults() async {
        let scope = AskImagePresentationScope(), request = projectionRequest
        var calls = 0
        let model = ClipboardMediaProjection(read: { _ in await MainActor.run { calls += 1 }; return .init(pages: 0) })
        await model.load(request, access: access(scope)); await model.load(request, access: access(scope))
        XCTAssertNil(model.value); XCTAssertEqual(calls, 1)
        scope.invalidate(); await model.load(request, access: access(scope)); XCTAssertEqual(calls, 2)
        model.cancel(); await model.load(nil, access: access(scope)); XCTAssertNil(model.value)
    }

    func testProjectionRejectsLateResultsOldAccessAndClearsOnRevocation() async throws {
        let scope = AskImagePresentationScope(), pending = ClipboardMetadataPending(), old = access(scope)
        let request = projectionRequest, model = ClipboardMediaProjection(read: { request in
            if request.options.kind == .pdf { return try await pending.read() }; return .init(duration: 2)
        })
        let task = Task { await model.load(request, access: old) }
        for _ in 0..<100 { if await pending.started { break }; try await Task.sleep(for: .milliseconds(5)) }
        scope.invalidate()
        let new = ClipboardMediaInfoProvider.Request(url: request.url, options: .init(kind: .duration)), current = access(scope)
        await model.load(new, access: current); XCTAssertEqual(model.value?.duration, 2)
        await pending.resolve(.init(pages: 7)); await task.value
        await model.load(request, access: old); XCTAssertEqual(model.displayed(new, access: current)?.duration, 2)
        XCTAssertNil(model.displayed(request, access: current)); scope.setVisible(false); XCTAssertNil(model.value)
    }

    func testAuthorizationAfterAwaitAndScopeCapacityAreEnforced() async throws {
        let scope = AskImagePresentationScope(), pending = ClipboardMetadataPending(), request = projectionRequest
        var allowed = true
        let authorization = AskImagePresentationAccess(scope: scope, epoch: scope.epoch, authorize: { allowed })
        let model = ClipboardMediaProjection(read: { _ in try await pending.read() }), task = Task { await model.load(request, access: authorization) }
        for _ in 0..<100 { if await pending.started { break }; try await Task.sleep(for: .milliseconds(5)) }
        allowed = false; await pending.resolve(.init(pages: 2)); await task.value; XCTAssertNil(model.value)
        let models = (0..<17).map { _ in ClipboardMediaProjection(read: { _ in .init(pages: 1) }) }
        for model in models { await model.load(request, access: access(scope)) }
        XCTAssertEqual(models.filter { $0.value != nil }.count, 16)
        scope.invalidate(); XCTAssertTrue(models.allSatisfy { $0.value == nil })
    }

    func testActualViewShowsMetadataThenClearsOnScopeRetirement() async throws {
        let scope = AskImagePresentationScope(), model = ClipboardMediaProjection(read: { _ in .init(pages: 7) }), request = projectionRequest
        let view = NSHostingView(rootView: ClipboardMediaValue(request: request, model: model) { value in
            VStack(alignment: .leading) {
                Text("Clipboard document").font(.title2)
                Text(value?.pages.map { "\($0) pages" } ?? "Metadata unavailable")
            }.padding(24).frame(width: 320, height: 120).background(Color.white).foregroundStyle(.black)
        }.environment(\.askContextImageAccess, access(scope)))
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 320, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view; window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); view.removeFromSuperview() }
        for _ in 0..<100 where model.value == nil { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(model.value?.pages, 7); try await Task.sleep(for: .milliseconds(100))
        view.layoutSubtreeIfNeeded(); let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds)); view.cacheDisplay(in: view.bounds, to: bitmap)
        let folder = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/clipboard-metadata-validation")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: folder.appendingPathComponent("clipboard-metadata.png"))
        scope.setVisible(false); XCTAssertNil(model.value)
    }
}
