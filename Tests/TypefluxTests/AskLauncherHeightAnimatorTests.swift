import AppKit
import Testing
@testable import Typeflux

@Suite("Launcher height motion", .serialized, .exclusiveUIState)
@MainActor
struct AskLauncherHeightAnimatorTests {
    @Test func growthAndShrinkageSettleWithoutBouncing() {
        for (start, target): (CGFloat, CGFloat) in [(120, 550), (550, 120)] {
            let motion = AskLauncherHeightAnimator.Motion(start: start, target: target, startedAt: 0)
            var previous = start
            for tick in 0 ... 120 {
                let next = motion.sample(at: Double(tick) / 120).height
                #expect(next >= min(start, target) && next <= max(start, target))
                #expect(start < target ? next >= previous : next <= previous)
                previous = next
            }
            #expect(abs(previous - target) < 0.1)
        }
    }

    @Test func clearingAQueryClosesTheEmptyGapWithin150Milliseconds() {
        let motion = AskLauncherHeightAnimator.Motion(start: 650, target: 230, startedAt: 0, rate: 60)
        #expect(motion.sample(at: 0.016).height > 230, "Keep intermediate frames when motion is enabled")
        #expect(abs(motion.sample(at: 0.15).height - 230) < 1)
        #expect(motion.sample(at: 0.15).height >= 230, "Do not bounce past the home height")
    }

    @Test func retargetingPreservesPositionAndVelocity() {
        let first = AskLauncherHeightAnimator.Motion(start: 120, target: 550, startedAt: 0)
        let sample = first.sample(at: 0.08)
        let next = AskLauncherHeightAnimator.Motion(start: sample.height, target: 650,
                                                    velocity: sample.velocity, startedAt: 0.08)
        #expect(next.sample(at: 0.08).height == sample.height)
        #expect(abs(next.sample(at: 0.08).velocity - sample.velocity) < 0.0001)
        #expect(abs(next.sample(at: 1).height - 650) < 0.1)
    }

    @Test func nativeUpdatesHaveIntermediateFramesAndReducedMotionFinishesImmediately() async throws {
        let animator = AskLauncherHeightAnimator()
        var samples: [CGFloat] = []
        animator.update(from: 120, to: 550, animated: true) { samples.append($0) }
        try await Task.sleep(for: .milliseconds(90))
        #expect(samples.count >= 2)
        #expect(samples.allSatisfy { $0 > 120 && $0 < 550 })
        animator.update(from: samples.last ?? 120, to: 200, animated: false) { samples.append($0) }
        #expect(samples.last == 200)
        let count = samples.count
        try await Task.sleep(for: .milliseconds(60))
        #expect(samples.count == count, "cancelled animation cannot overwrite the new height")
    }

    @Test func reportsAMotionUntilItLandsOnItsTarget() async throws {
        let animator = AskLauncherHeightAnimator()
        var applied: [CGFloat] = []
        #expect(!animator.isAnimating)
        animator.update(from: 120, to: 120.05, animated: true) { applied.append($0) }
        #expect(!animator.isAnimating, "a height already in place is applied at once")
        animator.update(from: 120, to: 300, animated: true, rate: 60) { applied.append($0) }
        #expect(animator.isAnimating)
        for _ in 0 ..< 500 where animator.isAnimating { try await Task.sleep(for: .milliseconds(5)) }
        #expect(!animator.isAnimating)
        #expect(applied.last == 300, "the motion ends exactly on its target")
        animator.update(from: 300, to: 120, animated: true) { applied.append($0) }
        #expect(animator.isAnimating)
        animator.stop()
        #expect(!animator.isAnimating)
    }
}
