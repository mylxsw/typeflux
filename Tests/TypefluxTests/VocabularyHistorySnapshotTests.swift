import AppKit
import SwiftUI
@testable import Typeflux
import XCTest

/// Run in the focused XCTest process to capture the real window server compositor.
@MainActor
final class VocabularyHistorySnapshotTests: XCTestCase {
    func testFourAppearanceCombinations() async throws {
        guard let path = ProcessInfo.processInfo.environment["TYPEFLUX_VOCABULARY_HISTORY_SNAPSHOTS"] else { return }
        let root = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try await SettingsBehaviorTestSupport.withFixture { settings in
            let store = seedFixture(settings, root: root)
            let record = try XCTUnwrap(store.list().first { $0.personaPrompt != nil })
            for style in InterfaceStyle.allCases {
                for dark in [false, true] {
                    settings.interfaceStyle = style
                    settings.appearanceMode = dark ? .dark : .light
                    let model = StudioViewModel(
                        settingsStore: settings,
                        historyStore: store,
                        initialSection: .vocabulary,
                        modelLibrary: AskModelLibrary(defaults: settings.defaults,
                                                      automaticallyLoadsCatalog: false)
                    )
                    let window = makeWindow(StudioView(viewModel: model), dark: dark)
                    defer { window.close() }
                    try await capture(window, name: "vocabulary", style: style, dark: dark, root: root)
                    model.searchQuery = "typeflx"
                    try await capture(window, name: "vocabulary-search-empty", style: style, dark: dark, root: root)
                    model.searchQuery = ""
                    try SettingsBehaviorTestSupport.button(L("vocabulary.action.newWord"), in: window).press()
                    try await SettingsBehaviorTestSupport.wait { window.attachedSheet != nil }
                    try await capture(window, name: "vocabulary-sheet", style: style, dark: dark, root: root)
                    let sheet = try XCTUnwrap(window.attachedSheet)
                    try SettingsBehaviorTestSupport.button(L("common.cancel"), in: sheet).press()
                    try await SettingsBehaviorTestSupport.wait { window.attachedSheet == nil }
                    model.navigate(to: .history)
                    try await SettingsBehaviorTestSupport.wait { model.displayedHistory.count == 3 }
                    try await capture(window, name: "history", style: style, dark: dark, root: root)
                    let preview = try XCTUnwrap(model.displayedHistory.first { $0.id == record.id }?.previewText)
                    try SettingsBehaviorTestSupport.button(preview, in: window).press()
                    try await capture(window, name: "history-detail", style: style, dark: dark, root: root)
                    scrollDetailToBottom(window)
                    try await capture(window, name: "history-pipeline", style: style, dark: dark, root: root)
                    try SettingsBehaviorTestSupport.button(L("history.action.back"), in: window).press()
                    model.historyFilter = .audio
                    try await SettingsBehaviorTestSupport.wait { model.displayedHistory.isEmpty }
                    try await capture(window, name: "history-filter-empty", style: style, dark: dark, root: root)
                    try await captureEmptyVocabulary(model, window: window, style: style, dark: dark, root: root)
                    try await captureAccessibility(settings, model: model, style: style, dark: dark, root: root)
                }
            }
        }
    }

    private func seedFixture(_ settings: SettingsStore, root: URL) -> SQLiteHistoryStore {
        settings.appLanguage = .simplifiedChinese
        AppLocalization.shared.setLanguage(.simplifiedChinese)
        settings.historyRetentionPolicy = .forever
        let store = SQLiteHistoryStore(baseDir: root.appendingPathComponent("fixture"))
        store.clear()
        let base = Date()
        let record = HistoryRecord(date: base, transcriptText: "明天上午讨论 Typeflux 的新版本。",
                                   personaPrompt: "Make the transcript concise.",
                                   personaResultText: "明早讨论 Typeflux 新版本。", postProcessedText: "明早讨论 Typeflux 新版本。",
                                   pipelineStats: HistoryPipelineStats(
                                       recordingStoppedAt: base, audioFileReadyAt: base.addingTimeInterval(0.1),
                                       transcriptionStartedAt: base.addingTimeInterval(0.1),
                                       transcriptionCompletedAt: base.addingTimeInterval(0.74),
                                       llmProcessingStartedAt: base.addingTimeInterval(0.74),
                                       llmProcessingCompletedAt: base.addingTimeInterval(1.06),
                                       applyStartedAt: base.addingTimeInterval(1.06),
                                       applyCompletedAt: base.addingTimeInterval(1.1),
                                       transcriptionDurationMilliseconds: 640, llmDurationMilliseconds: 320,
                                       applyDurationMilliseconds: 40, endToEndMilliseconds: 1000
                                   ), applyMessage: "Inserted successfully.")
        store.save(record: record)
        store.save(record: HistoryRecord(date: Date().addingTimeInterval(-86400),
                                         transcriptText: "检查 PGVector 的索引配置。"))
        store.save(record: HistoryRecord(date: Date().addingTimeInterval(-3600),
                                         transcriptText: "重试这条语音记录。", errorMessage: "Network connection failed."))
        VocabularyStore.save([
            VocabularyEntry(term: "Typeflux", source: .manual, occurrenceCount: 214),
            VocabularyEntry(term: "Liquid Glass", source: .automatic, occurrenceCount: 37),
            VocabularyEntry(term: "PGVector", source: .claude, occurrenceCount: 19),
            VocabularyEntry(term: "SwiftUI", source: .codex, occurrenceCount: 88)
        ])
        return store
    }

    private func captureEmptyVocabulary(_ model: StudioViewModel, window: NSWindow,
                                        style: InterfaceStyle, dark: Bool, root: URL) async throws {
        let entries = VocabularyStore.load()
        VocabularyStore.save([])
        model.navigate(to: .vocabulary)
        try await SettingsBehaviorTestSupport.wait { model.vocabularyEntries.isEmpty }
        try await capture(window, name: "vocabulary-empty", style: style, dark: dark, root: root)
        VocabularyStore.save(entries)
    }

    private func captureAccessibility(_ settings: SettingsStore, model: StudioViewModel,
                                      style: InterfaceStyle, dark: Bool, root: URL) async throws {
        guard style == .liquidGlass else { return }
        model.navigate(to: .vocabulary)
        for increasedContrast in [false, true] {
            let content = StudioView(viewModel: model).environment(\.typefluxAccessibilityOptions,
                                                                   TypefluxAccessibilityOptions(
                                                                       reduceTransparency: !increasedContrast,
                                                                       increasedContrast: increasedContrast
                                                                   ))
            let window = makeWindow(content, dark: dark)
            defer { window.close() }
            try await capture(window, name: increasedContrast ? "contrast" : "reduce-transparency",
                              style: settings.interfaceStyle, dark: dark, root: root)
        }
    }

    private func scrollDetailToBottom(_ window: NSWindow) {
        guard let content = window.contentView else { return }
        func descendants(_ view: NSView) -> [NSView] {
            [view] + view.subviews.flatMap(descendants)
        }
        let scroll = descendants(content).compactMap { $0 as? NSScrollView }.last {
            ($0.documentView?.bounds.height ?? 0) > $0.contentSize.height
        }
        guard let scroll, let document = scroll.documentView else { return }
        let offset = document.isFlipped ? max(0, document.bounds.height - scroll.contentSize.height) : 0
        scroll.contentView.scroll(to: NSPoint(x: 0, y: offset))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    private func makeWindow(_ view: some View, dark: Bool) -> NSWindow {
        let window = NSPanel(contentRect: NSRect(x: 40, y: 40, width: 1280, height: 820),
                             styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.toolbar = NSToolbar(identifier: "vocabulary-history-snapshot")
        window.toolbarStyle = .unified
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let host = NSHostingView(rootView: view)
        host.sizingOptions = []
        window.contentView = host
        window.level = .floating
        window.orderFrontRegardless()
        window.makeKey()
        window.setContentSize(NSSize(width: 1280, height: 820))
        return window
    }

    private func capture(_ window: NSWindow, name: String, style: InterfaceStyle, dark: Bool, root: URL) async throws {
        try await Task.sleep(for: .milliseconds(500))
        window.displayIfNeeded()
        let file = root.appendingPathComponent("\(name)-\(style.rawValue)-\(dark ? "dark" : "light").png")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l", String(window.windowNumber), file.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertTrue(try Data(contentsOf: file).count > 1000)
    }
}
