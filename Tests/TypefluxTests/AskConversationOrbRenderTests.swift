import AppKit
import SwiftUI
import Testing
@testable import Typeflux

/// Renders the orb's loop frame by frame for a motion review. Opt-in through
/// TYPEFLUX_ORB_FRAMES: each frame shows the calm drop and the dictating one
/// side by side, 30 frames a second over one 8 s loop.
@Suite("Ask orb motion frames", .serialized)
@MainActor
struct AskConversationOrbRenderTests {
    @Test func renderLoopFrames() throws {
        guard let directory = ProcessInfo.processInfo.environment["TYPEFLUX_ORB_FRAMES"] else { return }
        let root = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let start = Date(timeIntervalSinceReferenceDate: 0)
        for index in 0 ..< 240 {
            let date = start.addingTimeInterval(Double(index) / 30)
            let view = HStack(spacing: 0) {
                tile(AskConversationOrb(size: 120).drop(phase: AskConversationOrb.phase(at: date, listening: false)))
                tile(AskConversationOrb(size: 120, listening: true)
                    .drop(phase: AskConversationOrb.phase(at: date, listening: true)))
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

    private func tile(_ content: some View) -> some View {
        content.frame(width: 120, height: 120).frame(width: 320, height: 300)
    }
}
