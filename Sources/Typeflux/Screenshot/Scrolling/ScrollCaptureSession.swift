import CoreGraphics
import Foundation
import TypefluxMediaProtocol

/// Live frames are joined while the user scrolls. By hand, each frame is analyzed as soon as the last
/// analysis is done, so the overlap with the joined image is never lost to waiting; a few older frames
/// are kept to bridge a gap the newest frame is already past. Automatic scrolling, an explicit action
/// that mouse input hands back to the user, joins each step once its picture holds still.
@MainActor
// swiftlint:disable:next type_body_length
final class ScrollCaptureSession: ScrollCapturing {
    /// Each automatic step scrolls this share of the scrolling part of the region.
    static let stepShare: CGFloat = 0.6
    static let startupTimeout: TimeInterval = 3
    static let quietInterval: TimeInterval = 0.125
    static let maxWait: TimeInterval = 0.45
    /// Appends further apart than this belong to separate scrolls; one undo removes one scroll.
    static let gestureGap: TimeInterval = 0.3
    /// Done waits at most this long for an analysis in flight before joining its frames itself.
    static let finishGrace: TimeInterval = 0.4
    /// Frames kept to bridge a gap while scrolling by hand, under a byte limit.
    private static let bridgeBudget = 64_000_000
    /// A larger viewport may keep one original intermediate frame alongside the newest one.
    private static let largeViewportBudget = 128_000_000
    private static let maxPendingFrames = 5
    private static let viewportLinger: TimeInterval = 0.16
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

    /// The newest frame not joined yet, and older ones that can bridge the way to it.
    private struct PendingFrame {
        let image: CGImage
        let arrived: Date
        /// Oldest first; only while scrolling by hand.
        var bridges: [CGImage]
        let since: Date
    }

    /// The frames one analysis joins: the newest first, then, when it is past the overlap, the
    /// bridges and the newest in order.
    struct Batch: @unchecked Sendable {
        let latest: CGImage
        var bridges: [CGImage] = []
        /// Native registration may propose shifts. It runs in a helper process and takes from a few
        /// hundred milliseconds to seconds on a large display, so scrolling by hand never waits on it.
        var registers = true
        var arrived: Date
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
    private let registration: (any ScrollFrameRegistering)?
    private static let analysisAdmission = AskToolPixelBudget(limit: 2)
    private let inbox = ScrollFrameInbox()
    private var observers: [NSObjectProtocol] = []
    private var finishing = false
    private var started = false
    private var inputsStopped = false
    private(set) var finishTask: Task<Void, Never>?
    /// Reduces a captured image to a frame to join; slow, so it runs off the main thread.
    private let analyze: @Sendable (CGImage) -> ScrollFrame?

    private var onFinish: ((ScrollCaptureResult) -> Void)?
    private var startupDeadline: Date?
    private var stopTicking: (() -> Void)?
    private var pending: PendingFrame?
    private var viewportDeadline: Date?
    private var lastScroll: Date?
    private var awaitingScrollAfterUndo = false
    /// The frames being analyzed.
    private var analyzing: Batch?
    /// Its analysis, so tests can wait for it.
    private(set) var analysis: Task<Void, Never>?
    /// Bumped by every change to the stitcher, so an analysis started before an undo is dropped.
    private var stitcherVersion = 0
    /// The step in flight: its kind, when it went out and how far it scrolls, in points.
    private var step: StepFlight?
    private var unchangedSteps = 0
    private var failures = 0
    private var hasDriven = false
    /// Where each scroll after the first frame starts, as a segment count, for undo and the preview.
    private var scrollStarts: [Int] = []
    private var lastAppend: Date?
    /// The stream start, so tests can wait for it.
    private(set) var startTask: Task<Void, Never>?

    init(region: ScrollCaptureRegion,
         source: any ScrollFrameSource,
         driver: any ScrollDriving,
         monitor: any ScrollUserActivityMonitoring,
         presenter: any ScrollCapturePresenting,
         estimator: (any ScrollFrameRegistering)? = VisionScrollOffsetEstimator(),
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
        registration = estimator
        stitcher = DirectionalScrollStitcher(maxPixels: maxPixels)
        for name in [Notification.Name.authDidLogout, .authDidLogin, .authTokenDidRefresh] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.cancel() }
            })
        }
    }

    func start(onFinish: @escaping (ScrollCaptureResult) -> Void) {
        guard !started else { return }
        started = true
        isActive = true
        self.onFinish = onFinish
        startupDeadline = now().addingTimeInterval(Self.startupTimeout)
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
        let source = source, region = region, inbox = inbox
        startTask = Task { [weak self] in
            do {
                try await source.start(region, onFrame: { [weak self] image in
                    guard inbox.offer(image) else { return }
                    Task { @MainActor [weak self] in
                        if let frame = inbox.take() { self?.receive(frame.image, viewport: frame.viewport) }
                    }
                }, onError: { [weak self] _ in
                    guard inbox.fail() else { return }
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
        stitcher = DirectionalScrollStitcher(maxPixels: stitcher.maxPixelBudget)
        deliver(.cancelled)
    }

    // MARK: Frames

    func receive(_ image: CGImage, viewport: CGImage? = nil) {
        guard isActive, !finishing, !awaitingScrollAfterUndo, Self.accepts(image) else { return }
        let time = now()
        if let viewport {
            viewportDeadline = time.addingTimeInterval(Self.viewportLinger)
            presenter.updateViewport(viewport)
        }
        var bridges: [CGImage] = []
        if !state.isAutomatic, !stitcher.isEmpty, let pending {
            let (frameBytes, overflow) = image.bytesPerRow.multipliedReportingOverflow(by: image.height)
            let room = overflow ? 0 : Self.bridgeSlots(frameBytes: frameBytes)
            if room > 0, pending.image.width == image.width, pending.image.height == image.height {
                bridges = pending.bridges
                bridges.append(pending.image)
                if bridges.count > room { bridges = Array(Self.thinned(bridges).prefix(room)) }
            }
        }
        let since = pending?.since ?? time
        pending = PendingFrame(image: image, arrived: time, bridges: bridges, since: since)
        if !state.isAutomatic { pump() }
    }

    static func bridgeSlots(frameBytes: Int) -> Int {
        guard frameBytes > 0, frameBytes <= largeViewportBudget / 2 else { return 0 }
        return max(1, min(maxPendingFrames, bridgeBudget / frameBytes) - 1)
    }

    private func clearViewport() {
        guard viewportDeadline != nil else { return }
        viewportDeadline = nil
        presenter.updateViewport(nil)
    }

    /// Every other frame, starting with the oldest: evenly spaced, still closest to the joined image.
    static func thinned(_ frames: [CGImage]) -> [CGImage] {
        stride(from: 0, to: frames.count, by: 2).map { frames[$0] }
    }

    /// Timeouts, then the next analysis or automatic step.
    func tick() {
        guard isActive, !finishing else { return }
        let time = now()
        if let startupDeadline, time >= startupDeadline {
            stop()
            deliver(.timedOut)
            return
        }
        if let viewportDeadline, time >= viewportDeadline, pending == nil, analysis == nil {
            clearViewport()
        }
        if analysis == nil, pending == nil, let step, time.timeIntervalSince(step.sent) >= Self.stepTimeout {
            // The step moved nothing on screen, so no frame came.
            self.step = nil
            if step.kind == .forward {
                countUnchangedStep()
            }
        }
        pump()
    }

    /// Starts analyzing the pending frames when nothing else is: by hand at once, during automatic
    /// scrolling once the picture holds still. Then sends the next automatic step.
    private func pump() {
        guard isActive, !finishing, analysis == nil else { return }
        if let pending {
            let time = now()
            let settled = time.timeIntervalSince(pending.arrived) >= Self.quietInterval
                && lastScroll.map { time.timeIntervalSince($0) >= Self.quietInterval } != false
            if stitcher.isEmpty {
                startAnalysis(of: Batch(latest: pending.image, arrived: pending.arrived))
                return
            }
            if state.isAutomatic {
                if settled || time.timeIntervalSince(pending.since) >= Self.maxWait {
                    startAnalysis(of: Batch(latest: pending.image, arrived: pending.arrived))
                    return
                }
            } else {
                startAnalysis(of: Batch(latest: pending.image, bridges: pending.bridges, registers: false,
                                        arrived: pending.arrived))
                return
            }
        }
        stepIfReady()
    }

    /// The next automatic step, once the last one's frame is joined. Frames may still be coming
    /// (a blinking caret, a spinner, a video); they do not hold scrolling up.
    private func stepIfReady() {
        guard isActive, !finishing, state.status == .scrolling, step == nil, analysis == nil, !stitcher.isEmpty else { return }
        stitcher.lockAxisForAutomatic()
        sendStep(.forward, points: stepPoints)
    }

    /// Reduces the frames and joins them, both off the main thread, on a copy of the stitcher.
    /// The result is dropped when the stitcher changed in the meantime (an undo).
    private func startAnalysis(of batch: Batch) {
        guard let slot = try? Self.analysisAdmission.acquire(bytes: 1) else { return }
        pending = nil
        analyzing = batch
        let analyze = analyze, copy = stitcher, version = stitcherVersion
        let registration = batch.registers ? registration : nil
        // In pixels; the step's own distance is usually exactly how far the content moved.
        let expected = step.flatMap { Self.expectedShift(($0.kind == .forward ? $0.points : -$0.points) * max(region.scale, 1)) }
        analysis = Task { [weak self] in
            let work = Task.detached(priority: .userInitiated) { () -> ([ScrollStitcher.Outcome], DirectionalScrollStitcher)? in
                defer { withExtendedLifetime(slot) {} }
                var stitcher = copy
                guard let outcomes = await Self.join(batch, into: &stitcher, expectedShift: expected,
                                                     analyze: analyze, registration: registration),
                    !Task.isCancelled else { return nil }
                return (outcomes, stitcher)
            }
            let result = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
            guard let self else { return }
            analysis = nil
            analyzing = nil
            guard isActive else { return }
            if let (outcomes, stitcher) = result, version == stitcherVersion {
                noteScroll(from: copy.segments.count, to: stitcher.segments.count)
                self.stitcher = stitcher
                stitcherVersion += 1
                for outcome in outcomes where !finishing && isActive {
                    handle(outcome)
                }
            }
            pump()
        }
    }

    /// Joins the newest frame; when it is already past the overlap, the frames in between first.
    /// - Returns: what each joined frame did, or nil when cancelled or the newest cannot be analyzed.
    nonisolated static func join(_ batch: Batch, into stitcher: inout DirectionalScrollStitcher, expectedShift: Int?,
                                 analyze: @Sendable (CGImage) -> ScrollFrame?,
                                 registration: (any ScrollFrameRegistering)?) async -> [ScrollStitcher.Outcome]? {
        guard !Task.isCancelled, let latest = analyze(batch.latest) else { return nil }
        var attempt = stitcher
        guard let outcome = try? await attempt.addPreparingOffsets(latest, expectedShift: expectedShift,
                                                                   registration: registration) else { return nil }
        if outcome != .unaligned || batch.bridges.isEmpty || stitcher.isEmpty {
            stitcher = attempt
            return [outcome]
        }
        var outcomes: [ScrollStitcher.Outcome] = []
        for image in batch.bridges {
            guard !Task.isCancelled else { return nil }
            guard !stitcher.isFull, let frame = analyze(image) else { continue }
            guard let bridged = try? await stitcher.addPreparingOffsets(frame, registration: registration)
            else { return nil }
            outcomes.append(bridged)
        }
        guard !Task.isCancelled else { return nil }
        if !stitcher.isFull,
           let last = try? await stitcher.addPreparingOffsets(latest, registration: registration) {
            outcomes.append(last)
        }
        return outcomes
    }

    /// Appends close together belong to one scroll; automatic steps are one scroll each.
    private func noteScroll(from before: Int, to after: Int) {
        // The first frame is not a scroll; the first append after it starts one.
        guard after > before, before > 0 else { return }
        let time = now()
        if state.isAutomatic || lastAppend.map({ time.timeIntervalSince($0) >= Self.gestureGap }) ?? true {
            scrollStarts.append(before)
        }
        lastAppend = time
    }

    private func handle(_ outcome: ScrollStitcher.Outcome) {
        let finishedStep = step
        step = nil
        switch outcome {
        case .started:
            startupDeadline = nil
            state.status = .manual
            if stitcher.isFull {
                finish(.reachedLimit)
                return
            }
        case let .appended(_, suspicious):
            unchangedSteps = 0
            failures = suspicious ? failures + 1 : 0
            if state.status == .misaligned { state.status = .manual }
        case .unchanged:
            if finishedStep?.kind == .forward {
                countUnchangedStep()
            }
            return
        case .scrolledBack:
            return
        case .unaligned:
            failures += 1
            if state.status == .manual, pending == nil {
                state.status = .misaligned
            }
        case .reachedLimit:
            finish(.reachedLimit)
            return
        }
        guard isActive else { return }
        if failures >= Self.failuresToPause, state.status == .scrolling || state.status == .manual {
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
            driver.begin(in: presenter.automaticScrollRect ?? region.rect)
        }
        // Only what the screen shows after this step counts for it.
        pending = nil
        driver.scroll(by: kind == .forward ? points : -points, axis: stitcher.axis ?? .vertical)
        step = StepFlight(kind: kind, sent: now(), points: points)
    }

    // MARK: Controls

    func togglePause() {
        guard isActive, !finishing else { return }
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
            driver.begin(in: presenter.automaticScrollRect ?? region.rect)
            hasDriven = true
        case .starting, .finishing:
            return
        }
        publish()
    }

    /// Drops the newest segment. While scrolling automatically, scrolls back by as much, so the
    /// next frame lines up with the one before.
    func undo() {
        guard isActive, !finishing, stitcher.segments.count > 1 else { return }
        // One scroll at a time: by hand, all slices joined during the newest scroll gesture.
        let target = max(1, min(scrollStarts.popLast() ?? stitcher.segments.count - 1, stitcher.segments.count - 1))
        scrollStarts.removeAll { $0 >= target }
        var removed = 0
        while stitcher.segments.count > target, let last = stitcher.segments.last {
            removed += stitcher.axis == .horizontal ? last.image.width : last.height
            guard stitcher.removeLastSegment() else { break }
        }
        lastAppend = nil
        stitcherVersion += 1
        analysis?.cancel()
        pending = nil
        analyzing = nil
        clearViewport()
        failures = 0
        unchangedSteps = 0
        if state.status == .scrolling {
            sendStep(.rewind, points: CGFloat(removed) / max(region.scale, 1))
        } else {
            // The unchanged viewport must not immediately restore the segments just removed.
            awaitingScrollAfterUndo = true
        }
        publish()
    }

    func userActivity(_ activity: ScrollUserActivity) {
        guard isActive, !finishing else { return }
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

    /// Stops capture at once and shows that the image is being made. An analysis in flight finishes:
    /// starting it again would only repeat its work. Only one waiting on native registration gets a
    /// short grace period, after which its frame is joined again here with the local check. Frames
    /// still waiting are joined with the local check only. Nothing runs on the UI actor but
    /// bookkeeping.
    func finish(_ ending: ScrollCaptureEnding) {
        guard isActive, !finishing else { return }
        finishing = true
        stopInputs()
        clearViewport()
        let existing = analysis, inFlight = analyzing
        var batches: [Batch] = []
        if ending == .user, let pending {
            batches.append(Batch(latest: pending.image, bridges: pending.bridges, registers: false,
                                 arrived: pending.arrived))
        }
        pending = nil
        if ending != .user {
            analysis?.cancel()
            stitcherVersion += 1
        }
        state.status = .finishing
        publish()
        let grace = Self.finishGrace, waiting = batches
        finishTask = Task { [weak self] in
            var batches = waiting
            if let existing, ending == .user {
                let joined: Bool
                if inFlight?.registers == true {
                    joined = await Self.completes(existing, within: grace)
                } else {
                    await existing.value
                    joined = true
                }
                guard let self, isActive, !Task.isCancelled else { return }
                if !joined {
                    // Too slow (native registration): drop its late result and join its frames here.
                    existing.cancel()
                    stitcherVersion += 1
                    if var inFlight {
                        inFlight.registers = false
                        batches.insert(inFlight, at: 0)
                    }
                }
            }
            guard let self, isActive, !Task.isCancelled else { return }
            let copy = stitcher, analyze = analyze, version = stitcherVersion, final = batches
            let work = Task.detached(priority: .userInitiated) { () -> CGImage? in
                var value = copy
                for batch in final {
                    guard !Task.isCancelled, !value.isFull else { break }
                    _ = await Self.join(batch, into: &value, expectedShift: nil, analyze: analyze, registration: nil)
                }
                guard !Task.isCancelled else { return nil }
                return value.makeImage()
            }
            let image = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
            guard isActive, !Task.isCancelled, version == stitcherVersion else { return }
            finishTask = nil
            stop()
            deliver(image.map { .finished($0, ending) } ?? .failed)
        }
    }

    /// Whether `task` finishes within `seconds`. Returns as soon as either happens: a task group
    /// would wait for the task anyway, and a native registration in flight ignores cancellation.
    nonisolated static func completes(_ task: Task<Void, Never>, within seconds: TimeInterval) async -> Bool {
        final class Once: @unchecked Sendable {
            private let lock = NSLock()
            private var continuation: CheckedContinuation<Bool, Never>?
            init(_ continuation: CheckedContinuation<Bool, Never>) { self.continuation = continuation }
            func resume(_ value: Bool) {
                let pending = lock.withLock { () -> CheckedContinuation<Bool, Never>? in
                    defer { continuation = nil }
                    return continuation
                }
                pending?.resume(returning: value)
            }
        }
        return await withCheckedContinuation { continuation in
            let once = Once(continuation)
            let timer = Task {
                try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                once.resume(false)
            }
            Task {
                await task.value
                once.resume(true)
                timer.cancel()
            }
        }
    }

    static func accepts(_ image: CGImage) -> Bool {
        (try? MediaRegistrationInput(width: image.width, height: image.height).validate()) != nil
    }

    static func expectedShift(_ value: CGFloat) -> Int? {
        guard value.isFinite, abs(value) <= 16384 else { return nil }
        return Int(value)
    }

    private func streamStopped() {
        guard isActive, !finishing else { return }
        if stitcher.isEmpty {
            stop()
            deliver(.failed)
        } else {
            finish(.interrupted)
        }
    }

    private func stop() {
        isActive = false
        stitcherVersion += 1
        analysis?.cancel()
        finishTask?.cancel()
        stopInputs()
        clearViewport()
        presenter.dismiss()
        pending = nil
        lastScroll = nil
        analyzing = nil
        step = nil
    }

    private func stopInputs() {
        guard !inputsStopped else { return }
        inputsStopped = true
        inbox.close()
        startTask?.cancel()
        stopTicking?()
        stopTicking = nil
        source.stop()
        monitor.stop()
        driver.end()
    }

    deinit {
        analysis?.cancel(); finishTask?.cancel(); startTask?.cancel(); inbox.close()
        observers.forEach(NotificationCenter.default.removeObserver)
        if !inputsStopped {
            source.stop()
            let monitor = monitor, driver = driver, presenter = presenter, stopTicking = stopTicking
            let cleanup = { @MainActor in
                stopTicking?(); monitor.stop(); driver.end(); presenter.dismiss()
            }
            if Thread.isMainThread { MainActor.assumeIsolated { cleanup() } }
            else { Task { @MainActor in cleanup() } }
        }
    }

    private func deliver(_ result: ScrollCaptureResult) {
        let onFinish = onFinish
        self.onFinish = nil
        onFinish?(result)
    }

    private func publish() {
        let segments = stitcher.segments
        state.axis = stitcher.axis ?? .vertical
        state.pixelSize = ScreenPixelSize(width: stitcher.width, height: stitcher.height)
        state.canUndo = segments.count > 1 && !finishing
        state.lastSegmentSuspicious = segments.count > 1 && segments.last?.isSuspicious == true
        var preview = ScrollCapturePreview(axis: state.axis, segments: segments, footer: stitcher.footer,
                                           headerHeight: stitcher.headerHeight, width: stitcher.width)
        preview.footerThumbnail = stitcher.footerThumbnail
        preview.newestStart = segments.count > 1 ? scrollStarts.last ?? segments.count - 1 : 0
        presenter.update(state, preview: preview)
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
