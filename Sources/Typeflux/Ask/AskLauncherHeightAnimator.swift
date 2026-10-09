import AppKit

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

    private var timer: Timer?
    private var motion: Motion?

    func update(from height: CGFloat, to target: CGFloat, animated: Bool,
                framesPerSecond: Int = 60, rate: CGFloat = 28, apply: @escaping (CGFloat) -> Void) {
        guard animated, abs(height - target) > 0.1 else {
            stop()
            apply(target)
            return
        }
        guard motion?.target != target else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let velocity = motion?.sample(at: now).velocity ?? 0
        stop()
        motion = Motion(start: height, target: target, velocity: velocity, startedAt: now, rate: rate)
        let timer = Timer(timeInterval: 1 / Double(max(60, framesPerSecond)), repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let motion = self.motion else { return }
                let sample = motion.sample(at: ProcessInfo.processInfo.systemUptime)
                if abs(sample.height - motion.target) < 0.1, abs(sample.velocity) < 2 {
                    self.stop()
                    apply(motion.target)
                } else {
                    apply(sample.height)
                }
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        motion = nil
    }

    deinit { timer?.invalidate() }
}
