import AVFoundation
import XCTest
import TypefluxMediaProtocol
import TypefluxMediaRuntime
@testable import Typeflux

final class MediaAVPreviewTests: XCTestCase {
    private func request(video: Bool = false, start: Double = 0) -> MediaRequest {
        var request = MediaRequest(operation: video ? .previewVideo : .previewAudio)
        request.preview = .init(width: 100, height: 80, start: start)
        return request
    }
    private func audioResult(start: Double = 0) -> MediaPreviewResult {
        var result = MediaPreviewResult(rasters: [])
        result.duration = 31; result.start = start; result.waveform = Array(repeating: 0, count: 80)
        return result
    }

    func testTimingAndWaveformProtocolRejectsNonfiniteWrongIdentityAndMixedPayloads() throws {
        let request = request(start: 30)
        try audioResult(start: 30).validate(for: request)
        let mutations: [(inout MediaPreviewResult) -> Void] = [
            { $0.duration = nil }, { $0.duration = .infinity }, { $0.duration = -1 },
            { $0.duration = MediaAVLimits.maximumDuration + 1 }, { $0.start = .nan }, { $0.start = 29 },
            { $0.pages = 1 }, { $0.waveform = nil }, { $0.waveform = [0] },
            { $0.waveform?[0] = .infinity }, { $0.waveform?[0] = -0.1 }, { $0.waveform?[0] = 1.1 },
            { $0.rasters = [.init(width: 1, height: 1)] }
        ]
        for mutate in mutations {
            var result = audioResult(start: 30); mutate(&result)
            XCTAssertThrowsError(try result.validate(for: request))
        }
        var video = audioResult(start: 30); video.waveform = nil; video.rasters = [.init(width: 10, height: 10)]
        try video.validate(for: self.request(video: true, start: 30))
        video.waveform = []
        XCTAssertThrowsError(try video.validate(for: self.request(video: true, start: 30)))
        var wrong = request; wrong.preview?.start = .nan
        XCTAssertThrowsError(try wrong.validate())
        wrong = request; wrong.preview?.page = 1
        XCTAssertThrowsError(try wrong.validate())
        wrong = request; wrong.preview?.passage = "private"
        XCTAssertThrowsError(try wrong.validate())
        var response = MediaResponse(id: UUID()); response.preview = audioResult(start: 30)
        XCTAssertThrowsError(try response.validate(for: request))
        let encoded = try JSONEncoder().encode(request)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var options = try XCTUnwrap(object["preview"] as? [String: Any])
        options["container"] = "../../outside"
        object["preview"] = options
        XCTAssertThrowsError(try JSONDecoder().decode(MediaRequest.self, from: JSONSerialization.data(withJSONObject: object)))
        XCTAssertEqual(MediaAVLimits.start(.nan, duration: 31), 0)
        XCTAssertEqual(MediaAVLimits.start(-10, duration: 31), 0)
        XCTAssertEqual(MediaAVLimits.start(100, duration: 31), 30.999)
        XCTAssertEqual(MediaAVLimits.start(1, duration: 0), 0)
    }

    func testWaveformBoundsPrerollWindowSilenceAndNonfiniteSamples() throws {
        var accumulator = MediaWaveformAccumulator(start: 10, window: 30)
        try accumulator.admit(bytes: 0)
        XCTAssertEqual(accumulator.normalized, Array(repeating: 0, count: 80))
        try accumulator.append([100], time: 9)
        try accumulator.append([100], time: 40)
        try accumulator.append([.nan, .infinity, -0.5], time: 10)
        try accumulator.append([0.25], time: 25)
        XCTAssertEqual(accumulator.normalized[0], 1)
        XCTAssertEqual(accumulator.normalized[40], 0.5)
        XCTAssertThrowsError(try accumulator.append([], time: .nan))
        for count in [-1, 1, MediaAVLimits.chunkBytes + 4, Int.max] {
            XCTAssertThrowsError(try accumulator.admit(bytes: count))
        }
        for _ in 0 ..< MediaAVLimits.decodedBytes / MediaAVLimits.chunkBytes {
            try accumulator.admit(bytes: MediaAVLimits.chunkBytes)
        }
        XCTAssertThrowsError(try accumulator.admit(bytes: 4))
    }

    private func directory() throws -> URL { try AskAttachmentFixture.directory() }
    private func wave(_ url: URL) throws {
        let samples = Array(repeating: Float(0), count: 30 * 16000) + Array(repeating: Float(0.5), count: 16000)
        try samples.withUnsafeBytes { try SemanticMediaExtractor.wave(Data($0), to: url) }
    }
    private func movie(_ url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.jpeg, AVVideoWidthKey: 64, AVVideoHeightKey: 32
        ])
        input.transform = CGAffineTransform(translationX: 32, y: 0).rotated(by: .pi / 2)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 32
        ])
        writer.add(input); XCTAssertTrue(writer.startWriting()); writer.startSession(atSourceTime: .zero)
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 64, 32, kCVPixelFormatType_32ARGB, nil, &buffer), kCVReturnSuccess)
        let frame = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(frame, [])
        memset(CVPixelBufferGetBaseAddress(frame), 128, CVPixelBufferGetDataSize(frame))
        CVPixelBufferUnlockBaseAddress(frame, [])
        for index in 0..<3 {
            for _ in 0..<100 where !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            XCTAssertTrue(adaptor.append(frame, withPresentationTime: CMTime(value: Int64(index), timescale: 2)))
        }
        input.markAsFinished(); await writer.finishWriting(); XCTAssertEqual(writer.status, .completed)
    }

    func testNativeAudioSelectionAndVideoTransform() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("input"); try wave(input)
        let first = try await MediaAVDecoder.decode(request(), directory: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("decode.wav").path))
        XCTAssertEqual(first.preview?.duration, 31)
        XCTAssertEqual(first.preview?.waveform, Array(repeating: 0, count: 80))
        let selected = try await MediaAVDecoder.decode(request(start: 30), directory: root)
        XCTAssertEqual(selected.preview?.start, 30)
        XCTAssertTrue(try XCTUnwrap(selected.preview?.waveform).contains { $0 > 0 })
        try FileManager.default.removeItem(at: input)
        try await movie(input)
        let frame = try await MediaAVDecoder.decode(request(video: true, start: 1), directory: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("decode.mov").path))
        XCTAssertEqual(frame.preview?.start, 1)
        let raster = try XCTUnwrap(frame.preview?.rasters.first)
        XCTAssertLessThan(raster.width, raster.height)
        XCTAssertLessThanOrEqual(raster.width, 100); XCTAssertLessThanOrEqual(raster.height, 80)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("raster-0")).count, raster.bytes)
        do { _ = try await MediaAVDecoder.decode(request(), directory: root); XCTFail("No audio track") } catch {}
    }

    func testMalformedOversizedAndCancelledNativeRequestsFail() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("input"); try Data("broken media".utf8).write(to: input)
        for video in [false, true] {
            do { _ = try await MediaAVDecoder.decode(request(video: video), directory: root); XCTFail("Malformed media") } catch {}
        }
        do { _ = try await MediaAVDecoder.decode(MediaRequest(operation: .image), directory: root); XCTFail("Wrong operation") } catch {}
        let file = try FileHandle(forWritingTo: input)
        try file.truncate(atOffset: UInt64(MediaAVLimits.inputBytes + 1)); try file.close()
        do { _ = try await MediaAVDecoder.decode(request(), directory: root); XCTFail("Oversize") }
        catch { XCTAssertEqual(error as? MediaFailure, .tooLarge) }
        try wave(input)
        let task = Task { try await MediaAVDecoder.decode(self.request(), directory: root) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled") } catch {}
    }

    private func instrumentedWorker() throws -> MediaWorker {
        let profiles = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/av-preview-validation")
        try FileManager.default.createDirectory(at: profiles, withIntermediateDirectories: true)
        return MediaWorker(run: { process, cancelled in
            var process = process
            process.environment["LLVM_PROFILE_FILE"] = profiles.appendingPathComponent("helper-%p.profraw").path
            return try ManagedProcess().runBlocking(process, isCancelled: cancelled)
        })
    }
    func testRealHelperHostBridgeAndRedactedFailures() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("source.WAV"); try wave(input)
        let worker = try instrumentedWorker()
        let audio = try MediaPreviewDisplay.renderAV(input, pixels: .init(width: 100, height: 80), video: false,
            start: 30, cancellation: AskSearchCancellation(), worker: worker)
        XCTAssertEqual(audio.start, 30); XCTAssertEqual(audio.duration, 31)
        XCTAssertTrue(audio.waveform.contains { $0 > 0 }); XCTAssertTrue(audio.images.isEmpty)
        let zero = try MediaPreviewDisplay.renderAV(input, pixels: .init(width: 100, height: 80), video: false,
            start: .nan, cancellation: AskSearchCancellation(), worker: worker)
        XCTAssertEqual(zero.start, 0)
        try FileManager.default.removeItem(at: input)
        let movieInput = root.appendingPathComponent("source.mov"); try await movie(movieInput)
        let video = try MediaPreviewDisplay.renderAV(movieInput, pixels: .init(width: 100, height: 80), video: true,
            start: 1, cancellation: AskSearchCancellation(), worker: worker)
        XCTAssertEqual(video.images.count, 1); XCTAssertEqual(video.start, 1)
        try Data("private damaged file".utf8).write(to: input)
        XCTAssertThrowsError(try MediaPreviewDisplay.renderAV(input, pixels: .init(width: 100, height: 80), video: true,
            start: 0, cancellation: AskSearchCancellation(), worker: worker)) { XCTAssertEqual($0 as? MediaFailure, .unreadable) }
        await worker.shutdown(); XCTAssertEqual(worker.activeCount, 0)
    }

    func testSeparateInputLimitsAndLateResultRejection() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("sparse")
        FileManager.default.createFile(atPath: input.path, contents: nil)
        let file = try FileHandle(forWritingTo: input); defer { try? file.close() }
        try file.truncate(atOffset: UInt64(MediaLimits.inputBytes + 1))
        let state = AVPreviewState()
        let worker = MediaWorker(run: { process, _ in
            state.calls += 1
            let request = try JSONDecoder().decode(MediaRequest.self, from: XCTUnwrap(process.stdin))
            var response = MediaResponse(id: request.id); response.preview = self.audioResult()
            return .init(termination: .exited(0), exitCode: 0,
                stdout: String(decoding: try JSONEncoder().encode(response), as: UTF8.self), stderr: "", outputTruncated: false)
        })
        _ = try worker.perform(.previewAudio, input: .file(input), preview: request().preview, isCancelled: { false }) { _, _ in () }
        XCTAssertEqual(state.calls, 1)
        XCTAssertThrowsError(try worker.decode(.image, input: .file(input)))
        try file.truncate(atOffset: UInt64(MediaAVLimits.inputBytes + 1))
        XCTAssertThrowsError(try worker.perform(.previewAudio, input: .file(input), preview: request().preview,
                                               isCancelled: { false }) { _, _ in () })
        XCTAssertEqual(state.calls, 1)
        try file.truncate(atOffset: 1)
        XCTAssertThrowsError(try worker.perform(.previewAudio, input: .file(input), preview: request().preview,
                                               isCancelled: { state.cancelled }) { _, _ in state.cancelled = true })
        XCTAssertEqual(state.calls, 2); XCTAssertEqual(worker.activeCount, 0)
    }
}
private final class AVPreviewState: @unchecked Sendable { var calls = 0; var cancelled = false }
