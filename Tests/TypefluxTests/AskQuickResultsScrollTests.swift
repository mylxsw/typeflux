import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@Suite("Ask quick results scrolling", .serialized, .exclusiveUIState)
@MainActor
struct AskQuickResultsScrollTests {
    private final class State: ObservableObject {
        @Published var results = AskQuickResults(apps: [], lead: false)
    }

    private struct Content: View {
        @ObservedObject var state: State

        var body: some View {
            AskQuickResultsView(results: state.results, question: "test", actions: nil,
                                thumbnails: false, onRun: { _, _ in }, onHighlight: { _ in })
        }
    }

    private func results(_ prefix: String, count: Int) -> AskQuickResults {
        let matches = (0 ..< count).map { index in
            AskAppMatch(entry: AskAppEntry(name: "\(prefix) \(index)",
                                          url: URL(fileURLWithPath: "/Applications/\(prefix)\(index).app"),
                                          bundleID: "test.\(prefix).\(index)", names: []), score: 0.9)
        }
        return AskQuickResults(apps: matches, lead: true)
    }

    @Test func updatingResultsAndHighlightTogetherDoesNotUseAnOldRowIndex() async throws {
        let state = State()
        let window = AskTestVoiceWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 440),
                                        styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: Content(state: state))
        window.contentView = hosting
        window.orderFront(nil)
        defer { window.orderOut(nil); window.close() }

        func update(_ results: AskQuickResults) async throws {
            state.results = results
            hosting.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(50))
        }
        try await update(state.results)
        for _ in 0 ..< 3 {
            var expanded = results("expanded", count: 12)
            expanded.highlight(11)
            try await update(expanded)
            #expect(state.results.highlightedRow == .app(11))
            // The selected index stays the same while every row identity changes.
            var replaced = results("replaced", count: 12)
            replaced.highlight(11)
            try await update(replaced)
            try await update(results("short", count: 1))
            try await update(AskQuickResults(apps: [], lead: false))
            #expect(state.results.highlightedRow == .askAI)
        }
    }
}
