import CoreGraphics
import Foundation

/// Runs one screenshot at a time, from the shortcut, the launcher or the menu bar.
///
/// `idle → capturing → selecting → editing → finishing → idle`. A scrolling capture goes
/// `editing → scrolling → editingLongImage → finishing`. Every way out (esc, a failure, a
/// finished copy or save) goes through `teardown()`, which closes the overlay, stops a
/// scrolling capture and drops the frozen or joined images. Recognizing text, translating and
/// asking the AI hand the rendered image to `followUpHandler` (the launcher) instead of the clipboard.
@MainActor
final class ScreenshotCoordinator {
    enum State: Equatable {
        case idle
        /// Freezing the displays.
        case capturing
        /// Framing: nothing chosen yet.
        case selecting
        /// A region is chosen and can still be adjusted and marked up.
        case editing
        /// The region is captured live while it scrolls.
        case scrolling
        /// The joined long image is being marked up.
        case editingLongImage
        /// The overlay has closed; the image is being encoded and delivered.
        case finishing
    }

    typealias Encoder = @Sendable (CGImage, CGFloat) throws -> Data
    typealias Renderer = (ScreenSnapshot.Display, CGRect, [ScreenshotAnnotation]) throws -> CGImage

    private(set) var state: State = .idle
    /// The frozen displays, held only while the overlay shows.
    private(set) var snapshot: ScreenSnapshot?
    /// The capture or delivery in flight, so tests can wait for it.
    private(set) var pendingTask: Task<Void, Never>?
    private let captureQueue = ScreenshotTaskQueue<ScreenSnapshot>()
    private var captureTimeoutTask: Task<Void, Never>?
    var captureTimeout: Duration = .seconds(5)
    /// A pin's copy or save in flight, so tests can wait for it.
    private(set) var pinTask: Task<Void, Never>?

    private let capture: any ScreenCapturing
    private let permission: any ScreenCapturePermissionProviding
    private let overlay: any ScreenshotOverlayPresenting
    private let permissionGuide: any ScreenshotPermissionGuidePresenting
    private let toast: any ScreenshotToastPresenting
    private let output: any ScreenshotOutputting
    private let saveDirectory: () -> URL
    private let now: () -> Date
    private let relaunch: () -> Void
    private let encode: Encoder
    private let render: Renderer
    private let longImageEditor: any ScreenshotLongImagePresenting
    /// Screenshots pinned above other windows; they outlive the session that made them.
    let pins: any ScreenshotPinPresenting
    private let makeScrollCapture: @MainActor (ScrollCaptureRegion) -> any ScrollCapturing
    /// The scrolling capture in progress.
    private(set) var scrollCapture: (any ScrollCapturing)?
    /// `jtgd`: the region goes straight to a scrolling capture once it is chosen.
    private var scrollsOnCommit = false
    /// `ocr`, `jtai`: the region goes straight to this follow-up once it is chosen.
    private(set) var followUpOnCommit: ScreenshotFollowUp?
    /// Recognizes text, translates and asks the AI; set by the app.
    weak var followUpHandler: (any ScreenshotFollowUpHandling)?
    /// Bumped by every teardown, so a capture or delivery from an earlier session is ignored.
    private var session = 0
    var isRecordingActive: () -> Bool = { false }
    var onRecordingRequested: ((ScreenRecordingFormat, ScreenRecordingTarget?) -> Void)?

    func prewarm() {
        guard state == .idle else { return }
        overlay.prewarm()
    }

    init(capture: any ScreenCapturing,
         permission: any ScreenCapturePermissionProviding,
         overlay: any ScreenshotOverlayPresenting,
         permissionGuide: any ScreenshotPermissionGuidePresenting,
         toast: any ScreenshotToastPresenting,
         output: any ScreenshotOutputting,
         saveDirectory: @escaping () -> URL,
         now: @escaping () -> Date = Date.init,
         relaunch: @escaping () -> Void = {},
         encode: @escaping Encoder = { try ScreenshotImageExporter.png($0, scale: $1) },
         render: @escaping Renderer = { try ScreenshotRenderer.render($0, crop: $1, annotations: $2) },
         longImageEditor: (any ScreenshotLongImagePresenting)? = nil,
         pins: (any ScreenshotPinPresenting)? = nil,
         makeScrollCapture: @escaping @MainActor (ScrollCaptureRegion) -> any ScrollCapturing = ScreenshotCoordinator
             .scrollCapture(for:)) {
        self.capture = capture
        self.permission = permission
        self.overlay = overlay
        self.permissionGuide = permissionGuide
        self.toast = toast
        self.output = output
        self.saveDirectory = saveDirectory
        self.now = now
        self.relaunch = relaunch
        self.encode = encode
        self.render = render
        self.longImageEditor = longImageEditor ?? ScreenshotLongImageEditorController()
        self.pins = pins ?? ScreenshotPinController()
        self.makeScrollCapture = makeScrollCapture
    }

    /// A scrolling capture with the real stream, wheel events and panels.
    static func scrollCapture(for region: ScrollCaptureRegion) -> any ScrollCapturing {
        ScrollCaptureSession(region: region, source: ScreenCaptureStreamFrameSource(), driver: ScrollDriver(),
                             monitor: ScrollUserActivityMonitor(), presenter: ScrollCaptureOverlayController())
    }

    /// Starts a screenshot. While framing, starting again selects the whole display;
    /// while capturing or finishing, it is ignored with a notice. With a `followUp`, the chosen
    /// region goes straight to it instead of the editor.
    func start(mode: ScreenshotMode = .region, followUp: ScreenshotFollowUp? = nil) {
        guard FeatureProcess.owns(.screenshot) else {
            FeatureProcess.send(FeatureScreenshotRequest(mode: mode, followUp: followUp).command); return
        }
        guard !isRecordingActive() else { ShortcutLatency.record(.blocked); toast.show(.recordingBusy); return }
        if mode == .recording || mode == .gif {
            guard state == .idle else { toast.show(.busy); return }
            onRecordingRequested?(mode == .gif ? .gif : .mp4, nil)
            return
        }
        switch state {
        case .idle:
            break
        case .selecting, .editing:
            ShortcutLatency.record(.dismissed)
            overlay.selectFullScreen()
            state = .editing
            return
        case .capturing:
            ShortcutLatency.record(.blocked)
            return
        case .finishing, .scrolling, .editingLongImage:
            ShortcutLatency.record(.blocked)
            toast.show(.busy)
            return
        }
        guard permission.isGranted else {
            ShortcutLatency.record(.blocked)
            presentPermissionGuide(mode: mode, followUp: followUp)
            return
        }
        permissionGuide.dismiss()
        state = .capturing
        followUpOnCommit = followUp
        let session = session
        captureTimeoutTask = Task { [weak self, captureTimeout] in
            do { try await Task.sleep(for: captureTimeout) } catch { return }
            guard let self, self.session == session, self.state == .capturing else { return }
            ShortcutLatency.record(.failed)
            self.teardown()
            self.toast.show(.captureTimedOut)
        }
        let capture = capture
        let captureQueue = captureQueue
        pendingTask = Task { [weak self] in
            ShortcutLatency.record(.captureStarted)
            let result: Result<ScreenSnapshot, Error>
            do {
                result = try await .success(captureQueue.capture {
                    try await capture.snapshot(ScreenCaptureRequest(windowExclusion: .screenshotControls))
                })
            } catch {
                result = .failure(error)
            }
            ShortcutLatency.record(.captureFinished)
            self?.didCapture(result, mode: mode, followUp: followUp, session: session)
        }
    }

    /// Esc, or anything else that abandons the screenshot.
    func cancel() {
        teardown()
    }

    func handle(_ event: ScreenshotOverlayEvent) {
        switch event {
        case .committed:
            if state == .selecting { state = .editing }
            if state == .editing, scrollsOnCommit {
                scrollsOnCommit = false
                overlay.startScrollCapture()
            } else if state == .editing, let followUp = followUpOnCommit {
                followUpOnCommit = nil
                overlay.finish(.followUp(followUp))
            }
        case let .scroll(displayID, rect):
            startScrollCapture(displayID: displayID, rect: rect)
        case .cancelled:
            teardown()
        case let .colorPicked(hex):
            guard state == .selecting || state == .editing else { return }
            output.copy(text: hex)
            toast.show(.colorCopied(hex))
        case let .finish(action, displayID, rect, annotations, beautification):
            finish(action, displayID: displayID, rect: rect, annotations: annotations, beautification: beautification)
        }
    }

    // MARK: Permission

    /// Asks the system once (its prompt also lists Typeflux in System Settings) and
    /// shows the guide every time access is missing.
    private func presentPermissionGuide(mode: ScreenshotMode, followUp: ScreenshotFollowUp? = nil) {
        permission.requestOnce()
        permissionGuide.show(actions: ScreenshotPermissionGuideActions(
            openSettings: { [weak self] in self?.permission.openSystemSettings() },
            recheck: { [weak self] in self?.recheckPermission(mode: mode, followUp: followUp) ?? false },
            restart: { [weak self] in self?.relaunch() },
            later: { [weak self] in self?.permissionGuide.dismiss() }
        ))
    }

    /// "Check again" in the guide: starts the screenshot once access is there.
    func recheckPermission(mode: ScreenshotMode = .region, followUp: ScreenshotFollowUp? = nil) -> Bool {
        guard permission.isGranted else { return false }
        permissionGuide.dismiss()
        start(mode: mode, followUp: followUp)
        return true
    }

    // MARK: Session

    private func didCapture(_ result: Result<ScreenSnapshot, Error>, mode: ScreenshotMode,
                            followUp: ScreenshotFollowUp?, session: Int) {
        // Esc during the capture ends the session; its late result is dropped.
        guard session == self.session, state == .capturing else { ShortcutLatency.record(.superseded); return }
        captureTimeoutTask?.cancel()
        captureTimeoutTask = nil
        switch result {
        case let .success(snapshot):
            self.snapshot = snapshot
            state = .selecting
            scrollsOnCommit = mode == .scrolling
            overlay.present(snapshot) { [weak self] event in self?.handle(event) }
            if mode == .fullScreen {
                overlay.selectFullScreen()
                // Selecting may already have committed the region, and even finished it for a follow-up.
                if state == .selecting { state = .editing }
            }
        case let .failure(error):
            ShortcutLatency.record(.failed)
            teardown()
            if (error as? ScreenCaptureError) == .permissionDenied {
                presentPermissionGuide(mode: mode, followUp: followUp)
            } else {
                toast.show(.failed)
            }
        }
    }

    private func finish(_ action: ScreenshotOutputAction, displayID: CGDirectDisplayID, rect: CGRect,
                        annotations: [ScreenshotAnnotation], beautification: ScreenshotBeautification = .init()) {
        guard state == .selecting || state == .editing || state == .editingLongImage,
              let display = snapshot?.display(id: displayID) else { return }
        if action == .record {
            guard state != .editingLongImage, annotations.isEmpty else { return }
            let region = ScreenRecordingTarget.region(displayID: displayID, rect: rect.intersection(display.frame))
            teardown()
            onRecordingRequested?(.mp4, region)
            return
        }
        let image: CGImage
        do {
            // Only the rendered image leaves the overlay, so nothing under a mosaic is ever copied or saved.
            let base: CGImage
            if let foreground = overlay.backgroundRemovedImage(displayID: displayID, rect: rect) {
                let processed = ScreenSnapshot.Display(id: display.id, frame: rect, scale: display.scale, image: foreground)
                base = try render(processed, rect, annotations)
            } else {
                base = try render(display, rect, annotations)
            }
            image = try ScreenshotBeautificationRenderer.render(base, scale: display.scale, settings: beautification)
        } catch {
            teardown()
            toast.show(.failed)
            return
        }
        if action == .pin {
            // A long image has no place on screen to pin to; the long image editor offers no pin.
            guard state != .editingLongImage else { return }
            let pinRect = beautification.isEnabled
                ? CGRect(x: rect.midX - CGFloat(image.width) / display.scale / 2,
                         y: rect.midY - CGFloat(image.height) / display.scale / 2,
                         width: CGFloat(image.width) / display.scale, height: CGFloat(image.height) / display.scale)
                : rect
            teardown()
            pins.pin(image, scale: display.scale, at: pinRect) { [weak self] event in self?.handlePin(event) }
            return
        }
        if case let .followUp(followUp) = action {
            let isLongImage = state == .editingLongImage
            teardown()
            guard let followUpHandler else {
                toast.show(.failed)
                return
            }
            followUpHandler.handle(followUp, image: ScreenshotFollowUpImage(image: image, scale: display.scale,
                                                                           isLongImage: isLongImage))
            return
        }
        // The overlay closes first, so the user is back at once; encoding runs off the main thread.
        state = .finishing
        overlay.dismiss()
        longImageEditor.dismiss()
        snapshot = nil
        let scale = display.scale, session = session, encode = encode
        pendingTask = Task { [weak self] in
            let png = await Task.detached(priority: .userInitiated) { try? encode(image, scale) }.value
            self?.deliver(png, action: action, session: session)
        }
    }

    private func deliver(_ png: Data?, action: ScreenshotOutputAction, session: Int) {
        guard session == self.session, state == .finishing else { return }
        defer { teardown() }
        guard let png else {
            toast.show(.failed)
            return
        }
        send(png, action: action)
    }

    /// Copies or saves an encoded screenshot and says how it went.
    private func send(_ png: Data, action: ScreenshotOutputAction) {
        switch action {
        case .copy:
            toast.show(output.copy(png) ? .copied : .failed)
        case .followUp, .pin, .record:
            // Handed over in `finish` without encoding; never delivered here.
            break
        case .save, .copyAndSave:
            let copied = action == .copyAndSave && output.copy(png)
            do {
                let url = try output.save(png, in: saveDirectory(), date: now())
                toast.show(.saved(url))
            } catch {
                // Never lose the shot: it goes to the clipboard instead, with the reason.
                toast.show(copied || output.copy(png) ? .savedAsCopy(reason: error.localizedDescription) : .failed)
            }
        }
    }

    // MARK: Pins

    /// A pin's copy, save and "mark up again". Pins live on after their session, so copying and saving
    /// do not depend on it; marking up waits until no other screenshot is in progress.
    func handlePin(_ event: ScreenshotPinEvent) {
        switch event {
        case let .copy(image, scale):
            encodeThenOutput(image, scale: scale, action: .copy)
        case let .save(image, scale):
            encodeThenOutput(image, scale: scale, action: .save)
        case let .edit(image, scale, screen):
            guard state == .idle, !isRecordingActive() else {
                toast.show(.busy)
                return
            }
            let scale = max(scale, 1)
            let display = ScreenSnapshot.Display(
                id: 0, frame: CGRect(x: 0, y: 0, width: CGFloat(image.width) / scale,
                                     height: CGFloat(image.height) / scale),
                scale: scale, image: image
            )
            snapshot = ScreenSnapshot(displays: [display], windows: [])
            state = .editingLongImage
            longImageEditor.present(display, on: screen) { [weak self] event in self?.handle(event) }
        }
    }

    private func encodeThenOutput(_ image: CGImage, scale: CGFloat, action: ScreenshotOutputAction) {
        let encode = encode
        pinTask = Task { [weak self] in
            let png = await Task.detached(priority: .userInitiated) { try? encode(image, scale) }.value
            guard let self else { return }
            guard let png else {
                self.toast.show(.failed)
                return
            }
            self.send(png, action: action)
        }
    }

    // MARK: Scrolling capture

    private func startScrollCapture(displayID: CGDirectDisplayID, rect: CGRect) {
        guard state == .selecting || state == .editing, let display = snapshot?.display(id: displayID) else { return }
        let region = ScrollCaptureRegion(displayID: displayID, displayFrame: display.frame, scale: display.scale,
                                         rect: rect.intersection(display.frame))
        guard !region.rect.isEmpty else { return }
        // The frozen picture goes away: the region is captured live from here.
        overlay.dismiss()
        snapshot = nil
        state = .scrolling
        let capture = makeScrollCapture(region)
        scrollCapture = capture
        let session = session
        capture.start { [weak self] result in self?.didScroll(result, region: region, session: session) }
    }

    private func didScroll(_ result: ScrollCaptureResult, region: ScrollCaptureRegion, session: Int) {
        guard session == self.session, state == .scrolling else { return }
        scrollCapture = nil
        switch result {
        case let .finished(image, ending):
            let scale = max(region.scale, 1)
            let display = ScreenSnapshot.Display(
                id: region.displayID,
                frame: CGRect(x: 0, y: 0, width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale),
                scale: scale, image: image
            )
            snapshot = ScreenSnapshot(displays: [display], windows: [])
            state = .editingLongImage
            // `jtai` with a scrolling capture: the long image goes to the AI as it is.
            if let followUp = followUpOnCommit {
                followUpOnCommit = nil
                finish(.followUp(followUp), displayID: display.id, rect: display.frame, annotations: [])
                return
            }
            longImageEditor.present(display, on: region.displayFrame) { [weak self] event in self?.handle(event) }
            if let notice = Self.toast(for: ending) { toast.show(notice) }
        case .cancelled:
            teardown()
        case .failed:
            teardown()
            toast.show(.failed)
        }
    }

    static func toast(for ending: ScrollCaptureEnding) -> ScreenshotToast? {
        switch ending {
        case .user, .reachedEnd: nil
        case .reachedLimit: .scrollLimitReached
        case .cannotScroll: .scrollUnavailable
        case .interrupted: .scrollInterrupted
        }
    }

    private func teardown() {
        captureTimeoutTask?.cancel()
        captureTimeoutTask = nil
        pendingTask?.cancel()
        pendingTask = nil
        overlay.dismiss()
        longImageEditor.dismiss()
        snapshot = nil
        state = .idle
        scrollsOnCommit = false
        followUpOnCommit = nil
        session += 1
        let capture = scrollCapture
        scrollCapture = nil
        capture?.cancel()
    }
}
