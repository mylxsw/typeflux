import AppKit
import QuartzCore

/// One clock drives the native window and the SwiftUI viewport. Independent
/// layer animations cannot keep their coordinates in sync with a resizing panel.
@MainActor
final class AskLauncherHeightAnimator {
    struct Motion {
        var start: CGFloat
        var target: CGFloat
        var velocity: CGFloat = 0
        var startedAt: TimeInterval
        var rate: CGFloat = 28

        /// A critically damped spring: smooth retargeting without a bounce.
        func sample(at time: TimeInterval) -> (height: CGFloat, velocity: CGFloat) {
            let elapsed = CGFloat(max(0, time - startedAt))
            let offset = start - target
            let coefficient = velocity + rate * offset
            let decay = exp(-rate * elapsed)
            return (target + (offset + coefficient * elapsed) * decay,
                    (velocity - rate * coefficient * elapsed) * decay)
        }
    }

    private let clock = AskDisplayClock()
    private var motion: Motion?

    /// Whether a motion is still on its way to its target.
    var isAnimating: Bool {
        motion != nil
    }

    /// - Parameter view: Ticks follow this view's display refresh when it is on
    ///   screen, so each frame samples the spring exactly once.
    func update(from height: CGFloat, to target: CGFloat, animated: Bool,
                framesPerSecond: Int = 60, rate: CGFloat = 28, view: NSView? = nil,
                apply: @escaping (CGFloat) -> Void) {
        guard height != target else {
            stop()
            return
        }
        guard animated, abs(height - target) > 0.1 else {
            stop()
            apply(target)
            return
        }
        guard motion?.target != target else { return }
        let now = CACurrentMediaTime()
        let velocity = motion?.sample(at: now).velocity ?? 0
        stop()
        motion = Motion(start: height, target: target, velocity: velocity, startedAt: now, rate: rate)
        clock.start(view: view, framesPerSecond: framesPerSecond) { [weak self] time in
            // An animator that went away must not leave its display link running.
            guard let self, let motion else { return false }
            let sample = motion.sample(at: time)
            if abs(sample.height - motion.target) < 0.1, abs(sample.velocity) < 2 {
                stop()
                apply(motion.target)
                return false
            }
            apply(sample.height)
            return true
        }
    }

    func stop() {
        clock.stop()
        motion = nil
    }
}

/// Calls back once per displayed frame until the callback returns false. A
/// display link follows the screen's refresh, including ProMotion rates, so no
/// frame is sampled twice or skipped; without a view in a window (or before
/// macOS 14) a common-mode timer stands in.
@MainActor
final class AskDisplayClock: NSObject {
    private var timer: Timer?
    private var link: AnyObject?
    private var tick: ((TimeInterval) -> Bool)?
    private var generation = 0

    var isRunning: Bool {
        tick != nil
    }

    func start(view: NSView?, framesPerSecond: Int = 60, tick: @escaping (TimeInterval) -> Bool) {
        stop()
        generation += 1
        self.tick = tick
        if #available(macOS 14.0, *), let view, view.window != nil {
            let link = view.displayLink(target: self, selector: #selector(frame(_:)))
            link.add(to: .main, forMode: .common)
            self.link = link
            return
        }
        let timer = Timer(timeInterval: 1 / Double(max(60, framesPerSecond)), repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.fire(CACurrentMediaTime()) }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if #available(macOS 14.0, *) {
            (link as? CADisplayLink)?.invalidate()
        }
        link = nil
        tick = nil
    }

    @available(macOS 14.0, *)
    @objc private func frame(_ link: CADisplayLink) {
        // Sample at the frame's presentation time, not when the callback ran.
        fire(link.targetTimestamp)
    }

    private func fire(_ time: TimeInterval) {
        guard let tick else { return }
        let current = generation
        // A callback may restart the clock; only its own run may end here.
        if !tick(time), generation == current {
            stop()
        }
    }

    deinit {
        timer?.invalidate()
        if #available(macOS 14.0, *) {
            (link as? CADisplayLink)?.invalidate()
        }
    }
}
