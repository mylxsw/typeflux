import CoreGraphics
import Foundation
import Testing
import TypefluxMediaProtocol
@testable import Typeflux

private final class TextPreparationState: @unchecked Sendable {
    private let lock = NSLock()
    private var runs = 0, preparations = 0
    var counts: [Int] { lock.withLock { [runs, preparations] } }
    func run() { lock.withLock { runs += 1 } }
    func prepare() { lock.withLock { preparations += 1 } }
}
private final class TextPreparationGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var held = true
    func wait() {
        condition.lock(); defer { condition.unlock() }
        while held { condition.wait() }
    }
    func release() { condition.withLock { held = false; condition.broadcast() } }
}

@Suite("Text recognition preparation authority", .serialized, .exclusiveUIState)
@MainActor struct TextPreparationAuthorityTests {
    private func image() throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: 8, height: 4, bitsPerComponent: 8,
            bytesPerRow: 32, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        return try #require(context.makeImage())
    }
    private func file(_ root: URL) throws -> URL {
        let url = root.appendingPathComponent("private.bytes"); try Data([1, 2, 3]).write(to: url); return url
    }
    private func worker(_ state: TextPreparationState) -> MediaWorker {
        MediaWorker(executable: URL(fileURLWithPath: "/usr/bin/true"), requiresLifecycle: true, run: { p, _ in
            state.run()
            let request = try JSONDecoder().decode(MediaRequest.self, from: p.stdin!)
            var response = MediaResponse(id: request.id)
            let box = CGRect(x: 0.1, y: 0.2, width: 0.6, height: 0.1)
            if request.operation == .textGeometry { response.geometry = .init(boxes: [box]) }
            else {
                response.recognition = .init(lines: [.init(text: "a@example.com", confidence: 0.9, box: box,
                    regions: [.init(kind: .email, range: .init(location: 0, length: 13), box: box)])])
            }
            return .init(termination: .exited(0), exitCode: 0,
                stdout: String(decoding: try JSONEncoder().encode(response), as: UTF8.self), stderr: "", outputTruncated: false)
        })
    }
    private func wait(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(condition())
    }

    @Test func preReadyAndPrecancelledCallsDoNotPrepareSources() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let url = try file(root), image = try image(), state = TextPreparationState(), worker = self.worker(state)
        let reader = VisionImageTextRecognizer(worker: worker, readRevision: { url in
            state.prepare(); return try .init(url)
        }, readPixels: { image, shape in state.prepare(); return try VisionImageTextRecognizer.pixels(image, shape: shape) })
        do { _ = try await reader.recognizeText(in: .url(url)); Issue.record("Pre-ready file") } catch {}
        do { _ = try await reader.recognizeText(in: .image(image)); Issue.record("Pre-ready pixels") } catch {}
        do { _ = try await reader.textGeometry(in: image); Issue.record("Pre-ready geometry") } catch {}
        #expect(state.counts == [0, 0])
        let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .textRecognition)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.textRecognition)
        let pending = Task { withUnsafeCurrentTask { $0?.cancel() }; return try await reader.recognizeText(in: .url(url)) }
        do { _ = try await pending.value; Issue.record("Pre-canceled file") } catch {}
        #expect(state.counts == [0, 0])
        await registry.shutdown()
    }

    @Test(arguments: ["file", "pixels", "geometry"])
    func heldPreparationCannotAdoptRecoveredGeneration(_ kind: String) async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let url = try file(root), image = try image(), state = TextPreparationState(), worker = self.worker(state)
        let gate = TextPreparationGate(); defer { gate.release() }
        let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .textRecognition)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.textRecognition)
        let reader = VisionImageTextRecognizer(worker: worker, readRevision: { url in
            let value = try ClipboardImageRevision(url); state.prepare(); gate.wait(); return value
        }, readPixels: { image, shape in
            let value = try VisionImageTextRecognizer.pixels(image, shape: shape); state.prepare(); gate.wait(); return value
        })
        let pending = Task {
            if kind == "geometry" { _ = try await reader.textGeometry(in: image) }
            else { _ = try await reader.recognizeText(in: kind == "file" ? .url(url) : .image(image)) }
        }
        await wait { state.counts[1] == 1 }
        await registry.disable(.textRecognition); try await registry.start(.textRecognition)
        #expect(state.counts == [0, 1] && worker.activeCount == 0)
        gate.release()
        do { try await pending.value; Issue.record("Old preparation adopted recovered lane") } catch {}
        #expect(state.counts == [0, 1])
        if kind == "geometry" { #expect(try await reader.textGeometry(in: image).boxes.count == 1) }
        else { #expect(try await reader.recognizeText(in: kind == "file" ? .url(url) : .image(image)).string == "a@example.com") }
        #expect(state.counts == [1, 2])
        await registry.shutdown()
    }

    @Test(arguments: [false, true])
    func cancelledPreparationRetainsBothAdmissionsUntilReturn(_ rawPixels: Bool) async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let url = try file(root), image = try image(), state = TextPreparationState(), worker = self.worker(state)
        let gate = TextPreparationGate(); defer { gate.release() }
        let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .textRecognition)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.textRecognition)
        let reader = VisionImageTextRecognizer(worker: worker, readRevision: { url in
            let value = try ClipboardImageRevision(url); state.prepare(); gate.wait(); return value
        }, readPixels: { image, shape in
            let value = try VisionImageTextRecognizer.pixels(image, shape: shape); state.prepare(); gate.wait(); return value
        })
        let source = rawPixels ? ImageTextSource.image(image) : .url(url)
        let a = Task { try await reader.recognizeText(in: source) }, b = Task { try await reader.recognizeText(in: source) }
        await wait { state.counts[1] == 2 }; a.cancel(); b.cancel()
        do { _ = try await reader.recognizeText(in: source); Issue.record("Freed occupied preparation") } catch {}
        #expect(state.counts == [0, 2])
        gate.release(); _ = await a.result; _ = await b.result
        #expect(state.counts == [0, 2])
        #expect(try await reader.recognizeText(in: source).string == "a@example.com")
        await registry.shutdown()
    }

    @Test func freshPrivatePixelsPreserveExactTextAndGeometryContracts() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let state = TextPreparationState(), worker = self.worker(state), image = try image()
        let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .textRecognition)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.textRecognition)
        let reader = VisionImageTextRecognizer(worker: worker)
        let result = try await reader.recognizeText(in: .image(image)), line = try #require(result.lines.first)
        #expect(line.locate?(.init(location: 0, length: 13)) == line.boundingBox)
        #expect(line.locate?(.init(location: 0, length: 1)) == nil)
        #expect(ScreenshotSensitiveInfoDetector.findings(in: result).first?.text == "a@example.com")
        #expect(try await reader.textGeometry(in: image).boxes == [line.boundingBox])
        #expect(state.counts[0] == 2 && worker.activeCount == 0)
        await registry.shutdown()
    }

    @Test func failedPreparationDoesNotSpendNativeHealthOrRetainAdmission() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let state = TextPreparationState(), worker = self.worker(state), image = try image()
        let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .textRecognition)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.textRecognition)
        let failing = VisionImageTextRecognizer(worker: worker, readPixels: { _, _ in
            state.prepare(); throw MediaFailure.unreadable
        })
        for _ in 0..<3 {
            do { _ = try await failing.recognizeText(in: .image(image)); Issue.record("Preparation failure accepted") } catch {}
        }
        #expect(state.counts == [0, 3] && module.module.health.current?.state == .ready)
        #expect(try await VisionImageTextRecognizer(worker: worker).recognizeText(in: .image(image)).string == "a@example.com")
        await registry.shutdown()
    }
}
