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

        /// The real overlay commits the region it selects.
        var commitsOnFullScreen = false
        func selectFullScreen() {
            fullScreenSelections += 1
            if commitsOnFullScreen { onEvent?(.committed) }
        }

        private(set) var scrollRequests = 0
        func startScrollCapture() { scrollRequests += 1 }

        /// Finishes as the real overlay would: the region on the 2× display.
        private(set) var finishes: [ScreenshotOutputAction] = []
        func finish(_ action: ScreenshotOutputAction) {
            finishes.append(action)
            onEvent?(.finish(action, displayID: 1, rect: CGRect(x: 10, y: 20, width: 50, height: 30)))
        }

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
        func clear() { shown = [] }
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

    private final class LongEditor: ScreenshotLongImagePresenting {
        private(set) var presented: [(display: ScreenSnapshot.Display, screen: CGRect)] = []
        private(set) var dismissals = 0
        var onEvent: ((ScreenshotOverlayEvent) -> Void)?

        func present(_ image: ScreenSnapshot.Display, on screen: CGRect,
                     onEvent: @escaping (ScreenshotOverlayEvent) -> Void) {
            presented.append((image, screen))
            self.onEvent = onEvent
        }

        func dismiss() {
            dismissals += 1
            onEvent = nil
        }
    }

    private final class ScrollCapture: ScrollCapturing {
        let region: ScrollCaptureRegion
        var onFinish: ((ScrollCaptureResult) -> Void)?
        private(set) var cancels = 0

        init(region: ScrollCaptureRegion) { self.region = region }

        func start(onFinish: @escaping (ScrollCaptureResult) -> Void) { self.onFinish = onFinish }

        func cancel() {
            cancels += 1
            onFinish?(.cancelled)
        }
    }

    private final class FollowUps: ScreenshotFollowUpHandling {
        private(set) var handled: [(followUp: ScreenshotFollowUp, image: ScreenshotFollowUpImage)] = []
        func handle(_ followUp: ScreenshotFollowUp, image: ScreenshotFollowUpImage) {
            handled.append((followUp, image))
        }
    }

    private let followUps = FollowUps()
    private let longEditor = LongEditor()
    private var scrollCaptures: [ScrollCapture] = []

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
                                 encode: ScreenshotCoordinator.Encoder? = nil,
                                 render: ScreenshotCoordinator.Renderer? = nil) -> ScreenshotCoordinator {
        ScreenshotCoordinator(
            capture: capturer, permission: permission, overlay: overlay, permissionGuide: guide, toast: toasts,
            output: output, saveDirectory: { [directory] in directory }, now: { [date] in date },
            relaunch: { [weak self] in self?.relaunches += 1 },
            encode: encode ?? { image, scale in Data("\(image.width)x\(image.height)@\(Int(scale))".utf8) },
            render: render ?? { try ScreenshotRenderer.render($0, crop: $1, annotations: $2) },
            longImageEditor: longEditor,
            makeScrollCapture: { [unowned self] region in
                let capture = ScrollCapture(region: region)
                scrollCaptures.append(capture)
                return capture
            }
        )
    }

    private func started(_ coordinator: ScreenshotCoordinator, mode: ScreenshotMode = .region) async {
        coordinator.start(mode: mode)
        await coordinator.pendingTask?.value
    }

    func testRecordingModesDispatchWithoutFreezingDisplays() {
        let capturer = FakeScreenCapturer(.success(Self.snapshot()))
        let sut = makeCoordinator(capturer: capturer)
        var formats: [ScreenRecordingFormat] = []
        sut.onRecordingRequested = { format, target in
            formats.append(format)
            XCTAssertNil(target)
        }
        sut.start(mode: .recording)
        sut.start(mode: .gif)
        XCTAssertEqual(formats, [.mp4, .gif])
        XCTAssertTrue(capturer.requests.isEmpty)
        XCTAssertEqual(sut.state, .idle)
        sut.isRecordingActive = { true }
        sut.start(mode: .region)
        sut.start(mode: .recording)
        XCTAssertEqual(formats.count, 2)
        XCTAssertEqual(toasts.shown.last, .busy)
    }

    func testUnsavedRecordingAllowsScreenshotAndAnotherRecordingFromScreenshotEntry() async {
        let fixture = ScreenRecordingSessionControllerTests.Fixture()
        let first = await fixture.record()
        let sut = makeCoordinator()
        sut.isRecordingActive = { fixture.controller.isCaptureActive }
        sut.onRecordingRequested = { format, region in fixture.controller.show(format: format, region: region) }
        fixture.controller.isOtherCaptureActive = { sut.state != .idle }
        await started(sut)
        XCTAssertTrue(overlay.isShowing)
        XCTAssertTrue(first.window.window?.isVisible == true)
        XCTAssertFalse(toasts.shown.contains(.busy))
        sut.handle(.cancelled)
        sut.start(mode: .recording)
        XCTAssertEqual(fixture.controller.sessions.count, 2)
        XCTAssertEqual(fixture.controller.sessions.last?.model.state, .setup)
        XCTAssertEqual(first.model.state, .preview)
        await fixture.clean()
    }

    func testRecordingSelectedRegionHandsOffWithoutRendering() async {
        let sut = makeCoordinator(render: { _, _, _ in
            XCTFail("A live recording must not render static annotations")
            throw ScreenCaptureError.unavailable
        })
        var target: ScreenRecordingTarget?
        sut.onRecordingRequested = { _, region in target = region }
        await started(sut)
        let rect = CGRect(x: 10, y: 20, width: 50, height: 30)
        sut.handle(.finish(.record, displayID: 1, rect: rect))
        XCTAssertEqual(target, .region(displayID: 1, rect: rect))
        XCTAssertEqual(sut.state, .idle)
        XCTAssertFalse(overlay.isShowing)
        XCTAssertTrue(output.copiedText.isEmpty)
    }

    // MARK: Starting

    func testStartFreezesAllDisplaysAndShowsOneOverlay() async {
        let capturer = FakeScreenCapturer(.success(Self.snapshot()))
        let sut = makeCoordinator(capturer: capturer)

        await started(sut)

        XCTAssertEqual(sut.state, .selecting)
        XCTAssertEqual(capturer.requests, [ScreenCaptureRequest(windowExclusion: .screenshotControls)])
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

    func testBeautifiedCopyAndSaveUseTheSameRetinaComposition() async throws {
        let sut = makeCoordinator()
        await started(sut)
        let beauty = ScreenshotBeautification(isEnabled: true, background: .mint, padding: 10, cornerRadius: 8, shadow: 0)
        overlay.onEvent?(.finish(.copyAndSave, displayID: 1, rect: CGRect(x: 10, y: 20, width: 50, height: 30),
                                 beautification: beauty))
        await sut.pendingTask?.value
        XCTAssertEqual(output.copied, [Data("140x100@2".utf8)])
        XCTAssertEqual(try XCTUnwrap(output.saved.first).png, output.copied.first)
        XCTAssertEqual(sut.state, .idle)
    }

    func testBeautifiedFollowUpReceivesTheRedactedImage() async throws {
        let sut = makeCoordinator()
        sut.followUpHandler = followUps
        await started(sut)
        let region = CGRect(x: 10, y: 20, width: 50, height: 30)
        let cover = ScreenshotAnnotation(kind: .mosaic(ScreenshotMosaic(shape: .rect(region), effect: .solid)),
                                         style: ScreenshotAnnotationStyle(color: .white))
        let beauty = ScreenshotBeautification(isEnabled: true, background: .charcoal, padding: 10,
                                              cornerRadius: 8, shadow: 0)
        overlay.onEvent?(.finish(.followUp(.askAI), displayID: 1, rect: region, annotations: [cover],
                                 beautification: beauty))
        let handed = try XCTUnwrap(followUps.handled.first?.image)
        XCTAssertEqual(handed.pixelSize, CGSize(width: 140, height: 100))
        XCTAssertEqual(ScreenshotMagnifier.color(of: handed.image, at: CGPoint(x: 70, y: 50))?.hex, "#FFFFFF")
        XCTAssertTrue(output.copied.isEmpty)
        XCTAssertEqual(sut.state, .idle)
    }

    func testBeautifiedPinFitsTheExpandedImageWithoutDistortion() async throws {
        let sut = makeCoordinator()
        defer { sut.pins.closeAll() }
        await started(sut)
        let beauty = ScreenshotBeautification(isEnabled: true, padding: 10)
        overlay.onEvent?(.finish(.pin, displayID: 1, rect: CGRect(x: 10, y: 20, width: 50, height: 30),
                                 beautification: beauty))
        let pins = try XCTUnwrap(sut.pins as? ScreenshotPinController)
        let panel = try XCTUnwrap(pins.panels.first)
        XCTAssertEqual(panel.frame.size, CGSize(width: 70, height: 50))
        XCTAssertEqual(pins.views.first?.imageSize, CGSize(width: 70, height: 50))
        XCTAssertEqual(sut.state, .idle)
    }

    func testLongImageExportsWithBeautification() async throws {
        let sut = await scrolling()
        scrollCaptures[0].onFinish?(.finished(ScreenCaptureTestSupport.image(width: 200, height: 900), .reachedEnd))
        let display = try XCTUnwrap(longEditor.presented.first?.display)
        let beauty = ScreenshotBeautification(isEnabled: true, padding: 10)
        longEditor.onEvent?(.finish(.copy, displayID: 1, rect: display.frame, beautification: beauty))
        await sut.pendingTask?.value
        XCTAssertEqual(output.copied, [Data("240x940@2".utf8)])
        XCTAssertEqual(sut.state, .idle)
    }

    func testCopyDeliversTheImageWithItsMosaicsApplied() async {
        // The encoder reports the center pixel, so the test sees what would reach the clipboard.
        let sut = makeCoordinator(encode: { image, _ in
            Data((ScreenshotMagnifier.color(of: image, at: CGPoint(x: image.width / 2, y: image.height / 2))?.hex
                    ?? "none").utf8)
        })
        await started(sut)
        let region = CGRect(x: 10, y: 10, width: 50, height: 25)
        let cover = ScreenshotAnnotation(kind: .mosaic(ScreenshotMosaic(shape: .rect(region), effect: .solid)),
                                         style: ScreenshotAnnotationStyle(color: .white))

        overlay.onEvent?(.finish(.copy, displayID: 1, rect: region, annotations: [cover]))
        await sut.pendingTask?.value

        XCTAssertEqual(output.copied, [Data("#FFFFFF".utf8)], "Not the gray screenshot under the mosaic")
        XCTAssertEqual(toasts.shown, [.copied])
    }

    func testRenderFailureNeverFallsBackToTheUnmaskedImage() async {
        var rendered: [[ScreenshotAnnotation]] = []
        let sut = makeCoordinator(render: { _, _, annotations in
            rendered.append(annotations)
            throw ScreenshotExportError.encodingFailed
        })
        await started(sut)
        let mark = ScreenshotAnnotation(kind: .counter(center: CGPoint(x: 20, y: 20)))

        overlay.onEvent?(.finish(.save, displayID: 1, rect: CGRect(x: 0, y: 0, width: 50, height: 50),
                                 annotations: [mark]))

        XCTAssertEqual(rendered, [[mark]])
        XCTAssertTrue(output.copied.isEmpty)
        XCTAssertTrue(output.saved.isEmpty)
        XCTAssertEqual(toasts.shown, [.failed])
        XCTAssertEqual(sut.state, .idle)
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

    // MARK: Scrolling capture

    /// The region on the 2× display, then S: the overlay hands it to a scrolling capture.
    private func scrolling() async -> ScreenshotCoordinator {
        let sut = makeCoordinator()
        await started(sut)
        overlay.onEvent?(.committed)
        overlay.onEvent?(.scroll(displayID: 1, rect: CGRect(x: 10, y: 20, width: 100, height: 60)))
        return sut
    }

    func testScrollingCaptureReplacesTheFrozenOverlay() async throws {
        let sut = await scrolling()

        XCTAssertEqual(sut.state, .scrolling)
        XCTAssertFalse(overlay.isShowing)
        XCTAssertNil(sut.snapshot, "The frozen displays are let go")
        let capture = try XCTUnwrap(scrollCaptures.first)
        XCTAssertEqual(capture.region, ScrollCaptureRegion(displayID: 1, displayFrame: CGRect(x: 0, y: 0, width: 200, height: 100),
                                                           scale: 2, rect: CGRect(x: 10, y: 20, width: 100, height: 60)))
        XCTAssertNotNil(capture.onFinish)

        sut.start()
        XCTAssertEqual(toasts.shown, [.busy])
        XCTAssertEqual(scrollCaptures.count, 1)
    }

    func testTheLongImageOpensInItsEditorAndIsDeliveredRendered() async throws {
        let sut = await scrolling()
        let long = ScreenCaptureTestSupport.image(width: 200, height: 900)

        scrollCaptures[0].onFinish?(.finished(long, .reachedEnd))

        XCTAssertEqual(sut.state, .editingLongImage)
        XCTAssertNil(sut.scrollCapture)
        XCTAssertTrue(toasts.shown.isEmpty)
        let presented = try XCTUnwrap(longEditor.presented.first)
        XCTAssertEqual(presented.screen, CGRect(x: 0, y: 0, width: 200, height: 100))
        XCTAssertEqual(presented.display.frame, CGRect(x: 0, y: 0, width: 100, height: 450), "Points at 2×")
        XCTAssertEqual(presented.display.scale, 2)
        XCTAssertEqual(presented.display.id, 1)
        sut.start()
        XCTAssertEqual(toasts.shown, [.busy])

        let mark = ScreenshotAnnotation(kind: .rect(CGRect(x: 10, y: 400, width: 30, height: 30)))
        longEditor.onEvent?(.finish(.copy, displayID: 1, rect: presented.display.frame, annotations: [mark]))
        await sut.pendingTask?.value

        XCTAssertEqual(output.copied, [Data("200x900@2".utf8)])
        XCTAssertEqual(sut.state, .idle)
        XCTAssertGreaterThanOrEqual(longEditor.dismissals, 1)
        XCTAssertNil(sut.snapshot)
    }

    func testManualHorizontalImageIsEditedAndCopiedAtItsFullSize() async throws {
        let sut = await scrolling()
        let page = ScrollCaptureFixtures.page(width: 120)
        var stitcher = DirectionalScrollStitcher()
        for offset in [0, 100, 180] {
            let horizontal = ScrollCaptureFixtures.transpose(page.frameImage(offset: offset, scrollingHeight: 200))
            _ = try stitcher.add(XCTUnwrap(ScrollFrame(image: horizontal)))
        }
        let image = try XCTUnwrap(stitcher.makeImage())
        scrollCaptures[0].onFinish?(.finished(image, .user))
        XCTAssertEqual(sut.state, .editingLongImage)
        let presented = try XCTUnwrap(longEditor.presented.first)
        XCTAssertEqual(presented.display.frame, CGRect(x: 0, y: 0, width: 190, height: 60))
        XCTAssertEqual(presented.display.image.width, 380)
        XCTAssertEqual(presented.display.image.height, 120)
        let mark = ScreenshotAnnotation(kind: .rect(CGRect(x: 160, y: 10, width: 20, height: 20)))
        longEditor.onEvent?(.finish(.copy, displayID: 1, rect: presented.display.frame, annotations: [mark]))
        await sut.pendingTask?.value
        XCTAssertEqual(output.copied, [Data("380x120@2".utf8)])
        XCTAssertEqual(sut.state, .idle)
        XCTAssertNil(sut.snapshot)
        XCTAssertEqual(toasts.shown, [.copied])
    }

    func testEndingsWithANoticeShowIt() async {
        for (ending, notice) in [(ScrollCaptureEnding.reachedLimit, ScreenshotToast.scrollLimitReached),
                                 (.cannotScroll, .scrollUnavailable), (.interrupted, .scrollInterrupted)] {
            toasts.clear()
            let sut = await scrolling()
            scrollCaptures.last?.onFinish?(.finished(ScreenCaptureTestSupport.image(width: 20, height: 20), ending))
            XCTAssertEqual(toasts.shown, [notice])
            sut.cancel()
        }
        XCTAssertNil(ScreenshotCoordinator.toast(for: .user))
        XCTAssertNil(ScreenshotCoordinator.toast(for: .reachedEnd))
    }

    func testCancellingOrFailingTheScrollingCaptureEndsTheScreenshot() async {
        let cancelled = await scrolling()
        scrollCaptures[0].onFinish?(.cancelled)
        XCTAssertEqual(cancelled.state, .idle)
        XCTAssertTrue(toasts.shown.isEmpty)

        let failed = await scrolling()
        scrollCaptures[1].onFinish?(.failed)
        XCTAssertEqual(failed.state, .idle)
        XCTAssertEqual(toasts.shown, [.failed])
    }

    func testCancellingTheScreenshotStopsTheScrollingCaptureOnce() async {
        let sut = await scrolling()

        sut.cancel()

        XCTAssertEqual(sut.state, .idle)
        XCTAssertEqual(scrollCaptures[0].cancels, 1)
        XCTAssertNil(sut.scrollCapture)
        // Its late result belongs to the old session.
        scrollCaptures[0].onFinish?(.finished(ScreenCaptureTestSupport.image(width: 20, height: 20), .user))
        XCTAssertTrue(longEditor.presented.isEmpty)
    }

    func testEscInTheLongImageEditorEndsTheScreenshot() async {
        let sut = await scrolling()
        scrollCaptures[0].onFinish?(.finished(ScreenCaptureTestSupport.image(width: 20, height: 20), .user))

        longEditor.onEvent?(.cancelled)

        XCTAssertEqual(sut.state, .idle)
        XCTAssertNil(sut.snapshot)
    }

    func testScrollRequestsOutsideARegionOrSessionAreIgnored() async {
        let sut = makeCoordinator()
        sut.handle(.scroll(displayID: 1, rect: CGRect(x: 0, y: 0, width: 10, height: 10)))
        XCTAssertEqual(sut.state, .idle)

        await started(sut)
        overlay.onEvent?(.scroll(displayID: 99, rect: CGRect(x: 0, y: 0, width: 10, height: 10)))
        overlay.onEvent?(.scroll(displayID: 1, rect: CGRect(x: 500, y: 500, width: 10, height: 10)))
        XCTAssertEqual(sut.state, .selecting)
        XCTAssertTrue(scrollCaptures.isEmpty)
    }

    func testScrollingModeStartsTheCaptureOnceTheRegionIsChosen() async {
        let sut = makeCoordinator()
        await started(sut, mode: .scrolling)
        XCTAssertEqual(sut.state, .selecting)
        XCTAssertEqual(overlay.scrollRequests, 0)

        overlay.onEvent?(.committed)
        XCTAssertEqual(overlay.scrollRequests, 1)
        overlay.onEvent?(.committed)
        XCTAssertEqual(overlay.scrollRequests, 1, "Only for the first region")

        sut.cancel()
        await started(sut)
        overlay.onEvent?(.committed)
        XCTAssertEqual(overlay.scrollRequests, 1, "A normal screenshot does not scroll")
    }

    // MARK: Follow-ups

    private func followingUp(_ followUp: ScreenshotFollowUp?, mode: ScreenshotMode = .region) async
        -> ScreenshotCoordinator {
        let sut = makeCoordinator()
        sut.followUpHandler = followUps
        sut.start(mode: mode, followUp: followUp)
        await sut.pendingTask?.value
        return sut
    }

    func testAFollowUpKeywordFinishesTheRegionOnceItIsChosen() async throws {
        let sut = await followingUp(.recognizeText)
        XCTAssertEqual(sut.followUpOnCommit, .recognizeText)
        XCTAssertEqual(sut.state, .selecting)

        overlay.onEvent?(.committed)

        XCTAssertEqual(overlay.finishes, [.followUp(.recognizeText)])
        XCTAssertEqual(sut.state, .idle, "The overlay closes at once")
        XCTAssertNil(sut.snapshot)
        XCTAssertNil(sut.followUpOnCommit)
        XCTAssertTrue(output.copied.isEmpty, "Nothing goes to the clipboard")
        let handed = try XCTUnwrap(followUps.handled.first)
        XCTAssertEqual(handed.followUp, .recognizeText)
        XCTAssertEqual(handed.image.image.width, 100, "The rendered region at 2×")
        XCTAssertEqual(handed.image.image.height, 60)
        XCTAssertEqual(handed.image.scale, 2)
        XCTAssertFalse(handed.image.isLongImage)
        XCTAssertEqual(handed.image.pixelSize, CGSize(width: 100, height: 60))
    }

    func testAToolbarFollowUpHandsTheMarkedUpImageOver() async throws {
        let sut = await followingUp(nil)
        overlay.onEvent?(.committed)
        XCTAssertTrue(overlay.finishes.isEmpty, "A plain screenshot stays in the editor")
        XCTAssertEqual(sut.state, .editing)

        overlay.onEvent?(.finish(.followUp(.askAI), displayID: 1, rect: CGRect(x: 0, y: 0, width: 20, height: 10)))

        XCTAssertEqual(followUps.handled.map(\.followUp), [.askAI])
        XCTAssertEqual(sut.state, .idle)
        XCTAssertTrue(output.copied.isEmpty && output.saved.isEmpty, "No encoding or delivery for a follow-up")
    }

    func testAFollowUpWithoutAHandlerFails() async {
        let sut = makeCoordinator()
        await started(sut)
        overlay.onEvent?(.committed)

        overlay.onEvent?(.finish(.followUp(.translate), displayID: 1, rect: CGRect(x: 0, y: 0, width: 20, height: 10)))

        XCTAssertEqual(toasts.shown, [.failed])
        XCTAssertEqual(sut.state, .idle)
    }

    func testAFullScreenFollowUpEndsInIdleWhenSelectingCommits() async {
        let sut = makeCoordinator()
        sut.followUpHandler = followUps
        overlay.commitsOnFullScreen = true
        sut.start(mode: .fullScreen, followUp: .askAI)
        await sut.pendingTask?.value

        XCTAssertEqual(followUps.handled.map(\.followUp), [.askAI])
        XCTAssertEqual(sut.state, .idle, "Not left in editing after the hand-over")
    }

    func testCancellingDropsTheFollowUp() async {
        let sut = await followingUp(.askAI)
        sut.cancel()
        XCTAssertNil(sut.followUpOnCommit)

        await started(sut)
        overlay.onEvent?(.committed)
        XCTAssertTrue(followUps.handled.isEmpty)
        XCTAssertEqual(sut.state, .editing)
    }

    func testAFollowUpWaitsForPermissionAndStartsOnRecheck() async {
        let permission = FakeScreenCapturePermission(granted: false)
        let sut = makeCoordinator(permission: permission)
        sut.followUpHandler = followUps
        sut.start(mode: .region, followUp: .recognizeText)
        XCTAssertEqual(guide.shown, 1)
        XCTAssertNil(sut.followUpOnCommit)

        permission.granted = true
        XCTAssertEqual(guide.actions?.recheck(), true)
        await sut.pendingTask?.value
        XCTAssertEqual(sut.followUpOnCommit, .recognizeText)
    }

    func testAScrollingFollowUpHandsTheLongImageOverWithoutTheEditor() async throws {
        let sut = await followingUp(.askAI, mode: .scrolling)
        overlay.onEvent?(.committed)
        XCTAssertEqual(overlay.scrollRequests, 1, "Scrolling comes first")
        overlay.onEvent?(.scroll(displayID: 1, rect: CGRect(x: 10, y: 20, width: 100, height: 60)))

        scrollCaptures[0].onFinish?(.finished(ScreenCaptureTestSupport.image(width: 200, height: 900), .reachedEnd))

        XCTAssertTrue(longEditor.presented.isEmpty)
        let handed = try XCTUnwrap(followUps.handled.first)
        XCTAssertEqual(handed.followUp, .askAI)
        XCTAssertTrue(handed.image.isLongImage)
        XCTAssertEqual(handed.image.pixelSize, CGSize(width: 200, height: 900))
        XCTAssertEqual(sut.state, .idle)
    }

    func testTheLongImageEditorsFollowUpIsMarkedLong() async throws {
        let sut = await scrolling()
        sut.followUpHandler = followUps
        scrollCaptures[0].onFinish?(.finished(ScreenCaptureTestSupport.image(width: 200, height: 900), .reachedEnd))
        let display = try XCTUnwrap(longEditor.presented.first?.display)

        longEditor.onEvent?(.finish(.followUp(.recognizeText), displayID: 1, rect: display.frame))

        XCTAssertEqual(followUps.handled.first?.image.isLongImage, true)
        XCTAssertEqual(sut.state, .idle)
    }
}
