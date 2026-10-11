import CoreGraphics
import Foundation

/// Live frames are joined after the wheel and picture settle. Captures start in manual mode;
/// automatic scrolling is an explicit action, and mouse input returns control to the user.
/// A bounded sampling interval retains overlap during continuous scrolling or animated content.
@MainActor
// swiftlint:disable:next type_body_length
final class ScrollCaptureSession: ScrollCapturing {
    /// Each automatic step scrolls this share of the scrolling part of the region.
    static let stepShare: CGFloat = 0.6
    static let quietInterval: TimeInterval = 0.25
    static let maxWait: TimeInterval = 1.2
    /// Retain overlapping intermediate frames while the user keeps scrolling.
    static let manualSampleInterval: TimeInterval = 0.25
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
        /// Scrolling back after an undo: its result is not a step that "changed nothing".
        case rewind
    }

    private struct PendingFrame {
        let image: CGImage
        let arrived: Date
        let since: Date
    }

    private struct StepFlight {
        let kind: Step
        let sent: Date
        let points: CGFloat
    }

    let region: ScrollCaptureRegion
    private(set) var stitcher: DirectionalScrollStitcher
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
    private var pending: PendingFrame?
    private var lastScroll: Date?
    private var awaitingScrollAfterUndo = false
    /// The settled image being analyzed.
    private var analyzing: CGImage?
    /// Its analysis, so tests can wait for it.
    private(set) var analysis: Task<Void, Never>?
    /// Bumped by every change to the stitcher, so an analysis started before an undo is dropped.
    private var stitcherVersion = 0
    /// The step in flight: its kind, when it went out and how far it scrolls, in points.
    private var step: StepFlight?
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
         schedule: @escaping @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> ()
             -> Void = ScrollCaptureSession
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
        stitcher = DirectionalScrollStitcher(maxPixels: maxPixels, estimator: estimator)
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
                try await source.start(region, onFrame: { [weak self] image in
                    Task { @MainActor [weak self] in self?.receive(image) }
                }, onError: { [weak self] _ in
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
        guard isActive, !awaitingScrollAfterUndo else { return }
        let time = now()
        pending = PendingFrame(image: image, arrived: time, since: pending?.since ?? time)
    }

    /// Joins a frame once the picture holds still, and sends the next automatic step.
    func tick() {
        guard isActive, analysis == nil else { return }
        if stitcher.isEmpty, let pending {
            self.pending = nil
            startAnalysis(of: pending.image)
            return
        }
        let time = now()
        let wait = state.isAutomatic ? Self.maxWait : Self.manualSampleInterval
        if let pending, (time.timeIntervalSince(pending.arrived) >= Self.quietInterval
            && lastScroll.map { time.timeIntervalSince($0) >= Self.quietInterval } != false)
            || time.timeIntervalSince(pending.since) >= wait {
            self.pending = nil
            startAnalysis(of: pending.image)
            return
        } else if pending == nil, let step, time.timeIntervalSince(step.sent) >= Self.stepTimeout {
            // The step moved nothing on screen, so no frame came.
            self.step = nil
            if step.kind == .forward {
                countUnchangedStep()
            }
        }
        stepIfReady()
    }

    /// The next automatic step, once the last one's frame is joined. Frames may still be coming
    /// (a blinking caret, a spinner, a video); they do not hold scrolling up.
    private func stepIfReady() {
        guard isActive, state.status == .scrolling, step == nil, analysis == nil, !stitcher.isEmpty else { return }
        stitcher.lockAxisForAutomatic()
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
            let result = await Task.detached(priority: .userInitiated) { () -> (
                ScrollStitcher.Outcome,
                DirectionalScrollStitcher
            )? in
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
            state.status = .manual
            if stitcher.isFull {
                finish(.reachedLimit)
                return
            }
        case let .appended(_, suspicious):
            unchangedSteps = 0
            failures = suspicious ? failures + 1 : 0
        case .unchanged:
            if finishedStep?.kind == .forward {
                countUnchangedStep()
            }
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
        driver.scroll(by: kind == .forward ? points : -points, axis: stitcher.axis ?? .vertical)
        step = StepFlight(kind: kind, sent: now(), points: points)
    }

    // MARK: Controls

    func togglePause() {
        guard isActive else { return }
        switch state.status {
        case .scrolling:
            state.status = .paused
            step = nil
            unchangedSteps = 0
        case .manual, .paused, .pausedByMouse, .misaligned, .needsAccessibility:
            guard driver.canScroll else {
                state.status = .needsAccessibility
                publish()
                return
            }
            // An analysis already in flight chooses the axis before the first automatic step.
            if analysis == nil {
                stitcher.lockAxisForAutomatic()
            }
            awaitingScrollAfterUndo = false
            failures = 0
            unchangedSteps = 0
            step = nil
            state.status = .scrolling
            // The user may have moved the pointer away; put it back in the region.
            driver.begin(in: region.rect)
            hasDriven = true
        case .starting:
            return
        }
        publish()
    }

    /// Drops the newest segment. While scrolling automatically, scrolls back by as much, so the
    /// next frame lines up with the one before.
    func undo() {
        guard isActive else { return }
        let removed = stitcher.segments.last.map {
            stitcher.axis == .horizontal ? $0.image.width : $0.height
        } ?? 0
        guard stitcher.removeLastSegment() else { return }
        stitcherVersion += 1
        pending = nil
        analyzing = nil
        failures = 0
        unchangedSteps = 0
        if state.status == .scrolling {
            sendStep(.rewind, points: CGFloat(removed) / max(region.scale, 1))
        } else {
            // The unchanged viewport must not immediately restore the segment just removed.
            awaitingScrollAfterUndo = true
        }
        publish()
    }

    func userActivity(_ activity: ScrollUserActivity) {
        guard isActive else { return }
        if activity == .scrolled {
            lastScroll = now()
            awaitingScrollAfterUndo = false
        }
        if case .dragged = activity {
            lastScroll = now()
            awaitingScrollAfterUndo = false
        }
        if activity == .clicked {
            awaitingScrollAfterUndo = false
        }
        guard state.status == .scrolling else { return }
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
            for image in [analyzing, pending?.image].compactMap(\.self) where !stitcher.isFull {
                if let frame = analyze(image) {
                    _ = stitcher.add(frame)
                }
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
        startTask?.cancel()
        stopTicking?()
        stopTicking = nil
        source.stop()
        monitor.stop()
        driver.end()
        presenter.dismiss()
        pending = nil
        lastScroll = nil
        analyzing = nil
        step = nil
    }

    private func deliver(_ result: ScrollCaptureResult) {
        let onFinish = onFinish
        self.onFinish = nil
        onFinish?(result)
    }

    private func publish() {
        state.axis = stitcher.axis ?? .vertical
        state.pixelSize = ScreenPixelSize(width: stitcher.width, height: stitcher.height)
        state.canUndo = stitcher.segments.count > 1
        state.lastSegmentSuspicious = stitcher.segments.count > 1 && stitcher.segments.last?.isSuspicious == true
        presenter.update(
            state,
            preview: ScrollCapturePreview(axis: state.axis, segments: stitcher.segments, footer: stitcher.footer,
                                          headerHeight: stitcher.headerHeight,
                                          width: stitcher.width)
        )
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
