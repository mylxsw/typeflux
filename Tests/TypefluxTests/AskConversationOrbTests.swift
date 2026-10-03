import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@Suite("Ask conversation orb")
@MainActor
struct AskConversationOrbTests {
    private let start = Date(timeIntervalSinceReferenceDate: 0)

    @Test func loopRunsEveryEightSecondsAndTwiceAsFastWhileListening() {
        #expect(AskConversationOrb.phase(at: start, listening: false) == 0)
        #expect(AskConversationOrb.phase(at: start.addingTimeInterval(2), listening: false) == 0.25)
        #expect(AskConversationOrb.phase(at: start.addingTimeInterval(8), listening: false) == 0)
        #expect(AskConversationOrb.phase(at: start.addingTimeInterval(2), listening: true) == 0.5)
        #expect(AskConversationOrb.phase(at: start.addingTimeInterval(4), listening: true) == 0)
    }

    @Test func breathStaysGentleAndLoops() {
        #expect(AskConversationOrb.breath(0) == 1)
        #expect(abs(AskConversationOrb.breath(0.25) - 1.035) < 0.0001)
        #expect(abs(AskConversationOrb.breath(1) - 1) < 0.0001)
        for step in 0 ... 20 {
            let value = AskConversationOrb.breath(Double(step) / 20)
            #expect(value >= 1 && value <= 1.0351)
        }
    }

    @Test func gradientSlidesOneCyclePerLoop() {
        #expect(AskConversationOrb.flowColors.count == AskConversationOrb.colors.count * 2 - 1)
        let length = 2 * AskConversationOrb.cycleLength
        for phase in [0.0, 0.3, 0.75] {
            let axis = AskConversationOrb.flow(phase)
            let span = hypot(axis.end.x - axis.start.x, axis.end.y - axis.start.y)
            #expect(abs(span - length) < 0.0001)
            // The centre's position along the gradient advances with the loop.
            let ux = (axis.end.x - axis.start.x) / span, uy = (axis.end.y - axis.start.y) / span
            let along = (0.5 - axis.start.x) * ux + (0.5 - axis.start.y) * uy
            #expect(abs(along - AskConversationOrb.cycleLength * (0.5 + phase)) < 0.0001)
        }
        // A whole cycle later the same colour sits at the centre, so the loop is seamless.
        let first = AskConversationOrb.flow(0), last = AskConversationOrb.flow(1)
        #expect(abs((0.5 - first.start.x) / length - (0.5 - last.start.x) / length + 0.5 * cos(.pi / 6)) < 0.0001)
    }

    @Test func outlineIsPeriodicAndBounded() {
        for step in 0 ..< 24 {
            let angle = Double(step) / 24 * 2 * .pi
            let a = AskFluidDropShape.radiusScale(angle: angle, phase: 0.3, wobble: 0.07)
            let b = AskFluidDropShape.radiusScale(angle: angle, phase: 1.3, wobble: 0.07)
            #expect(abs(a - b) < 0.000001)
            #expect(a >= 0.93 && a <= 1.07)
            #expect(AskFluidDropShape.radiusScale(angle: angle, phase: 0.3, wobble: 0) == 1)
        }
    }

    @Test func dropStaysInsideItsFrameAndCloses() {
        let rect = CGRect(x: 0, y: 0, width: 88, height: 88)
        for wobble in [AskConversationOrb.calmWobble, AskConversationOrb.listeningWobble] {
            for phase in stride(from: 0.0, to: 1.0, by: 0.125) {
                let shape = AskFluidDropShape(phase: phase, wobble: wobble)
                let points = shape.points(in: rect)
                #expect(points.count == AskFluidDropShape.samples)
                #expect(points.allSatisfy { rect.insetBy(dx: -0.01, dy: -0.01).contains($0) })
                #expect(!shape.path(in: rect).isEmpty)
            }
        }
        var shape = AskFluidDropShape(phase: 0.2)
        shape.animatableData = 0.6
        #expect(shape.phase == 0.6)
        #expect(AskFluidDropShape(phase: 0).path(in: .zero).boundingRect.width == 0)
    }

    @Test func listensOnlyToTheNewConversation() {
        #expect(AskEmptyStateOrb.listening(phase: .listening, context: "chat:new"))
        #expect(!AskEmptyStateOrb.listening(phase: .listening, context: "launcher"))
        #expect(!AskEmptyStateOrb.listening(phase: .transcribing, context: "chat:new"))
        #expect(!AskEmptyStateOrb.listening(phase: .idle, context: nil))
    }

    @Test func rendersInEveryState() {
        for listening in [false, true] {
            let hosting = NSHostingView(rootView: AskConversationOrb(listening: listening))
            hosting.layoutSubtreeIfNeeded()
            #expect(hosting.fittingSize == CGSize(width: 88, height: 88))
        }
        let small = NSHostingView(rootView: AskConversationOrb(size: 60))
        small.layoutSubtreeIfNeeded()
        #expect(small.fittingSize == CGSize(width: 60, height: 60))
        let empty = NSHostingView(rootView: AskEmptyStateOrb(voice: AskVoiceInput()))
        empty.layoutSubtreeIfNeeded()
        #expect(empty.fittingSize.width == 88)
    }
}
