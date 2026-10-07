import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@Suite("Workflow output layout", .serialized)
@MainActor
struct AskWorkflowOutputLayoutTests {
    @Test(arguments: [480.0, 658.0, 700.0, 888.0])
    func `columns stay within the editor insets`(width: Double) async throws {
        _ = NSApplication.shared
        var frames: [String: CGRect] = [:]
        let view = AskWorkflowOutputLayout {
            Color.clear.frame(minWidth: 320, maxWidth: .infinity).frame(height: 160)
                .background(probe("form"))
            Color.clear.frame(maxWidth: .infinity).frame(height: 80)
                .background(probe("preview"))
        }
        .background(probe("layout"))
        .padding(.horizontal, 20)
        .frame(width: width, height: 600, alignment: .topLeading)
        .coordinateSpace(name: "editor")
        .onPreferenceChange(OutputLayoutFrames.self) { frames = $0 }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: view)
        window.contentView = hosting
        window.orderFront(nil)
        defer { window.orderOut(nil); window.close() }
        try await Task.sleep(for: .milliseconds(100))
        hosting.layoutSubtreeIfNeeded()

        let form = try #require(frames["form"])
        let preview = try #require(frames["preview"])
        let layout = try #require(frames["layout"])
        #expect(abs(form.minX - 20) < 0.5)
        #expect(abs(preview.maxX - (width - 20)) < 0.5)
        #expect(layout.contains(form) && layout.contains(preview))
        if width < 710 {
            #expect(abs(preview.minX - form.minX) < 0.5)
            #expect(abs(preview.minY - form.maxY - 20) < 0.5)
        } else {
            #expect(abs(preview.minY - form.minY) < 0.5)
            #expect(abs(preview.minX - form.maxX - 20) < 0.5)
            #expect(abs(preview.width - 330) < 0.5)
        }
    }

    private func probe(_ name: String) -> some View {
        GeometryReader { geometry in
            Color.clear.preference(key: OutputLayoutFrames.self,
                                   value: [name: geometry.frame(in: .named("editor"))])
        }
    }
}

private struct OutputLayoutFrames: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}
