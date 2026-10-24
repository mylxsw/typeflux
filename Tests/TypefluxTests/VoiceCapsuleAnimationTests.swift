import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@Suite(.serialized, .exclusiveUIState)
struct VoiceCapsuleAnimationTests {
    @Test @MainActor
    func animationRequiresPresentationAndRespectsReducedMotion() {
        for phase: VoiceCapsulePhase in [.listening(handsFree: false), .listening(handsFree: true), .processing, .failure] {
            for presented in [false, true] {
                for reducedMotion in [false, true] {
                    #expect(VoiceCapsuleOrb.animates(phase: phase, isPresented: presented, reduceMotion: reducedMotion)
                        == (presented && !reducedMotion && phase != .failure))
                }
            }
        }
        var environment = EnvironmentValues()
        #expect(environment.overlayAnimationsActive)
        environment.overlayAnimationsActive = false
        #expect(!environment.overlayAnimationsActive)
    }

    @Test @MainActor
    func hiddenOrbKeepsItsPreparedArtworkStatic() async throws {
        let root = VoiceCapsuleOrb(phase: .listening(handsFree: false), level: 0.5,
                                  diameter: 44, showsRipples: true)
            .environment(\.overlayAnimationsActive, false)
            .frame(width: 64, height: 64)
        let hosting = NSHostingView(rootView: root)
        hosting.frame = CGRect(x: 0, y: 0, width: 64, height: 64)
        func pixels() throws -> Data {
            hosting.layoutSubtreeIfNeeded()
            let image = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: image)
            return try #require(image.representation(using: .png, properties: [:]))
        }
        let before = try pixels()
        try await Task.sleep(for: .milliseconds(120))
        #expect(try pixels() == before)
    }

    @Test @MainActor
    func presentedPhaseArtworkRenders() throws {
        for phase: VoiceCapsulePhase in [.listening(handsFree: true), .processing, .failure] {
            let hosting = NSHostingView(rootView:
                VoiceCapsuleOrb(phase: phase, level: 0.5, diameter: 44, showsRipples: true)
                    .environment(\.overlayAnimationsActive, true)
                    .frame(width: 64, height: 64))
            hosting.frame = CGRect(x: 0, y: 0, width: 64, height: 64)
            hosting.layoutSubtreeIfNeeded()
            let image = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: image)
            #expect(image.pixelsWide > 0 && image.pixelsHigh > 0)
        }
    }
}
