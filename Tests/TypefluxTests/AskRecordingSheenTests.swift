import AppKit
import QuartzCore
import Testing
@testable import Typeflux

@Suite("Ask recording sheen")
@MainActor
struct AskRecordingSheenTests {
    @Test func shownOnlyWhileListeningAndNotUnderReduceMotion() {
        #expect(AskVoiceBorder.showsSheen(listening: true, reduceMotion: false))
        #expect(!AskVoiceBorder.showsSheen(listening: true, reduceMotion: true))
        #expect(!AskVoiceBorder.showsSheen(listening: false, reduceMotion: false))
    }

    @Test func gradientCoversTheEdgeAtEveryAngle() {
        let bounds = CGRect(x: 0, y: 0, width: 300, height: 400)
        let frame = AskRecordingSheen.gradientFrame(for: bounds)
        #expect(frame.width == 500 && frame.height == 500)
        #expect(frame.midX == bounds.midX && frame.midY == bounds.midY)
    }

    @Test func edgeStrokeStaysInsideTheCard() {
        let bounds = CGRect(x: 0, y: 0, width: 200, height: 100)
        let path = AskRecordingSheen.edgePath(in: bounds, cornerRadius: 26, lineWidth: 2)
        let box = path.boundingBoxOfPath
        #expect(box == bounds.insetBy(dx: 1, dy: 1))
        #expect(AskRecordingSheen.edgePath(in: .zero, cornerRadius: 26, lineWidth: 2).isEmpty)
        // A radius larger than the card is clamped instead of producing an invalid path.
        let small = CGRect(x: 0, y: 0, width: 10, height: 10)
        let tiny = AskRecordingSheen.edgePath(in: small, cornerRadius: 26, lineWidth: 2)
        #expect(!tiny.isEmpty)
    }

    @Test func rotationIsAnEndlessRenderServerAnimation() {
        let animation = AskRecordingSheen.rotation()
        #expect(animation.keyPath == "transform.rotation.z")
        #expect(animation.duration == AskRecordingSheen.period)
        #expect(animation.repeatCount == .infinity)
        #expect(!animation.isRemovedOnCompletion)
    }

    @Test func viewSpinsAMaskedConicGradientWithoutRedrawing() {
        let view = AskRecordingSheen.SheenView(frame: NSRect(x: 0, y: 0, width: 680, height: 100))
        view.configure(cornerRadius: 26, lineWidth: 1.5, animated: true)
        view.layout()
        #expect(view.gradientLayer.type == .conic)
        #expect(view.layer?.mask === view.maskLayer)
        #expect(view.maskLayer.lineWidth == 1.5)
        #expect(view.maskLayer.fillColor == nil)
        #expect(view.maskLayer.path?.boundingBoxOfPath == CGRect(x: 0.75, y: 0.75, width: 678.5, height: 98.5))
        #expect(view.gradientLayer.bounds.width == ceil(hypot(680, 100)))
        #expect(view.gradientLayer.animation(forKey: AskRecordingSheen.animationKey) != nil)
        #expect(!view.gradientLayer.isHidden)
        // Never takes clicks from the composer underneath.
        #expect(view.hitTest(NSPoint(x: 10, y: 10)) == nil)
    }

    @Test func reconfiguringDoesNotRestartOrStackTheAnimation() {
        let view = AskRecordingSheen.SheenView(frame: NSRect(x: 0, y: 0, width: 200, height: 80))
        view.configure(cornerRadius: 26, lineWidth: 1.5, animated: true)
        let first = view.gradientLayer.animation(forKey: AskRecordingSheen.animationKey)
        view.configure(cornerRadius: 26, lineWidth: 1.5, animated: true)
        #expect(view.gradientLayer.animationKeys()?.count == 1)
        #expect(view.gradientLayer.animation(forKey: AskRecordingSheen.animationKey) === first)
    }

    @Test func stoppingRemovesTheAnimationAndHidesTheHighlight() {
        let view = AskRecordingSheen.SheenView(frame: NSRect(x: 0, y: 0, width: 200, height: 80))
        view.configure(cornerRadius: 26, lineWidth: 1.5, animated: true)
        view.configure(cornerRadius: 26, lineWidth: 1.5, animated: false)
        #expect(view.gradientLayer.animation(forKey: AskRecordingSheen.animationKey) == nil)
        #expect(view.gradientLayer.isHidden)
    }
}
