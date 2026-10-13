import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@Suite("Launcher input history interaction", .serialized, .exclusiveUIState)
@MainActor
struct AskLauncherInputHistoryInteractionTests {
    @Test func nativeRecallSearchesAgainAndCopiesCalculationOnSecondReturn() async throws {
        try await AskQuickResultsInteractionTests().withPasteboard { pasteboard in
            let launcher = try await AskQuickResultsInteractionTests.Launcher(text: "")
            defer { launcher.close() }
            let model = launcher.fixture.model
            model.recordLauncherInput(destination: .calculation, label: "= 999", text: "2+2")
            try await launcher.press(126)
            #expect(model.launcherHistoryMode)
            #expect(pasteboard.string(forType: .string) == nil)
            try await launcher.press(36)
            #expect(!model.launcherHistoryMode)
            #expect(launcher.editor.string == "2+2")
            #expect(launcher.dismissed == 0)
            #expect(pasteboard.string(forType: .string) == nil)
            try await AskQuickSearchSessionTests.wait { !model.quickSearch.isSearching }
            try await launcher.press(36)
            #expect(pasteboard.string(forType: .string) == "4")
            #expect(launcher.dismissed == 1)
            #expect(model.launcherInputHistory.history.entries.first?.label == "= 4")
        }
    }

    @Test func nativeFilteringRightArrowNumbersAndBackspace() async throws {
        let launcher = try await AskQuickResultsInteractionTests.Launcher(text: "")
        defer { launcher.close() }
        let model = launcher.fixture.model
        model.recordLauncherInput(destination: .askAI, text: "Question")
        model.recordLauncherInput(destination: .application, label: "Zed", text: "editor")
        try await launcher.press(126)
        model.launcherDraft.text = "Question"
        try await Task.sleep(for: .milliseconds(60))
        #expect(!model.plugins.isActive)
        #expect(model.quickSearch.results == nil)
        launcher.editor.setSelectedRange(NSRange(location: 0, length: 0))
        try await launcher.press(124)
        #expect(!model.launcherHistoryMode)
        #expect(model.launcherDraft.text == "Question")
        #expect(launcher.editor.selectedRange().location == ("Question" as NSString).length)
        model.launcherDraft.text = ""
        try await Task.sleep(for: .milliseconds(60))
        try await launcher.press(126)
        try await launcher.press(19, .command)
        #expect(model.launcherDraft.text == "Question")
        #expect(!model.launcherHistoryMode)
        model.launcherDraft.text = ""
        try await Task.sleep(for: .milliseconds(60))
        try await launcher.press(126)
        try await launcher.press(51)
        #expect(!model.launcherHistoryMode)
        #expect(model.launcherDraft.text.isEmpty)
        #expect(launcher.dismissed == 0)
    }

    @Test func markedTextKeepsHistoryKeysWithTheInputMethod() async throws {
        let launcher = try await AskQuickResultsInteractionTests.Launcher(text: "")
        defer { launcher.close() }
        launcher.fixture.model.recordLauncherInput(destination: .askAI, text: "Question")
        launcher.editor.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0),
                                      replacementRange: NSRange(location: NSNotFound, length: 0))
        try await launcher.press(126)
        #expect(!launcher.fixture.model.launcherHistoryMode)
        launcher.editor.unmarkText()
    }

    @Test func emptyFilteredAndDisabledStatesShowTheRightExplanation() async throws {
        _ = NSApplication.shared
        // Match the existing UI harness: SwiftUI exposes its tree to assistive clients.
        NSApp.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
        let launcher = try await AskQuickResultsInteractionTests.Launcher(text: "")
        defer { launcher.close() }
        let model = launcher.fixture.model
        model.openLauncherInputHistory()
        try await launcher.fixture.wait { containsAccessibleText(L("ask.inputHistory.empty"), in: launcher.window) }
        #expect(containsAccessibleText(L("ask.inputHistory.empty.detail"), in: launcher.window))
        model.recordLauncherInput(destination: .askAI, text: "Question")
        model.launcherDraft.text = "missing"
        try await launcher.fixture.wait { containsAccessibleText(L("ask.inputHistory.noMatches"), in: launcher.window) }
        #expect(model.quickSearch.results == nil)
        model.launcherDraft.text = ""
        model.modelLibrary.settings.askLauncherInputHistoryEnabled = false
        try await launcher.fixture.wait { containsAccessibleText(L("ask.inputHistory.disabled"), in: launcher.window) }
        #expect(model.launcherInputHistory.history.entries.count == 1)
    }

    @Test func mouseRecallRestoresEditorFocusAtTheEnd() async throws {
        let launcher = try await AskQuickResultsInteractionTests.Launcher(text: "")
        defer { launcher.close() }
        let model = launcher.fixture.model
        model.recordLauncherInput(destination: .askAI, text: "Question")
        model.openLauncherInputHistory()
        launcher.window.makeKeyAndOrderFront(nil)
        launcher.window.makeFirstResponder(nil)
        let entry = try #require(model.highlightedLauncherHistory)
        model.fillLauncherInputHistory(entry)
        try await launcher.fixture.wait { launcher.window.firstResponder === launcher.editor }
        #expect(launcher.editor.selectedRange().location == ("Question" as NSString).length)
    }

    private func containsAccessibleText(_ label: String, in window: NSWindow) -> Bool {
        var seen = Set<ObjectIdentifier>()
        func walk(_ node: Any) -> Bool {
            guard let object = node as? NSObject, seen.insert(ObjectIdentifier(object)).inserted else { return false }
            for attribute in ["accessibilityLabel", "accessibilityValue"] {
                if object.responds(to: NSSelectorFromString(attribute)),
                   object.value(forKey: attribute) as? String == label { return true }
            }
            guard object.responds(to: NSSelectorFromString("accessibilityChildren")),
                  let children = object.value(forKey: "accessibilityChildren") as? [Any] else { return false }
            return children.contains(where: walk)
        }
        return walk(window)
    }

    @Test func renderHistoryInBothAppearances() async throws {
        guard let directory = ProcessInfo.processInfo.environment["TYPEFLUX_HISTORY_SNAPSHOTS"] else { return }
        let previousLanguage = AppLocalization.shared.language
        AppLocalization.shared.setLanguage(.simplifiedChinese)
        defer { AppLocalization.shared.setLanguage(previousLanguage) }
        let root = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let launcher = try await AskQuickResultsInteractionTests.Launcher(text: "")
            defer { launcher.close() }
            let model = launcher.fixture.model
            model.recordLauncherInput(destination: .askAI, text: "解释一下这段代码的设计思路")
            model.recordLauncherInput(destination: .keyword, label: "翻译", text: "hello world", keyword: "fy")
            model.recordLauncherInput(destination: .application, label: "Zed", text: "zed")
            model.recordLauncherInput(destination: .calculation, label: "= 33,400", text: "100*334")
            model.recordLauncherInput(destination: .unsent, text: "帮我总结今天的会议记录")
            model.openLauncherInputHistory()
            launcher.window.appearance = NSAppearance(named: appearance)
            launcher.window.setContentSize(NSSize(width: AskMetrics.launcherWidth,
                                                  height: AskLauncherInputHistoryView.height(count: 5) + 118))
            try await Task.sleep(for: .milliseconds(200))
            let hosting = try #require(launcher.window.contentView)
            hosting.layoutSubtreeIfNeeded()
            let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: root.appendingPathComponent("input-history-\(name).png"))
            #expect(png.count > 4000)
        }
    }
}
