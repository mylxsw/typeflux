import CoreGraphics
import Foundation
import Testing
@testable import Typeflux

@Suite("Screen capture service", .exclusiveUIState)
struct ScreenCaptureServiceTests {
    private struct Failure: Error {}

    private struct Capture {
        var display: CGDirectDisplayID
        var excluded: [CGWindowID]
        var size: ScreenPixelSize
    }

    /// Records what the service asked the system to capture.
    private final class Source {
        var displays: [ScreenCaptureContent.Display] = [
            .init(id: 1, frame: CGRect(x: 0, y: 0, width: 1512, height: 982), scale: 2),
            .init(id: 2, frame: CGRect(x: 1512, y: 0, width: 1920, height: 1080), scale: 1)
        ]
        var windows = [
            ScreenCaptureTestSupport.window(10, processID: 7, title: "Typeflux launcher"),
            ScreenCaptureTestSupport.window(11, processID: 300, title: "Document")
        ]
        var loads = 0
        private let captureLock = NSLock()
        private var recordedCaptures: [Capture] = []
        var captures: [Capture] { captureLock.withLock { recordedCaptures } }
        /// Returns an image of a different size, as the macOS 13 fallback does.
        var nativeOverride: ScreenPixelSize?
        var failure: Error?

        func content() -> ScreenCaptureContent {
            loads += 1
            return ScreenCaptureContent(displays: displays, windows: windows) { [self] display, excluded, size in
                // Displays are captured concurrently by the service's task group.
                captureLock.withLock {
                    recordedCaptures.append(Capture(display: display.id, excluded: excluded, size: size))
                }
                if let failure { throw failure }
                let actual = nativeOverride ?? size
                return ScreenCaptureTestSupport.image(width: actual.width, height: actual.height)
            }
        }
    }

    private func service(_ source: Source, granted: Bool = true, controls: [CGWindowID] = []) -> ScreenCaptureService {
        ScreenCaptureService(permission: FakeScreenCapturePermission(granted: granted), ownProcessID: 7,
                             captureControlWindowIDs: { controls }) {
            source.content()
        }
    }

    @Test func deniedAccessThrowsWithoutReadingTheScreen() async {
        let source = Source()
        await #expect(throws: ScreenCaptureError.permissionDenied) {
            try await service(source, granted: false).snapshot(ScreenCaptureRequest())
        }
        #expect(source.loads == 0)
    }

    @Test func capturesEveryDisplayAtNativePixelsInOrder() async throws {
        let source = Source()
        let snapshot = try await service(source).snapshot(ScreenCaptureRequest())
        #expect(snapshot.displays.map(\.id) == [1, 2])
        #expect(snapshot.displays.map(\.pixelSize) == [ScreenPixelSize(width: 3024, height: 1964),
                                                        ScreenPixelSize(width: 1920, height: 1080)])
        #expect(snapshot.displays.map(\.scale) == [2, 1])
        #expect(snapshot.displays[1].frame == CGRect(x: 1512, y: 0, width: 1920, height: 1080))
        #expect(source.captures.count == 2)
    }

    @Test func leavesOwnWindowsOutOfTheCaptureAndTheList() async throws {
        let source = Source()
        let snapshot = try await service(source).snapshot(ScreenCaptureRequest())
        #expect(snapshot.windows.map(\.id) == [11])
        #expect(snapshot.windows.first?.title == "Document")
        #expect(source.captures.allSatisfy { $0.excluded == [10] })
        let withoutWindows = try await service(source).snapshot(ScreenCaptureRequest(includesWindows: false))
        #expect(withoutWindows.windows.isEmpty)
    }

    @Test func explicitScreenshotKeepsAppPagesAndExcludesOnlyOwnCaptureControls() async throws {
        let source = Source()
        source.windows += [
            ScreenCaptureTestSupport.window(12, processID: 7, title: "Chat"),
            ScreenCaptureTestSupport.window(13, processID: 7, title: "Settings"),
            ScreenCaptureTestSupport.window(14, processID: 7, title: "Word cards"),
            ScreenCaptureTestSupport.window(15, processID: 7, title: "Notebook"),
            ScreenCaptureTestSupport.window(16, processID: 7, title: "Screenshot preview")
        ]
        // An unrelated app must remain selectable even if the provider returns its ID.
        let capturer = service(source, controls: [11, 16, 999])
        let snapshot = try await capturer.snapshot(ScreenCaptureRequest(windowExclusion: .screenshotControls))
        #expect(snapshot.windows.map(\.id) == [10, 11, 12, 13, 14, 15])
        #expect(source.captures.allSatisfy { $0.excluded == [16] })
        let withoutWindows = try await capturer.snapshot(ScreenCaptureRequest(
            includesWindows: false, windowExclusion: .screenshotControls
        ))
        #expect(withoutWindows.windows.isEmpty)
        #expect(source.captures.allSatisfy { $0.excluded == [16] })
    }

    @Test func explicitScreenshotWithoutControlsIncludesOwnWindows() async throws {
        let source = Source()
        let snapshot = try await service(source).snapshot(ScreenCaptureRequest(windowExclusion: .screenshotControls))
        #expect(snapshot.windows.map(\.id) == [10, 11])
        #expect(source.captures.allSatisfy { $0.excluded.isEmpty })
    }

    @Test func appPageCanBeSelectedByClickingItsWindow() async throws {
        let source = Source()
        let pageFrame = CGRect(x: 200, y: 100, width: 600, height: 400)
        source.windows.append(ScreenCaptureTestSupport.window(12, processID: 7, frame: pageFrame, title: "Chat"))
        let snapshot = try await service(source, controls: [10])
            .snapshot(ScreenCaptureRequest(windowExclusion: .screenshotControls))
        let display = try #require(snapshot.displays.first)
        var selection = ScreenshotSelection(displayFrame: display.frame, scale: display.scale, windows: snapshot.windows)
        let point = CGPoint(x: pageFrame.midX, y: pageFrame.midY)
        selection.pointerMoved(to: point)
        #expect(selection.hovered == pageFrame)
        _ = selection.mouseDown(at: point)
        #expect(selection.mouseUp(at: point) == .committed)
        #expect(selection.rect == pageFrame)
    }

    @Test func preferredDisplayFallsBackToTheFirstOne() async throws {
        let source = Source()
        let fitting = ScreenCaptureRequest.Resolution.fitting(maxDimension: 1600)
        let second = try await service(source)
            .snapshot(ScreenCaptureRequest(displays: .preferred(2), resolution: fitting))
        #expect(second.displays.map(\.id) == [2])
        #expect(second.displays.first?.pixelSize == ScreenPixelSize(width: 1600, height: 900))
        let missing = try await service(source)
            .snapshot(ScreenCaptureRequest(displays: .preferred(9), resolution: fitting))
        #expect(missing.displays.map(\.id) == [1])
        #expect(missing.displays.first?.pixelSize == ScreenPixelSize(width: 1512, height: 982))
        let unspecified = try await service(source).snapshot(ScreenCaptureRequest(displays: .preferred(nil)))
        #expect(unspecified.displays.map(\.id) == [1])
    }

    @Test func noDisplayIsUnavailable() async {
        let source = Source()
        source.displays = []
        await #expect(throws: ScreenCaptureError.unavailable) {
            try await service(source).snapshot(ScreenCaptureRequest(displays: .preferred(1)))
        }
        #expect(source.captures.isEmpty)
    }

    @Test func fallbackImagesAreScaledToTheRequestedSize() async throws {
        let source = Source()
        source.nativeOverride = ScreenPixelSize(width: 3024, height: 1964)
        let snapshot = try await service(source).snapshot(ScreenCaptureRequest(
            displays: .preferred(1), resolution: .fitting(maxDimension: 1000)
        ))
        #expect(snapshot.displays.first?.pixelSize == ScreenPixelSize(width: 1000, height: 649))
    }

    @Test func systemErrorsPassThrough() async {
        let source = Source()
        source.failure = Failure()
        await #expect(throws: Failure.self) { try await service(source).snapshot(ScreenCaptureRequest()) }
    }

    @Test @MainActor func cancelledEnumerationNeverStartsDisplayCapture() async throws {
        let source = Source(), collector = ShortcutLatencyEventCollector()
        var enumeration: CheckedContinuation<Void, Never>?
        let capturer = ScreenCaptureService(permission: FakeScreenCapturePermission(granted: true)) {
            await withCheckedContinuation { enumeration = $0 }
            return source.content()
        }
        let task = Task {
            try await ShortcutLatency.$eventSink.withValue(collector.sink) {
                try await ShortcutLatency.$current.withValue(diagnosticTestTrace(.screenshot)) {
                    try await capturer.snapshot(.init())
                }
            }
        }
        try await SettingsBehaviorTestSupport.wait { enumeration != nil }
        task.cancel()
        enumeration?.resume()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(source.captures.isEmpty)
        #expect(collector.stages == [.contentLoadStarted, .contentLoadFinished])
    }

    @Test @MainActor func cancelledDisplayResultIsNotResizedOrPublished() async throws {
        let collector = ShortcutLatencyEventCollector()
        var image: CheckedContinuation<CGImage, Never>?
        let capturer = ScreenCaptureService(permission: FakeScreenCapturePermission(granted: true)) {
            ScreenCaptureContent(displays: [.init(id: 1, frame: CGRect(x: 0, y: 0, width: 20, height: 10), scale: 1)],
                                 windows: []) { _, _, _ in
                await withCheckedContinuation { image = $0 }
            }
        }
        let task = Task {
            try await ShortcutLatency.$eventSink.withValue(collector.sink) {
                try await ShortcutLatency.$current.withValue(diagnosticTestTrace(.screenshot)) {
                    try await capturer.snapshot(.init())
                }
            }
        }
        try await SettingsBehaviorTestSupport.wait { image != nil }
        task.cancel()
        image?.resume(returning: ScreenCaptureTestSupport.image(width: 20, height: 10))
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(collector.stages == [.contentLoadStarted, .contentLoadFinished, .displayCaptureStarted, .displayCaptureFinished])
    }

    @Test func diagnosticsSeparateEnumerationCaptureAndResizeForEveryDisplay() async throws {
        let source = Source(), collector = ShortcutLatencyEventCollector()
        try await ShortcutLatency.$eventSink.withValue(collector.sink) {
            try await ShortcutLatency.$current.withValue(diagnosticTestTrace(.screenshot)) {
                _ = try await service(source).snapshot(.init())
            }
        }
        #expect(Array(collector.stages.prefix(2)) == [.contentLoadStarted, .contentLoadFinished])
        #expect(collector.stages.last == .captureAssembled)
        for index in 1...2 {
            let events = collector.events.filter { $0.itemIndex == index }
            #expect(events.map(\.stage) == [.displayCaptureStarted, .displayCaptureFinished, .imageResizeStarted, .imageResizeFinished])
            #expect(events.allSatisfy { $0.itemCount == 2 })
        }
    }

    @Test func precancelledCaptureDoesNotEnumerate() async {
        let source = Source()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await #expect(throws: CancellationError.self) { try await service(source).snapshot(.init()) }
        }
        await task.value
        #expect(source.loads == 0 && source.captures.isEmpty)
    }

    @Test func displaySelection() {
        let displays: [ScreenCaptureContent.Display] = [.init(id: 4, frame: .zero, scale: 1),
                                                        .init(id: 5, frame: .zero, scale: 1)]
        #expect(ScreenCaptureService.displays(displays, matching: .all).map(\.id) == [4, 5])
        #expect(ScreenCaptureService.displays(displays, matching: .preferred(5)).map(\.id) == [5])
        #expect(ScreenCaptureService.displays(displays, matching: .preferred(6)).map(\.id) == [4])
        #expect(ScreenCaptureService.displays([], matching: .preferred(nil)).isEmpty)
    }

    /// Exercises ScreenCaptureKit itself; runs only where the test host has Screen Recording access.
    @Test(.enabled(if: CGPreflightScreenCaptureAccess()))
    func capturesTheRealScreen() async throws {
        let snapshot = try await ScreenCaptureService().snapshot(ScreenCaptureRequest(
            displays: .preferred(CGMainDisplayID()), resolution: .fitting(maxDimension: 320)
        ))
        let display = try #require(snapshot.displays.first)
        #expect(max(display.image.width, display.image.height) <= 320)
        #expect(display.scale >= 1 && !display.frame.isEmpty)
        #expect(!snapshot.windows.contains { $0.processID == ProcessInfo.processInfo.processIdentifier })
    }
}
