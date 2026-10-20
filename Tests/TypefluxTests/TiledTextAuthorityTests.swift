import CoreGraphics
import Foundation
import Testing
import TypefluxMediaProtocol
@testable import Typeflux

private final class TiledAuthorityState: @unchecked Sendable {
    private let lock = NSLock()
    private var runs = 0, crops = 0, preparations = 0
    var counts: [Int] { lock.withLock { [runs, crops, preparations] } }
    func run() { lock.withLock { runs += 1 } }
    func crop() { lock.withLock { crops += 1 } }
    func prepare() { lock.withLock { preparations += 1 } }
}
private final class TiledAuthorityGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var held = true
    func wait() {
        condition.lock(); defer { condition.unlock() }
        while held { condition.wait() }
    }
    func release() { condition.withLock { held = false; condition.broadcast() } }
}
private actor TiledCustomReader: ImageTextRecognizing {
    private(set) var heights: [Int] = []
    private(set) var files = 0
    func recognizeText(in source: ImageTextSource) async throws -> RecognizedText {
        if case let .image(image) = source { heights.append(image.height) } else { files += 1 }
        return .init(lines: [])
    }
}

@Suite("Tiled text original batch authority", .serialized, .exclusiveUIState)
@MainActor struct TiledTextAuthorityTests {
    private func image(height: Int = 10) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: 8, height: height, bitsPerComponent: 8,
            bytesPerRow: 32, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        return try #require(context.makeImage())
    }
    private func worker(_ state: TiledAuthorityState) -> MediaWorker {
        MediaWorker(executable: URL(fileURLWithPath: "/usr/bin/true"), requiresLifecycle: true, run: { p, _ in
            state.run()
            let input = try JSONDecoder().decode(MediaRequest.self, from: p.stdin!)
            let box = CGRect(x: 0.1, y: 0.5, width: 0.6, height: 0.1)
            var response = MediaResponse(id: input.id)
            response.recognition = .init(lines: [.init(text: "a@example.com", confidence: 0.9, box: box,
                regions: [.init(kind: .email, range: .init(location: 0, length: 13), box: box)])])
            return .init(termination: .exited(0), exitCode: 0,
                stdout: String(decoding: try JSONEncoder().encode(response), as: UTF8.self), stderr: "", outputTruncated: false)
        })
    }
    private func native(_ worker: MediaWorker, state: TiledAuthorityState) -> VisionImageTextRecognizer {
        VisionImageTextRecognizer(worker: worker, readPixels: { image, shape in
            state.prepare(); return try VisionImageTextRecognizer.pixels(image, shape: shape)
        })
    }
    private func wait(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(condition())
    }

    @Test(arguments: [2, 3])
    func recoveryBetweenCompletedBandsCannotContinueOrMergeOldBatch(_ heldBand: Int) async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let state = TiledAuthorityState(), worker = self.worker(state), gate = TiledAuthorityGate(), image = try image()
        defer { gate.release() }
        let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .textRecognition)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.textRecognition)
        let reader = TiledImageTextRecognizer(base: native(worker, state: state), bandHeight: 4, overlap: 1,
            crop: { image, rect in
                let piece = image.cropping(to: rect); state.crop()
                if rect.minY == CGFloat((heldBand - 1) * 3) { gate.wait() }; return piece
            })
        let pending = Task { try await reader.recognizeText(in: .image(image)) }
        await wait { state.counts[1] == heldBand }
        // The prior band's actual native invocation has returned; the next has not entered.
        #expect(state.counts == [heldBand - 1, heldBand, heldBand - 1] && worker.activeCount == 0)
        await registry.disable(.textRecognition); try await registry.start(.textRecognition)
        gate.release()
        do { _ = try await pending.value; Issue.record("Old batch returned mixed-generation text") } catch {}
        #expect(state.counts[0] == heldBand - 1 && state.counts[2] == heldBand - 1)
        let fresh = try await reader.recognizeText(in: .image(image))
        #expect(fresh.lines.count == 3 && state.counts[0] == heldBand + 2)
        await registry.shutdown()
    }

    @Test func preReadyAndPrecancelledWholeBatchesDoNotCropOrPrepare() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let state = TiledAuthorityState(), worker = self.worker(state), image = try image()
        let reader = TiledImageTextRecognizer(base: native(worker, state: state), bandHeight: 4, overlap: 1,
            crop: { image, rect in state.crop(); return image.cropping(to: rect) })
        do { _ = try await reader.recognizeText(in: .image(image)); Issue.record("Pre-ready batch") } catch {}
        #expect(state.counts == [0, 0, 0])
        let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .textRecognition)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.textRecognition)
        #expect(state.counts == [0, 0, 0])
        let pending = Task { withUnsafeCurrentTask { $0?.cancel() }; return try await reader.recognizeText(in: .image(image)) }
        do { _ = try await pending.value; Issue.record("Canceled batch") } catch {}
        #expect(state.counts == [0, 0, 0])
        #expect(try await reader.recognizeText(in: .image(image)).lines.count == 3)
        await registry.shutdown()
    }

    @Test func canceledBetweenBandWorkRetainsBothBatchSlotsUntilActualReturn() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let state = TiledAuthorityState(), worker = self.worker(state), gate = TiledAuthorityGate(), image = try image()
        defer { gate.release() }
        let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .textRecognition)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.textRecognition)
        let reader = TiledImageTextRecognizer(base: native(worker, state: state), bandHeight: 4, overlap: 1,
            crop: { image, rect in
                let piece = image.cropping(to: rect); state.crop()
                if rect.minY == 3 { gate.wait() }; return piece
            })
        let a = Task { try await reader.recognizeText(in: .image(image)) }
        let b = Task { try await reader.recognizeText(in: .image(image)) }
        await wait { state.counts[1] == 4 }; a.cancel(); b.cancel()
        #expect(state.counts == [2, 4, 2] && worker.activeCount == 0)
        do { _ = try await reader.recognizeText(in: .image(image)); Issue.record("Freed occupied batch slot") } catch {}
        gate.release(); _ = await a.result; _ = await b.result
        #expect(state.counts == [2, 4, 2])
        #expect(try await reader.recognizeText(in: .image(image)).lines.count == 3)
        await registry.shutdown()
    }

    @Test func exactRegionsAndShortOrFileNativePathsKeepTheirContracts() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let state = TiledAuthorityState(), worker = self.worker(state)
        let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .textRecognition)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.textRecognition)
        let reader = TiledImageTextRecognizer(base: native(worker, state: state), bandHeight: 4, overlap: 1)
        let text = try await reader.recognizeText(in: .image(image()))
        #expect(text.lines.count == 3)
        for line in text.lines {
            #expect(line.locate?(.init(location: 0, length: 13)) == line.boundingBox)
            #expect(line.locate?(.init(location: 0, length: 1)) == nil)
        }
        #expect(ScreenshotSensitiveInfoDetector.findings(in: text).count == 3)
        #expect(try await reader.recognizeText(in: .image(image(height: 4))).lines.count == 1)
        let file = root.appendingPathComponent("private.bytes"); try Data([1, 2, 3]).write(to: file)
        #expect(try await reader.recognizeText(in: .url(file)).string == "a@example.com")
        #expect(state.counts[0] == 5 && worker.activeCount == 0)
        await registry.shutdown()
    }

    @Test func customActorBaseNeedsNoNativeLaneAndStillReceivesEveryBand() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let base = TiledCustomReader(), reader = TiledImageTextRecognizer(base: base, bandHeight: 4, overlap: 1)
        #expect(try await reader.recognizeText(in: .image(image())).lines.isEmpty)
        #expect(try await reader.recognizeText(in: .image(image(height: 4))).lines.isEmpty)
        #expect(try await reader.recognizeText(in: .url(root.appendingPathComponent("not-read"))).lines.isEmpty)
        let heights = await base.heights, files = await base.files
        #expect(heights == [4, 4, 4, 4] && files == 1)
    }

    @Test func failedCropDoesNotReturnPartialTextOrPoisonNextExplicitBatch() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let state = TiledAuthorityState(), worker = self.worker(state), image = try image()
        let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .textRecognition)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.textRecognition)
        let base = native(worker, state: state)
        let reader = TiledImageTextRecognizer(base: base, bandHeight: 4, overlap: 1,
            crop: { image, rect in rect.minY == 3 ? nil : image.cropping(to: rect) })
        do { _ = try await reader.recognizeText(in: .image(image)); Issue.record("Partial batch escaped") } catch {}
        #expect(state.counts[0] == 1 && module.module.health.current?.state == .ready)
        #expect(try await TiledImageTextRecognizer(base: base, bandHeight: 4, overlap: 1).recognizeText(in: .image(image)).lines.count == 3)
        await registry.shutdown()
    }
}
