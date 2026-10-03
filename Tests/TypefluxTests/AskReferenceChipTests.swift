import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@Suite("Ask reference pills", .serialized)
@MainActor
struct AskReferenceChipTests {
    private func reference(_ text: String = "A selected sentence", question: String = "") -> AskReference {
        AskReference(messageId: "source", text: text, question: question)
    }

    @Test func previewDropsSelectionDebris() {
        // A selection that starts mid-sentence keeps its leading comma.
        #expect(AskReference.preview("，内容是你问 Grok 帮你找") == "内容是你问 Grok 帮你找")
        // Rendered list markers, blank lines and tabs collapse into one line.
        #expect(AskReference.preview("\n3.\t右侧主对话区：是你和 Grok 的对话") == "右侧主对话区：是你和 Grok 的对话")
        #expect(AskReference.preview("课程大纲，但没有逐字稿。\n• 提供了一些建议。") == "课程大纲，但没有逐字稿。 提供了一些建议。")
        #expect(AskReference.preview("- first\n  * second\n> quoted") == "first second quoted")
        #expect(AskReference.preview("1) one\n2、two") == "one two")
        // Trailing separators go; sentence-ending punctuation stays.
        #expect(AskReference.preview("大意是：") == "大意是")
        #expect(AskReference.preview("Why not?") == "Why not?")
        #expect(AskReference.preview("Line one\n\n\nLine   two") == "Line one Line two")
        // Numbers that are content, not markers, survive.
        #expect(AskReference.preview("2026 was a year") == "2026 was a year")
        // Text made only of punctuation still shows something.
        #expect(AskReference.preview("  …  ") == "…")
        #expect(AskReference.preview("") == "")
        #expect(reference("，hello").preview == "hello")
    }

    @Test func intentFollowsTheQuestion() {
        #expect(reference(question: " \n").intent == .quote)
        #expect(reference(question: AskSelectionAction.explain.question).intent == .explain)
        #expect(reference(question: AskSelectionAction.translate.question + "\n").intent == .translate)
        #expect(reference(question: " Why? ").intent == .question("Why?"))

        #expect(AskReference.Intent.quote.label == nil)
        #expect(AskReference.Intent.explain.label == AskSelectionAction.explain.title)
        #expect(AskReference.Intent.translate.label == AskSelectionAction.translate.title)
        #expect(AskReference.Intent.question("Why?").label == "Why?")

        #expect(AskReference.Intent.quote.systemImage == "quote.opening")
        #expect(AskReference.Intent.explain.systemImage == AskSelectionAction.explain.systemImage)
        #expect(AskReference.Intent.translate.systemImage == AskSelectionAction.translate.systemImage)
        #expect(AskReference.Intent.question("x").systemImage == AskSelectionAction.ask.systemImage)
        #expect(NSImage(systemSymbolName: "quote.opening", accessibilityDescription: nil) != nil)
    }

    @Test func typedQuestionPillsShowOnlyTheQuestion() {
        #expect(AskReferenceChip.showsExcerpt(.quote))
        #expect(AskReferenceChip.showsExcerpt(.explain))
        #expect(AskReferenceChip.showsExcerpt(.translate))
        #expect(!AskReferenceChip.showsExcerpt(.question("Why?")))
        #expect(AskReferenceChip.maxWidth == 188)
        // Three sent pills fit beside each other in the bubble column.
        #expect(AskSentReferences.itemMaxWidth * 3 + AskReferenceStrip.spacing * 2 <= AskMetrics.bubbleMaxWidth)
    }

    @Test func dismissKeepsOnlyRealEditsWithinBudget() {
        let original = reference("abc")
        var edited = original
        edited.question = "Why?"
        #expect(AskReferenceEditor.keepsOnDismiss(edited, original: original, budget: 100))
        #expect(!AskReferenceEditor.keepsOnDismiss(original, original: original, budget: 100))
        #expect(!AskReferenceEditor.keepsOnDismiss(edited, original: nil, budget: 100))
        #expect(!AskReferenceEditor.keepsOnDismiss(edited, original: original, budget: 5))
        #expect(AskReferenceEditor.width == 360)
    }

    @Test func accessibilityLabelNamesIntentAndExcerpt() {
        #expect(AskReferenceChip.accessibilityLabel(reference("，text")) == L("ask.references.source") + ": text")
        #expect(AskReferenceChip.accessibilityLabel(reference("text", question: "Why?")) == "Why?: text")
    }

    @Test func placeholderCountsTheQuotes() {
        #expect(AskReferenceStrip.placeholder(count: 0) == nil)
        #expect(AskReferenceStrip.placeholder(count: -2) == nil)
        #expect(AskReferenceStrip.placeholder(count: 1) == L("ask.references.placeholder.one"))
        let many = AskReferenceStrip.placeholder(count: 3)
        #expect(many == L("ask.references.placeholder.many", 3))
        #expect(many?.contains("3") == true)
    }

    @Test func flowRowsWrapAndNarrowOversizedItems() {
        let size = CGSize(width: 100, height: 28)
        let rows = AskFlowLayout.rows(sizes: [size, size, size], maxWidth: 210, spacing: 6)
        #expect(rows.map(\.indices) == [[0, 1], [2]])
        #expect(rows[0].width == 206)
        #expect(rows[1].width == 100)
        #expect(AskFlowLayout.height(of: rows, spacing: 6) == 62)
        // An item wider than the row gets a row of its own, narrowed to fit.
        let wide = AskFlowLayout.rows(sizes: [size, CGSize(width: 500, height: 30)], maxWidth: 210, spacing: 6)
        #expect(wide.map(\.indices) == [[0], [1]])
        #expect(wide[1].width == 210)
        #expect(wide[1].height == 30)
        #expect(AskFlowLayout.rows(sizes: [], maxWidth: 210, spacing: 6).isEmpty)
        #expect(AskFlowLayout.height(of: [], spacing: 6) == 0)
    }

    @Test func removingAndReplacingKeepTheDraftConsistent() {
        let first = reference("one")
        let second = reference("two")
        #expect(AskReferenceStrip.removing(first.id, from: [first, second]) == [second])
        // Removing the last quote returns the draft to "no quotes".
        #expect(AskReferenceStrip.removing(second.id, from: [second]) == nil)
        #expect(AskReferenceStrip.removing("missing", from: nil) == nil)
        #expect(AskReferenceStrip.removing("missing", from: [first]) == [first])

        var edited = second
        edited.question = "Why?"
        #expect(AskReferenceStrip.replacing(edited, in: [first, second]) == [first, edited])
        #expect(AskReferenceStrip.replacing(edited, in: [first]) == [first])
        #expect(AskReferenceStrip.replacing(edited, in: nil) == nil)
    }

    @Test func budgetLeavesRoomForTheOtherQuotes() {
        let edited = reference("abc", question: "d")
        let other = reference("解释", question: "xy")
        #expect(AskReferenceStrip.byteBudget(for: edited, in: [edited, other], total: 100) == 100 - 8)
        #expect(AskReferenceStrip.byteBudget(for: edited, in: [edited], total: 100) == 100)
        #expect(AskReferenceStrip.byteBudget(for: edited, in: nil) == 64000)
    }

    @Test func pinnedLastItemSitsAtTheTrailingEdge() async throws {
        _ = NSApplication.shared
        let box = MinXBox()
        func probe(pinned: Bool) -> some View {
            AskFlowLayout(spacing: 6, pinsLastToTrailingEdge: pinned) {
                Color.red.frame(width: 50, height: 20)
                Color.blue.frame(width: 30, height: 20)
                    .background(GeometryReader { geometry in
                        Color.clear.preference(key: MinXKey.self, value: geometry.frame(in: .named("flow")).minX)
                    })
            }
            .frame(width: 300)
            .coordinateSpace(name: "flow")
            .onPreferenceChange(MinXKey.self) { box.value = $0 }
        }
        for (pinned, expected) in [(true, CGFloat(270)), (false, CGFloat(56))] {
            let host = NSHostingView(rootView: probe(pinned: pinned))
            host.frame = NSRect(x: 0, y: 0, width: 300, height: 40)
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(30))
            host.layoutSubtreeIfNeeded()
            #expect(abs(box.value - expected) < 1, "pinned: \(pinned)")
        }
    }

    @Test func newCopyExistsInEveryLanguage() throws {
        let plain = ["ask.references.placeholder.one", "ask.references.clear", "ask.references.collapse",
                     "ask.references.remove", "ask.references.locate", "ask.references.saveHint",
                     "ask.references.closeHint", "ask.references.optional", "ask.quote"]
        let formatted = ["ask.references.placeholder.many": 1, "ask.references.showAll": 1,
                         "ask.references.position": 2]
        for language in AppLanguage.allCases {
            let path = try #require(language.bundleLocalizationCandidates.compactMap {
                Bundle.module.path(forResource: $0, ofType: "lproj")
            }.first)
            let bundle = try #require(Bundle(path: path))
            for key in plain {
                let value = bundle.localizedString(forKey: key, value: nil, table: nil)
                #expect(value != key, "\(key) missing in \(language.rawValue)")
            }
            for (key, count) in formatted {
                let value = bundle.localizedString(forKey: key, value: nil, table: nil)
                #expect(value != key, "\(key) missing in \(language.rawValue)")
                #expect(value.components(separatedBy: "%d").count - 1 == count, "\(key) in \(language.rawValue)")
            }
        }
    }

    @Test func traysRenderForEveryCountAndAppearance() async throws {
        _ = NSApplication.shared
        let mixed = [
            reference("，内容是你问 Grok 帮你找 Harvard 幸福课的英文原稿", question: AskSelectionAction.explain.question),
            reference("课程大纲、阅读材料和练习，但没有逐字稿。"),
            reference("\n3.\t右侧主对话区：是你和 Grok 的对话", question: "为什么没有逐字稿？"),
            reference("It Thought for 9s", question: AskSelectionAction.translate.question),
            reference("Fifth"), reference("Sixth")
        ]
        for count in [1, 3, mixed.count] {
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                let view = VStack(spacing: 12) {
                    AskReferenceStrip(references: .constant(Array(mixed.prefix(count))), locate: { _ in })
                    AskSentReferences(references: Array(mixed.prefix(count)))
                    AskReferenceEditor(reference: mixed[2], save: { _ in }, cancel: {},
                                       position: L("ask.references.position", 3, count),
                                       locate: {}, remove: {})
                }
                .padding(16).frame(width: 700).background(AskTheme.composerSurface)
                let bitmap = try await render(view, appearance: appearance)
                #expect(bitmap.pixelsWide > 0)
                #expect(bitmap.pixelsHigh > 0)
                if let directory = ProcessInfo.processInfo.environment["TYPEFLUX_REFERENCE_SNAPSHOTS"] {
                    let root = URL(fileURLWithPath: directory)
                    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                    let png = try #require(bitmap.representation(using: .png, properties: [:]))
                    try png.write(to: root
                        .appendingPathComponent("reference-pills-\(count)-\(appearance.rawValue).png"))
                }
            }
        }
    }

    @Test func trayStaysWithinTwoRowsCollapsed() async throws {
        _ = NSApplication.shared
        let many = (0..<9).map { reference("A fairly long excerpt number \($0) that will truncate in its pill") }
        let host = NSHostingView(rootView: AskReferenceStrip(references: .constant(many), locate: { _ in })
            .frame(width: 712))
        host.frame = NSRect(x: 0, y: 0, width: 712, height: 400)
        host.layoutSubtreeIfNeeded()
        let height = host.fittingSize.height
        // Four pills, "+5" and "Clear" take exactly two rows.
        #expect(abs(height - (AskReferenceChip.height * 2 + AskReferenceStrip.spacing)) < 1)

        // Unfolded, the same list scrolls inside three rows.
        let open = NSHostingView(rootView: AskReferenceStrip(references: .constant(many), locate: { _ in },
                                                             expanded: true).frame(width: 712))
        open.frame = NSRect(x: 0, y: 0, width: 712, height: 400)
        open.layoutSubtreeIfNeeded()
        #expect(abs(open.fittingSize.height - AskReferenceStrip.maxExpandedHeight) < 1)

        // A lone quote is a single full-width row.
        let single = NSHostingView(rootView: AskReferenceStrip(references: .constant([many[0]]), locate: { _ in })
            .frame(width: 712))
        single.frame = NSRect(x: 0, y: 0, width: 712, height: 400)
        single.layoutSubtreeIfNeeded()
        #expect(abs(single.fittingSize.height - AskReferenceChip.height) < 1)
    }

    @Test func threePillsShareOneRowInTheWorkspaceComposer() async throws {
        _ = NSApplication.shared
        let three = (0..<3).map { reference("A fairly long excerpt number \($0) that will truncate in its pill") }
        // The composer tray in a 1000pt window; at the composer's full width
        // there is more room still. "Clear" rides on the same row.
        let width: CGFloat = 650
        let host = NSHostingView(rootView: AskReferenceStrip(references: .constant(three), locate: { _ in })
            .frame(width: width))
        host.frame = NSRect(x: 0, y: 0, width: width, height: 200)
        host.layoutSubtreeIfNeeded()
        #expect(abs(host.fittingSize.height - AskReferenceChip.height) < 1)
    }

    private func render(_ view: some View, appearance: NSAppearance.Name) async throws -> NSBitmapImageRep {
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 600), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(80))
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return bitmap
    }
}

private final class MinXBox {
    var value: CGFloat = -1
}

private struct MinXKey: PreferenceKey {
    static let defaultValue: CGFloat = -1
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
