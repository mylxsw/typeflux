import AppKit
import Foundation
import Testing
@testable import Typeflux

@Suite("Isolated clipboard capture", .serialized, .exclusiveUIState)
@MainActor
struct ClipboardCaptureWorkerTests {
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Double = 0
        func now() -> Double {
            lock.withLock { value }
        }

        func advance() {
            lock.withLock { value += 301 }
        }
    }

    private func capture(_ worker: ClipboardCaptureWorker, count: Int = 1, plain: Bool = false,
                         cancelled: @escaping @Sendable () -> Bool = { false }) async throws -> ClipboardCapture? {
        try await Task.detached { try worker.capture(changeCount: count, plainTextOnly: plain, cancelled: cancelled) }
            .value
    }

    @Test func `real child reads text and images and rejects superseded copies`() async throws {
        let name = NSPasteboard.Name("typeflux-worker-test-" + UUID().uuidString)
        let board = NSPasteboard(name: name)
        defer { board.releaseGlobally() }
        let worker = ClipboardCaptureWorker(arguments: ["clipboard-capture-worker", name.rawValue], timeout: 15)
        board.clearContents()
        board.setString("isolated text", forType: .string)
        #expect(try await capture(worker, count: board.changeCount) == .text("isolated text"))
        #expect(try await capture(worker, count: board.changeCount - 1) == nil)
        board.clearContents()
        let image = ClipboardTestSupport.imageData(width: 5, height: 3)
        board.setData(image, forType: .png)
        #expect(try await capture(worker, count: board.changeCount) == .image(
            png: image,
            pixelWidth: 5,
            pixelHeight: 3
        ))
        #expect(try await capture(worker, count: board.changeCount, plain: true) == nil)
        board.clearContents()
        let item = NSPasteboardItem()
        item.setString("private", forType: .string)
        item.setData(Data(), forType: .init("org.nspasteboard.ConcealedType"))
        board.writeObjects([item])
        #expect(try await capture(worker, count: board.changeCount) == nil)
    }

    @Test func `crashing child is isolated and the next change recovers without replaying`() async throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: marker) }
        let clock = Clock()
        let response = try String(
            decoding: JSONEncoder().encode(ClipboardWorkerResponse(changeCount: 2, capture: .text("recovered"))),
            as: UTF8.self
        )
        let worker = ClipboardCaptureWorker(executable: URL(fileURLWithPath: "/bin/sh"), arguments: [
            "-c", "if [ ! -f \"$1\" ]; then touch \"$1\"; kill -KILL $$; fi; printf '%s' \"$2\"", "fixture",
            marker.path,
            response
        ], uptime: { clock.now() })
        await #expect(throws: (any Error).self) { _ = try await capture(worker) }
        await #expect(throws: (any Error).self) { _ = try await capture(worker, count: 2) }
        clock.advance()
        #expect(try await capture(worker, count: 2) == .text("recovered"))
    }

    @Test func `hung child and cancelled capture return within budget`() async throws {
        let worker = ClipboardCaptureWorker(executable: URL(fileURLWithPath: "/bin/sh"),
                                            arguments: ["-c", "trap '' TERM; while :; do :; done"], timeout: 0.1)
        let started = ContinuousClock.now
        await #expect(throws: (any Error).self) { _ = try await capture(worker) }
        #expect(started.duration(to: .now) < .seconds(2))
        let cancelled = ClipboardCaptureWorker(executable: URL(fileURLWithPath: "/bin/echo"))
        await #expect(throws: CancellationError.self) { _ = try await capture(cancelled, cancelled: { true }) }
    }

    @Test func `malformed wrong version and wrong generation responses are rejected`() async throws {
        let valid = try JSONEncoder().encode(ClipboardWorkerResponse(changeCount: 2, capture: .text("wrong copy")))
        var wrongVersion = ClipboardWorkerResponse(changeCount: 1)
        wrongVersion.version = 99
        for data in try [Data("not json".utf8), valid, JSONEncoder().encode(wrongVersion)] {
            let worker = ClipboardCaptureWorker(executable: URL(fileURLWithPath: "/bin/sh"),
                                                arguments: [
                                                    "-c",
                                                    "printf '%s' \"$1\"",
                                                    "fixture",
                                                    String(decoding: data, as: UTF8.self)
                                                ])
            await #expect(throws: (any Error).self) { _ = try await capture(worker) }
        }
        #expect(try !ClipboardWorkerResponse(
            changeCount: 1,
            capture: .files([#require(URL(string: "https://example.com"))])
        ).isValid)
        #expect(ClipboardWorkerResponse(changeCount: 1, capture: .files([URL(fileURLWithPath: "/test")])).isValid)
        #expect(!ClipboardWorkerResponse(
            changeCount: 1,
            capture: .image(png: Data(), pixelWidth: Int.max, pixelHeight: 1)
        ).isValid)
        #expect(ClipboardCaptureWorkerCommand.run(arguments: []) == 2)
        #expect(ClipboardCaptureWorkerCommand.run(arguments: ["test", "invalid", "all"]) == 2)
        #expect(ClipboardCaptureWorkerCommand.run(arguments: ["test", "1", "invalid"]) == 2)
    }

    private final class ChangingPasteboard: PasteboardReading {
        var changeCount = 1
        func readContents() -> PasteboardContents {
            changeCount = 2
            return .init(string: "stale")
        }
    }

    @Test func `change during reading discards the capture`() {
        #expect(ClipboardCaptureWorkerCommand.capture(
            pasteboard: ChangingPasteboard(),
            changeCount: 1,
            plainTextOnly: false
        ).capture == nil)
    }
}
