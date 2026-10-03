import AppKit
import SwiftUI
import Testing
@testable import Typeflux

/// Renders the orb frame by frame for a motion review. Opt-in through
/// TYPEFLUX_ORB_FRAMES. Dictation starts at 2 s and stops at 6 s; the left drop
/// reproduces the old behaviour (the loop length and the outline switch at
/// once), the right one is the eased `AskOrbMotion`.
@Suite("Ask orb motion frames", .serialized)
@MainActor
struct AskConversationOrbRenderTests {
    static let frames = 300

    static func listening(at seconds: Double) -> Bool { seconds >= 2 && seconds < 6 }

    /// The previous behaviour: the phase came from the clock with a period that switched.
    static func switchedPhase(at seconds: Double) -> Double {
        let period = listening(at: seconds) ? AskConversationOrb.period / 2 : AskConversationOrb.period
        return seconds.truncatingRemainder(dividingBy: period) / period
    }

    @Test func renderTransitionFrames() throws {
        guard let directory = ProcessInfo.processInfo.environment["TYPEFLUX_ORB_FRAMES"] else { return }
        let root = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var motion = AskOrbMotion()
        for index in 0 ..< Self.frames {
            let seconds = Double(index) / 30
            let listening = Self.listening(at: seconds)
            if index > 0 { motion = motion.advanced(by: 1.0 / 30, listening: listening) }
            let view = HStack(spacing: 0) {
                tile(AskConversationOrb(size: 120).drop(phase: Self.switchedPhase(at: seconds),
                                                        energy: listening ? 1 : 0))
                tile(AskConversationOrb(size: 120).drop(phase: motion.phase, energy: motion.energy))
            }
            .frame(width: 640, height: 300)
            .background(Color(red: 0.12, green: 0.12, blue: 0.13))
            .environment(\.colorScheme, .dark)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let image = try #require(renderer.nsImage)
            let rep = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
            let png = try #require(rep.representation(using: .png, properties: [:]))
            try png.write(to: root.appendingPathComponent(String(format: "f%03d.png", index)))
        }
    }

    @Test func oldBehaviourJumpedWhereTheNewOneGlides() {
        // Just after dictation starts the old phase leapt; the eased one barely moves.
        let before = Self.switchedPhase(at: 1.99), after = Self.switchedPhase(at: 2.0)
        #expect(abs(after - before) > 0.2)
        var motion = AskOrbMotion(phase: before, energy: 0)
        motion = motion.advanced(by: 0.01, listening: true)
        #expect(abs(motion.phase - before) < 0.01)
    }

    private func tile(_ content: some View) -> some View {
        content.frame(width: 120, height: 120).frame(width: 320, height: 300)
    }
}
