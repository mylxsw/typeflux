import CoreGraphics
import Foundation

/// How a scrolling capture ended with an image.
enum ScrollCaptureEnding: Equatable {
    /// ↩ or the Done button.
    case user
    /// Several scrolls in a row changed nothing: the bottom.
    case reachedEnd
    case reachedLimit
    /// The region never scrolled; only the first frame is there.
    case cannotScroll
    /// The stream stopped (a display went away, the window closed); what was joined so far is kept.
    case interrupted
}

enum ScrollCaptureResult {
    case finished(CGImage, ScrollCaptureEnding)
    case cancelled
    /// Nothing was captured.
    case failed
}

/// What the bar under the region shows.
struct ScrollCaptureViewState: Equatable {
    enum Status: Equatable {
        /// Waiting for the first frame.
        case starting
        case scrolling
        /// ␣ paused it; the user can scroll by hand.
        case paused
        /// The user used the mouse, so automatic scrolling stepped aside.
        case pausedByMouse
        /// Several frames in a row did not line up; scrolling by hand from here.
        case misaligned
        /// No Accessibility access: only scrolling by hand.
        case needsAccessibility
    }

    var status: Status = .starting
    var pixelSize = ScreenPixelSize(width: 0, height: 0)
    var canUndo = false
    /// The newest segment did not line up well.
    var lastSegmentSuspicious = false

    var isAutomatic: Bool { status == .scrolling }
    /// ␣ resumes from any pause; without Accessibility there is nothing to resume.
    var canToggleAutomatic: Bool { status != .needsAccessibility && status != .starting }
}

/// The stitched image so far, for the preview strip.
struct ScrollCapturePreview {
    var segments: [ScrollStitcher.Segment] = []
    var footer: CGImage?
    var headerHeight = 0
    var width = 0
}

/// The buttons and keys of the scrolling capture bar.
struct ScrollCaptureActions {
    var togglePause: () -> Void
    var undo: () -> Void
    var cancel: () -> Void
    var finish: () -> Void
    var openAccessibilitySettings: () -> Void
}

/// The dimmed surroundings, the region's outline, the bar and the preview.
@MainActor
protocol ScrollCapturePresenting: AnyObject {
    func present(_ region: ScrollCaptureRegion, actions: ScrollCaptureActions)
    func update(_ state: ScrollCaptureViewState, preview: ScrollCapturePreview)
    func dismiss()
}

/// The scrolling capture that `ScreenshotCoordinator` runs.
@MainActor
protocol ScrollCapturing: AnyObject {
    func start(onFinish: @escaping (ScrollCaptureResult) -> Void)
    func cancel()
}

/// One scrolling capture: live frames of the region go to `ScrollStitcher`, the region is scrolled
/// step by step (about 60% of its height each), and the session ends at the bottom, at the size
/// limit, or when the user finishes or cancels.
///
/// A frame is only joined once the picture holds still for `quietInterval`, or after `maxWait` for
/// pages that never hold still. Only that frame is analyzed, off the main thread; while it is, no
/// step is sent or timed out. The user's own mouse input pauses automatic scrolling; frames from
/// scrolling by hand are joined the same way.
@MainActor
final class ScrollCaptureSession: ScrollCapturing {
    /// Each automatic step scrolls this share of the scrolling part of the region.
    static let stepShare: CGFloat = 0.6
    static let quietInterval: TimeInterval = 0.25
    static let maxWait: TimeInterval = 1.2
    /// After a step, nothing at all arriving for this long means nothing moved.
    static let stepTimeout: TimeInterval = 0.7
    /// This many steps in a row without change end the capture.
    static let unchangedStepsToEnd = 3
    /// This many unaligned or doubtful frames in a row pause automatic scrolling.
    static let failuresToPause = 3
    /// The pointer moving this far from where scrolling put it counts as the user taking over.
    static let pointerTolerance: CGFloat = 6
    static let tickInterval: TimeInterval = 1.0 / 30

    private enum Step {
        case forward
        /// Scrolling back up after an undo: its result is not a step that "changed nothing".
        case rewind
    }

    let region: ScrollCaptureRegion
    private(set) var stitcher: ScrollStitcher
    private(set) var state = ScrollCaptureViewState()
    private(set) var isActive = false

    private let source: any ScrollFrameSource
    private let driver: any ScrollDriving
    private let monitor: any ScrollUserActivityMonitoring
    private let presenter: any ScrollCapturePresenting
    private let now: () -> Date
    private let schedule: @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> () -> Void
    private let openAccessibilitySettings: () -> Void
    /// Reduces a captured image to a frame to join; slow, so it runs off the main thread.
    private let analyze: @Sendable (CGImage) -> ScrollFrame?

    private var onFinish: ((ScrollCaptureResult) -> Void)?
    private var stopTicking: (() -> Void)?
    /// The newest image not joined yet, when it arrived, and when the first unjoined one arrived.
    private var pending: (image: CGImage, arrived: Date, since: Date)?
    /// The settled image being analyzed.
    private var analyzing: CGImage?
    /// Its analysis, so tests can wait for it.
    private(set) var analysis: Task<Void, Never>?
    /// Bumped by every change to the stitcher, so an analysis started before an undo is dropped.
    private var stitcherVersion = 0
    /// The step in flight: its kind, when it went out and how far it scrolls, in points.
    private var step: (kind: Step, sent: Date, points: CGFloat)?
    private var unchangedSteps = 0
    private var failures = 0
    private var hasDriven = false
    /// The stream start, so tests can wait for it.
    private(set) var startTask: Task<Void, Never>?

    init(region: ScrollCaptureRegion,
         source: any ScrollFrameSource,
         driver: any ScrollDriving,
         monitor: any ScrollUserActivityMonitoring,
         presenter: any ScrollCapturePresenting,
         estimator: (any ScrollOffsetEstimating)? = VisionScrollOffsetEstimator(),
         maxPixels: Int = ScrollStitcher.defaultMaxPixels,
         now: @escaping () -> Date = Date.init,
         schedule: @escaping @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> () -> Void = ScrollCaptureSession
             .repeatingTimer,
         openAccessibilitySettings: @escaping () -> Void = {
             Task { await PrivacyGuard.requestPermission(.accessibility) }
         },
         analyze: @escaping @Sendable (CGImage) -> ScrollFrame? = { ScrollFrame(image: $0) }) {
        self.region = region
        self.source = source
        self.driver = driver
        self.monitor = monitor
        self.presenter = presenter
        self.now = now
        self.schedule = schedule
        self.openAccessibilitySettings = openAccessibilitySettings
        self.analyze = analyze
        stitcher = ScrollStitcher(maxPixels: maxPixels, estimator: estimator)
    }

    func start(onFinish: @escaping (ScrollCaptureResult) -> Void) {
        guard !isActive else { return }
        isActive = true
        self.onFinish = onFinish
        presenter.present(region, actions: ScrollCaptureActions(
            togglePause: { [weak self] in self?.togglePause() },
            undo: { [weak self] in self?.undo() },
            cancel: { [weak self] in self?.cancel() },
            finish: { [weak self] in self?.finish(.user) },
            openAccessibilitySettings: { [weak self] in self?.openAccessibilitySettings() }
        ))
        monitor.start { [weak self] activity in self?.userActivity(activity) }
        publish()
        stopTicking = schedule(Self.tickInterval) { [weak self] in self?.tick() }
        let source = source, region = region
        startTask = Task { [weak self] in
            do {
                try await source.start(region, onFrame: { image in
                    Task { @MainActor [weak self] in self?.receive(image) }
                }, onError: { _ in
                    Task { @MainActor [weak self] in self?.streamStopped() }
                })
            } catch {
                self?.streamStopped()
            }
        }
    }

    func cancel() {
        guard isActive else { return }
        stop()
        deliver(.cancelled)
    }

    // MARK: Frames

    func receive(_ image: CGImage) {
        guard isActive else { return }
        let time = now()
        pending = (image, time, pending?.since ?? time)
    }

    /// Joins a frame once the picture holds still, and sends the next automatic step.
    func tick() {
        guard isActive, analysis == nil else { return }
        let time = now()
        if let pending, time.timeIntervalSince(pending.arrived) >= Self.quietInterval
            || time.timeIntervalSince(pending.since) >= Self.maxWait {
            self.pending = nil
            startAnalysis(of: pending.image)
            return
        } else if pending == nil, let step, time.timeIntervalSince(step.sent) >= Self.stepTimeout {
            // The step moved nothing on screen, so no frame came.
            self.step = nil
            if step.kind == .forward { countUnchangedStep() }
        }
        stepIfReady()
    }

    /// The next automatic step, once the last one's frame is joined. Frames may still be coming
    /// (a blinking caret, a spinner, a video); they do not hold scrolling up.
    private func stepIfReady() {
        guard isActive, state.status == .scrolling, step == nil, analysis == nil, !stitcher.isEmpty else { return }
        sendStep(.forward, points: stepPoints)
    }

    /// Reduces the image to a frame and joins it, both off the main thread, on a copy of the
    /// stitcher. The result is dropped when the stitcher changed in the meantime (an undo).
    private func startAnalysis(of image: CGImage) {
        analyzing = image
        let analyze = analyze, copy = stitcher, version = stitcherVersion
        // In pixels; the step's own distance is usually exactly how far the content moved.
        let expected = step.map { Int(($0.kind == .forward ? $0.points : -$0.points) * max(region.scale, 1)) }
        analysis = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> (ScrollStitcher.Outcome, ScrollStitcher)? in
                guard let frame = analyze(image) else { return nil }
                var stitcher = copy
                let outcome = stitcher.add(frame, expectedShift: expected)
                return (outcome, stitcher)
            }.value
            guard let self else { return }
            analysis = nil
            analyzing = nil
            guard isActive else { return }
            if let (outcome, stitcher) = result, version == stitcherVersion {
                self.stitcher = stitcher
                stitcherVersion += 1
                handle(outcome)
            }
            stepIfReady()
        }
    }

    private func handle(_ outcome: ScrollStitcher.Outcome) {
        let finishedStep = step
        step = nil
        switch outcome {
        case .started:
            state.status = driver.canScroll ? .scrolling : .needsAccessibility
        case let .appended(_, suspicious):
            unchangedSteps = 0
            failures = suspicious ? failures + 1 : 0
        case .unchanged:
            if finishedStep?.kind == .forward { countUnchangedStep() }
        case .scrolledBack:
            break
        case .unaligned:
            failures += 1
        case .reachedLimit:
            finish(.reachedLimit)
            return
        }
        guard isActive else { return }
        if failures >= Self.failuresToPause, state.status == .scrolling {
            state.status = .misaligned
        }
        publish()
    }

    private func countUnchangedStep() {
        unchangedSteps += 1
        guard unchangedSteps >= Self.unchangedStepsToEnd else { return }
        finish(stitcher.segments.count > 1 ? .reachedEnd : .cannotScroll)
    }

    /// 60% of the part that scrolls, in points.
    var stepPoints: CGFloat {
        let scrolling = stitcher.frameHeight - stitcher.headerHeight - stitcher.footerHeight
        let rows = scrolling > 0 ? CGFloat(scrolling) / max(region.scale, 1) : region.rect.height
        return max(1, (rows * Self.stepShare).rounded())
    }

    private func sendStep(_ kind: Step, points: CGFloat) {
        if !hasDriven {
            hasDriven = true
            driver.begin(in: region.rect)
        }
        // Only what the screen shows after this step counts for it.
        pending = nil
        driver.scroll(by: kind == .forward ? points : -points)
        step = (kind, now(), points)
    }

    // MARK: Controls

    func togglePause() {
        guard isActive else { return }
        switch state.status {
        case .scrolling:
            state.status = .paused
        case .paused, .pausedByMouse, .misaligned:
            failures = 0
            unchangedSteps = 0
            step = nil
            state.status = .scrolling
            // The user may have moved the pointer away; put it back in the region.
            driver.begin(in: region.rect)
            hasDriven = true
        case .starting, .needsAccessibility:
            return
        }
        publish()
    }

    /// Drops the newest segment. While scrolling automatically, scrolls back by as much, so the
    /// next frame lines up with the one before.
    func undo() {
        guard isActive else { return }
        let removed = stitcher.segments.last?.height ?? 0
        guard stitcher.removeLastSegment() else { return }
        stitcherVersion += 1
        failures = 0
        unchangedSteps = 0
        if state.status == .scrolling {
            pending = nil
            sendStep(.rewind, points: CGFloat(removed) / max(region.scale, 1))
        }
        publish()
    }

    func userActivity(_ activity: ScrollUserActivity) {
        guard isActive, state.status == .scrolling else { return }
        if case let .moved(point) = activity, let anchor = driver.anchor,
           hypot(point.x - anchor.x, point.y - anchor.y) <= Self.pointerTolerance {
            return
        }
        state.status = .pausedByMouse
        step = nil
        publish()
    }

    /// ↩: joins what is still waiting, then ends with the image.
    func finish(_ ending: ScrollCaptureEnding) {
        guard isActive else { return }
        if ending == .user {
            for image in [analyzing, pending?.image].compactMap({ $0 }) where !stitcher.isFull {
                if let frame = analyze(image) { _ = stitcher.add(frame) }
            }
            stitcherVersion += 1
            pending = nil
        }
        stop()
        deliver(stitcher.makeImage().map { .finished($0, ending) } ?? .failed)
    }

    private func streamStopped() {
        guard isActive else { return }
        if stitcher.isEmpty {
            stop()
            deliver(.failed)
        } else {
            finish(.interrupted)
        }
    }

    private func stop() {
        isActive = false
        stopTicking?()
        stopTicking = nil
        source.stop()
        monitor.stop()
        driver.end()
        presenter.dismiss()
        pending = nil
        analyzing = nil
        step = nil
    }

    private func deliver(_ result: ScrollCaptureResult) {
        let onFinish = onFinish
        self.onFinish = nil
        onFinish?(result)
    }

    private func publish() {
        state.pixelSize = ScreenPixelSize(width: stitcher.width, height: stitcher.height)
        state.canUndo = stitcher.segments.count > 1
        state.lastSegmentSuspicious = stitcher.segments.count > 1 && stitcher.segments.last?.isSuspicious == true
        presenter.update(state, preview: ScrollCapturePreview(segments: stitcher.segments, footer: stitcher.footer,
                                                              headerHeight: stitcher.headerHeight,
                                                              width: stitcher.width))
    }

    static func repeatingTimer(_ interval: TimeInterval,
                               _ action: @escaping @MainActor () -> Void) -> () -> Void {
        let timer = Timer(timeInterval: interval, repeats: true) { _ in
            MainActor.assumeIsolated { action() }
        }
        RunLoop.main.add(timer, forMode: .common)
        return { timer.invalidate() }
    }
}
