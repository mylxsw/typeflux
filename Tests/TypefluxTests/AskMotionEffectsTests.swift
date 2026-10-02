import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@Suite("Ask shadows and motion")
struct AskMotionEffectsTests {
    @Test func elevationsGrowFromControlsToPopovers() {
        for dark in [true, false] {
            let control = AskElevation.control.layers(dark: dark)
            let panel = AskElevation.panel.layers(dark: dark)
            let popover = AskElevation.popover.layers(dark: dark)
            // Every level pairs a soft ambient shadow with a tight contact shadow.
            for layers in [control, panel, popover] {
                #expect(layers.count == 2)
                #expect(layers[0].radius > layers[1].radius)
            }
            #expect(control[0].radius < panel[0].radius)
            #expect(panel[0].radius < popover[0].radius)
            #expect(control[0].offsetY < panel[0].offsetY && panel[0].offsetY < popover[0].offsetY)
        }
    }

    @Test func lightAppearanceShadowsAreFainterAndTinted() {
        for level in [AskElevation.control, .panel, .popover] {
            #expect(level.layers(dark: false)[0].opacity < level.layers(dark: true)[0].opacity)
        }
        // The design board's panel shadow: 34pt blur, 12pt drop at 38% in dark.
        #expect(AskElevation.panel.layers(dark: true)[0] == .init(opacity: 0.38, radius: 17, offsetY: 12))
        #expect(AskElevation.shadowColor(dark: true) == .black)
        #expect(AskElevation.shadowColor(dark: false) != .black)
    }

    @Test func onlyFreshItemsRiseIn() {
        let now = Date(timeIntervalSince1970: 1000)
        #expect(AskRiseIn.isFresh(now, now: now))
        #expect(AskRiseIn.isFresh(now.addingTimeInterval(-2), now: now))
        #expect(!AskRiseIn.isFresh(now.addingTimeInterval(-AskRiseIn.freshness), now: now))
        #expect(!AskRiseIn.isFresh(now.addingTimeInterval(-3600), now: now))
        #expect(!AskRiseIn.isFresh(nil, now: now))
        #expect(AskRiseIn.distance > 0)
    }

    @Test @MainActor func transcriptRowsRiseFromTheirFirstMessage() {
        let first = Date(timeIntervalSince1970: 10), second = Date(timeIntervalSince1970: 20)
        let message = AskMessage(id: "m", role: "user", text: "Hi", createdAt: first)
        #expect(AskConversationView.createdAt(AskTranscriptItem(kind: .message(message))) == first)
        let steps = [AskMessage(id: "a", role: "assistant", text: "", createdAt: second), message]
        let group = AskTranscriptItem(kind: .activity(AskActivityGroup(id: "a", messages: steps)))
        #expect(AskConversationView.createdAt(group) == second)
        let empty = AskTranscriptItem(kind: .activity(AskActivityGroup(id: "e", messages: [])))
        #expect(AskConversationView.createdAt(empty) == nil)
    }

    @Test func popInStartsSmallBlurredAndSettles() {
        #expect(AskPopIn.startScale < 1 && AskPopIn.startScale >= 0.85)
        #expect(AskPopIn.startBlur > 0)
        #expect(AskPopIn.startOffset > 0)
        // Reduce Motion keeps a plain fade instead of the spring.
        #expect(AskPopIn.animation(reduceMotion: true) != AskPopIn.animation(reduceMotion: false))
    }

    @Test func pointerLightFollowsThePointerInsideTheShape() {
        let center = AskSpecularHighlight<Capsule>.center(CGPoint(x: 50, y: 10), in: CGSize(width: 200, height: 40))
        #expect(center.x == 0.25 && center.y == 0.25)
        // A zero-sized shape never divides by zero.
        let degenerate = AskSpecularHighlight<Capsule>.center(CGPoint(x: 5, y: 5), in: .zero)
        #expect(degenerate.x == 5 && degenerate.y == 5)
        #expect(AskSpecularHighlight<Capsule>.intensity(dark: true) < AskSpecularHighlight<Capsule>.intensity(dark: false))
        #expect(AskSpecularHighlight<Capsule>.radius > 0)
    }

    @Test func rimLightIsBrightestOnTheLitEdge() {
        for dark in [true, false] {
            let rim = AskRimLight.strength(dark: dark)
            #expect(rim.lit > rim.back)
            #expect(rim.back > 0)
        }
    }

    @Test func cardsLiftAndGiveWayGently() {
        #expect(AskLiftingCardStyle.hoverLift > 0 && AskLiftingCardStyle.hoverLift <= 4)
        #expect(AskLiftingCardStyle.pressedScale < 1 && AskLiftingCardStyle.pressedScale > 0.9)
        #expect(AskShimmer.duration > 0)
    }
}
