import CoreGraphics
@testable import Typeflux
import XCTest

@MainActor
final class ScreenshotCoordinatorTests: XCTestCase {
    private final class Overlay: ScreenshotOverlayPresenting {
        private(set) var presented: [ScreenSnapshot] = []
        private(set) var fullScreenSelections = 0
        private(set) var dismissals = 0
        var onEvent: ((ScreenshotOverlayEvent) -> Void)?
        var isShowing = false

        func present(_ snapshot: ScreenSnapshot, onEvent: @escaping (ScreenshotOverlayEvent) -> Void) {
            XCTAssertFalse(isShowing, "A second overlay over the first one")
            presented.append(snapshot)
            self.onEvent = onEvent
            isShowing = true
        }

        func selectFullScreen() { fullScreenSelections += 1 }

        func dismiss() {
            dismissals += 1
            isShowing = false
            onEvent = nil
        }
    }

    private final class Guide: ScreenshotPermissionGuidePresenting {
        private(set) var shown = 0
        private(set) var dismissals = 0
        var actions: ScreenshotPermissionGuideActions?

        func show(actions: ScreenshotPermissionGuideActions) {
            shown += 1
            self.actions = actions
        }

        func dismiss() { dismissals += 1 }
    }

    private final class Toasts: ScreenshotToastPresenting {
        private(set) var shown: [ScreenshotToast] = []
        func show(_ toast: ScreenshotToast) { shown.append(toast) }
    }

    private struct SaveFailure: LocalizedError { var errorDescription: String? { "disk full" } }

    private struct Saved {
        var png: Data
        var directory: URL
        var date: Date
    }

    private final class Output: ScreenshotOutputting {

        var copySucceeds = true
        var saveFails = false
        private(set) var copied: [Data] = []
        private(set) var copiedText: [String] = []
        private(set) var saved: [Saved] = []

        func copy(_ png: Data) -> Bool {
            copied.append(png)
            return copySucceeds
        }

        func copy(text: String) { copiedText.append(text) }

        func save(_ png: Data, in directory: URL, date: Date) throws -> URL {
            if saveFails { throw SaveFailure() }
            saved.append(Saved(png: png, directory: directory, date: date))
            return directory.appendingPathComponent("shot.png")
        }
    }

    /// Blocks the capture until the test lets it finish, to look at `capturing`.
    private final class GatedCapturer: ScreenCapturing {
        var continuation: CheckedContinuation<Void, Never>?
        let snapshot: ScreenSnapshot

        init(snapshot: ScreenSnapshot) { self.snapshot = snapshot }

        func snapshot(_ request: ScreenCaptureRequest) async throws -> ScreenSnapshot {
            await withCheckedContinuation { continuation = $0 }
            return snapshot
        }
    }

    private struct EncodeFailure: Error {}

    private let overlay = Overlay()
    private let guide = Guide()
    private let toasts = Toasts()
    private let output = Output()
    private let directory = URL(fileURLWithPath: "/tmp/shots", isDirectory: true)
    private let date = Date(timeIntervalSince1970: 1_791_650_000)
    private var relaunches = 0

    /// Two displays: a 2× laptop and a 1× external display to its right.
    nonisolated private static func snapshot() -> ScreenSnapshot {
        ScreenSnapshot(displays: [
            .init(id: 1, frame: CGRect(x: 0, y: 0, width: 200, height: 100), scale: 2,
                  image: ScreenCaptureTestSupport.image(width: 400, height: 200)),
            .init(id: 2, frame: CGRect(x: 200, y: 0, width: 300, height: 150), scale: 1,
                  image: ScreenCaptureTestSupport.image(width: 300, height: 150))
        ], windows: [])
    }

    private func makeCoordinator(capturer: any ScreenCapturing = FakeScreenCapturer(.success(snapshot())),
                                 permission: FakeScreenCapturePermission = FakeScreenCapturePermission(granted: true),
                                 encode: ScreenshotCoordinator.Encoder? = nil) -> ScreenshotCoordinator {
        ScreenshotCoordinator(
            capture: capturer, permission: permission, overlay: overlay, permissionGuide: guide, toast: toasts,
            output: output, saveDirectory: { [directory] in directory }, now: { [date] in date },
            relaunch: { [weak self] in self?.relaunches += 1 },
            encode: encode ?? { image, scale in Data("\(image.width)x\(image.height)@\(Int(scale))".utf8) }
        )
    }

    private func started(_ coordinator: ScreenshotCoordinator, mode: ScreenshotMode = .region) async {
        coordinator.start(mode: mode)
        await coordinator.pendingTask?.value
    }

    // MARK: Starting

    func testStartFreezesAllDisplaysAndShowsOneOverlay() async {
        let capturer = FakeScreenCapturer(.success(Self.snapshot()))
        let sut = makeCoordinator(capturer: capturer)

        await started(sut)

        XCTAssertEqual(sut.state, .selecting)
        XCTAssertEqual(capturer.requests, [ScreenCaptureRequest()])
        XCTAssertEqual(overlay.presented.count, 1)
        XCTAssertEqual(sut.snapshot?.displays.count, 2)
        XCTAssertEqual(guide.dismissals, 1, "A guide left open from before closes")
    }

    func testFullScreenModeSelectsTheDisplayAtOnce() async {
        let sut = makeCoordinator()

        await started(sut, mode: .fullScreen)

        XCTAssertEqual(sut.state, .editing)
        XCTAssertEqual(overlay.fullScreenSelections, 1)
    }

    func testStartingAgainWhileFramingSelectsTheWholeDisplay() async {
        let sut = makeCoordinator()
        await started(sut)

        sut.start()

        XCTAssertEqual(sut.state, .editing)
        XCTAssertEqual(overlay.fullScreenSelections, 1)
        XCTAssertEqual(overlay.presented.count, 1, "Never a second overlay")

        sut.start(mode: .fullScreen)
        XCTAssertEqual(overlay.fullScreenSelections, 2)
    }

    func testStartingAgainWhileCapturingIsIgnoredWithANotice() async throws {
        let capturer = GatedCapturer(snapshot: Self.snapshot())
        let sut = makeCoordinator(capturer: capturer)
        sut.start()
        let task = try XCTUnwrap(sut.pendingTask)
        while capturer.continuation == nil { await Task.yield() }

        XCTAssertEqual(sut.state, .capturing)
        sut.start()
        XCTAssertEqual(toasts.shown, [.busy])

        capturer.continuation?.resume()
        await task.value
        XCTAssertEqual(sut.state, .selecting)
        XCTAssertEqual(overlay.presented.count, 1)
    }

    func testCancellingDuringCaptureDropsTheLateResult() async throws {
        let capturer = GatedCapturer(snapshot: Self.snapshot())
        let sut = makeCoordinator(capturer: capturer)
        sut.start()
        let task = try XCTUnwrap(sut.pendingTask)
        while capturer.continuation == nil { await Task.yield() }

        sut.cancel()
        capturer.continuation?.resume()
        await task.value

        XCTAssertEqual(sut.state, .idle)
        XCTAssertTrue(overlay.presented.isEmpty)
        XCTAssertNil(sut.snapshot)
    }

    // MARK: Permission

    func testMissingPermissionAsksOnceAndShowsTheGuide() async {
        let permission = FakeScreenCapturePermission(granted: false)
        let capturer = FakeScreenCapturer(.success(Self.snapshot()))
        let sut = makeCoordinator(capturer: capturer, permission: permission)

        sut.start()
        sut.start()

        XCTAssertEqual(sut.state, .idle)
        XCTAssertTrue(capturer.requests.isEmpty)
        XCTAssertEqual(guide.shown, 2)
        // `requestOnce` itself keeps the system prompt to the first time.
        XCTAssertEqual(permission.onceRequests, 2)
        XCTAssertEqual(permission.requests, 0, "Never the prompting request()")
        XCTAssertTrue(overlay.presented.isEmpty)
    }

    func testGuideButtons() async throws {
        let permission = FakeScreenCapturePermission(granted: false)
        let sut = makeCoordinator(permission: permission)
        sut.start(mode: .fullScreen)
        let actions = try XCTUnwrap(guide.actions)

        actions.openSettings()
        XCTAssertEqual(permission.settingsOpened, 1)

        XCTAssertFalse(actions.recheck(), "Still not granted")
        XCTAssertEqual(sut.state, .idle)

        actions.restart()
        XCTAssertEqual(relaunches, 1)

        let dismissals = guide.dismissals
        actions.later()
        XCTAssertEqual(guide.dismissals, dismissals + 1)

        permission.granted = true
        XCTAssertTrue(actions.recheck())
        await sut.pendingTask?.value
        XCTAssertEqual(sut.state, .editing, "Starts in the mode first asked for")
    }

    func testRecheckWithoutGrantDoesNothing() {
        let sut = makeCoordinator(permission: FakeScreenCapturePermission(granted: false))

        XCTAssertFalse(sut.recheckPermission())
        XCTAssertEqual(sut.state, .idle)
    }

    func testPermissionRevokedDuringCaptureShowsTheGuide() async {
        let sut = makeCoordinator(capturer: FakeScreenCapturer(.failure(ScreenCaptureError.permissionDenied)))

        await started(sut)

        XCTAssertEqual(sut.state, .idle)
        XCTAssertEqual(guide.shown, 1)
        XCTAssertTrue(toasts.shown.isEmpty)
    }

    func testCaptureFailureShowsANoticeAndReturnsToIdle() async {
        let sut = makeCoordinator(capturer: FakeScreenCapturer(.failure(ScreenCaptureError.unavailable)))

        await started(sut)

        XCTAssertEqual(sut.state, .idle)
        XCTAssertEqual(toasts.shown, [.failed])
        XCTAssertGreaterThanOrEqual(overlay.dismissals, 1)
    }

    // MARK: Overlay events

    func testCommittingMovesToEditingOnce() async {
        let sut = makeCoordinator()
        await started(sut)

        overlay.onEvent?(.committed)
        XCTAssertEqual(sut.state, .editing)
        overlay.onEvent?(.committed)
        XCTAssertEqual(sut.state, .editing)
    }

    func testEscapeReleasesEverything() async {
        let sut = makeCoordinator()
        await started(sut)

        overlay.onEvent?(.cancelled)

        XCTAssertEqual(sut.state, .idle)
        XCTAssertNil(sut.snapshot)
        XCTAssertFalse(overlay.isShowing)
    }

    func testPickedColorIsCopiedAsText() async {
        let sut = makeCoordinator()
        sut.handle(.colorPicked("#000000"))
        XCTAssertTrue(output.copiedText.isEmpty, "No session, nothing to pick")

        await started(sut)
        overlay.onEvent?(.colorPicked("#2F8CFF"))

        XCTAssertEqual(output.copiedText, ["#2F8CFF"])
        XCTAssertEqual(toasts.shown, [.colorCopied("#2F8CFF")])
        XCTAssertEqual(sut.state, .selecting)
    }

    // MARK: Output

    func testCopyExportsNativePixelsOfTheChosenDisplay() async {
        let sut = makeCoordinator()
        await started(sut)
        overlay.onEvent?(.committed)

        // 50 × 25 pt on the 2× display: 100 × 50 px.
        overlay.onEvent?(.finish(.copy, displayID: 1, rect: CGRect(x: 10, y: 10, width: 50, height: 25)))
        XCTAssertEqual(sut.state, .finishing)
        XCTAssertFalse(overlay.isShowing, "The overlay closes before encoding")
        XCTAssertNil(sut.snapshot)
        await sut.pendingTask?.value

        XCTAssertEqual(output.copied, [Data("100x50@2".utf8)])
        XCTAssertEqual(toasts.shown, [.copied])
        XCTAssertEqual(sut.state, .idle)
    }

    func testCopyOnTheOneTimesDisplayKeepsItsPixels() async {
        let sut = makeCoordinator()
        await started(sut)

        overlay.onEvent?(.finish(.copy, displayID: 2, rect: CGRect(x: 250, y: 20, width: 120, height: 80)))
        await sut.pendingTask?.value

        XCTAssertEqual(output.copied, [Data("120x80@1".utf8)])
    }

    func testSaveWritesToTheConfiguredFolder() async throws {
        let sut = makeCoordinator()
        await started(sut)

        overlay.onEvent?(.finish(.save, displayID: 1, rect: CGRect(x: 0, y: 0, width: 200, height: 100)))
        await sut.pendingTask?.value

        let saved = try XCTUnwrap(output.saved.first)
        XCTAssertEqual(saved.png, Data("400x200@2".utf8))
        XCTAssertEqual(saved.directory, directory)
        XCTAssertEqual(saved.date, date)
        XCTAssertEqual(toasts.shown, [.saved(directory.appendingPathComponent("shot.png"))])
        XCTAssertTrue(output.copied.isEmpty)
    }

    func testFailedSaveFallsBackToCopy() async {
        output.saveFails = true
        let sut = makeCoordinator()
        await started(sut)

        overlay.onEvent?(.finish(.save, displayID: 1, rect: CGRect(x: 0, y: 0, width: 20, height: 20)))
        await sut.pendingTask?.value

        XCTAssertEqual(output.copied.count, 1)
        XCTAssertEqual(toasts.shown, [.savedAsCopy(reason: "disk full")])
        XCTAssertEqual(sut.state, .idle)
    }

    func testFailedSaveAndCopyReportsFailure() async {
        output.saveFails = true
        output.copySucceeds = false
        let sut = makeCoordinator()
        await started(sut)

        overlay.onEvent?(.finish(.save, displayID: 1, rect: CGRect(x: 0, y: 0, width: 20, height: 20)))
        await sut.pendingTask?.value

        XCTAssertEqual(toasts.shown, [.failed])
    }

    func testFailedCopyReportsFailure() async {
        output.copySucceeds = false
        let sut = makeCoordinator()
        await started(sut)

        overlay.onEvent?(.finish(.copy, displayID: 1, rect: CGRect(x: 0, y: 0, width: 20, height: 20)))
        await sut.pendingTask?.value

        XCTAssertEqual(toasts.shown, [.failed])
    }

    func testEncodingFailureReportsFailure() async {
        let sut = makeCoordinator(encode: { _, _ in throw EncodeFailure() })
        await started(sut)

        overlay.onEvent?(.finish(.copy, displayID: 1, rect: CGRect(x: 0, y: 0, width: 20, height: 20)))
        await sut.pendingTask?.value

        XCTAssertTrue(output.copied.isEmpty)
        XCTAssertEqual(toasts.shown, [.failed])
        XCTAssertEqual(sut.state, .idle)
    }

    func testRegionOffItsDisplayFailsCleanly() async {
        let sut = makeCoordinator()
        await started(sut)

        overlay.onEvent?(.finish(.copy, displayID: 1, rect: CGRect(x: 300, y: 0, width: 20, height: 20)))

        XCTAssertEqual(sut.state, .idle)
        XCTAssertEqual(toasts.shown, [.failed])
        XCTAssertFalse(overlay.isShowing)
    }

    func testFinishForAnUnknownDisplayOrOutsideASessionIsIgnored() async {
        let sut = makeCoordinator()
        sut.handle(.finish(.copy, displayID: 1, rect: CGRect(x: 0, y: 0, width: 10, height: 10)))
        XCTAssertEqual(sut.state, .idle)

        await started(sut)
        overlay.onEvent?(.finish(.copy, displayID: 99, rect: CGRect(x: 0, y: 0, width: 10, height: 10)))
        XCTAssertEqual(sut.state, .selecting)
        XCTAssertTrue(output.copied.isEmpty)
    }

    func testStartingWhileFinishingIsIgnoredAndANewShotFollows() async {
        let sut = makeCoordinator()
        await started(sut)
        overlay.onEvent?(.finish(.copy, displayID: 1, rect: CGRect(x: 0, y: 0, width: 20, height: 20)))
        let delivery = sut.pendingTask

        sut.start()
        XCTAssertEqual(toasts.shown, [.busy])
        await delivery?.value
        XCTAssertEqual(sut.state, .idle)

        await started(sut)
        XCTAssertEqual(sut.state, .selecting)
        XCTAssertEqual(overlay.presented.count, 2)
    }
}
