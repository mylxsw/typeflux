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
            AskQuickResultsView(results: state.results, question: "test", viewportHeight: 430, actions: nil,
                                thumbnails: false, onRun: { _, _ in }, onHighlight: { _ in })
                .background(AskTheme.surface)
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

    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
    func replacementRowsHaveNoGhostsAndAIStaysAtTheBottom(appearance: NSAppearance.Name) async throws {
        _ = NSApplication.shared
        let state = State()
        let window = AskTestVoiceWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 430),
                                        styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        let hosting = NSHostingView(rootView: Content(state: state))
        window.contentView = hosting
        window.orderFront(nil)
        defer { window.orderOut(nil); window.close() }
        // Prewarm icons, so the comparison measures row replacement rather than I/O.
        for prefix in ["Before", "After"] {
            for index in 0 ..< 12 {
                _ = await AskResultImageCache.shared.image(.init(
                    url: URL(fileURLWithPath: "/Applications/\(prefix)\(index).app"), thumbnail: false,
                    scale: NSScreen.main?.backingScaleFactor ?? 2))
            }
        }
        func snapshot(_ name: String) throws -> Data {
            hosting.layoutSubtreeIfNeeded()
            let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            if let path = ProcessInfo.processInfo.environment["TYPEFLUX_ASK_RESULT_SNAPSHOTS"] {
                try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
                try png.write(to: URL(fileURLWithPath: path + "/" + appearance.rawValue + "-" + name + ".png"))
            }
            return png
        }
        func frame(_ identifier: String) throws -> NSRect {
            var seen = Set<ObjectIdentifier>()
            func find(_ node: Any) -> NSRect? {
                guard let object = node as? NSObject, seen.insert(ObjectIdentifier(object)).inserted else { return nil }
                func value(_ key: String) -> Any? {
                    object.responds(to: NSSelectorFromString(key)) ? object.value(forKey: key) : nil
                }
                if value("accessibilityIdentifier") as? String == identifier {
                    return (value("accessibilityFrame") as? NSValue)?.rectValue
                }
                for child in value("accessibilityChildren") as? [Any] ?? [] {
                    if let frame = find(child) { return frame }
                }
                return nil
            }
            return try #require(find(window))
        }
        state.results = results("Before", count: 12)
        try await Task.sleep(for: .milliseconds(100))
        let anchored = try frame("ask.quick.askAI")
        #expect(anchored.height > 0 && anchored.minY >= window.frame.minY)
        let before = try snapshot("before")
        var weak = results("After", count: 2)
        weak.best = nil
        weak.highlighted = weak.rows.count - 1
        state.results = weak
        try await Task.sleep(for: .milliseconds(32))
        let immediate = try snapshot("replacement-32ms")
        #expect(try frame("ask.quick.askAI") == anchored, "AI must not move when a query loses its best match")
        let first = try frame("ask.quick.app")
        #expect(abs(first.maxY - (window.frame.maxY - 29)) < 1,
                "Reset to the heading and show the entire first result after replacing groups")
        try await Task.sleep(for: .milliseconds(350))
        let settled = try snapshot("replacement-settled")
        #expect(before != settled, "Exercise a real replacement of text, count and selection")
        #expect(immediate == settled, "New rows must render once, without fading or moving old text over them")

        // The former first result survives as the second item in the next batch.
        // An old onChange closure must not scroll to that former first identity.
        let expanded = results("After", count: 12)
        state.results = AskQuickResults(apps: [expanded.apps[1]], lead: true)
        try await Task.sleep(for: .milliseconds(50))
        state.results = expanded
        try await Task.sleep(for: .milliseconds(32))
        _ = try snapshot("ranking-32ms")
        #expect(abs(try frame("ask.quick.app").maxY - (window.frame.maxY - 29)) < 1,
                "A changed default result must reset to the new first row, not a previous render's first row")
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
