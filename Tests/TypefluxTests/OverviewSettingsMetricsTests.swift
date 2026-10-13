import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@Suite(.serialized, .exclusiveUIState)
@MainActor
struct OverviewSettingsMetricsTests {
    private typealias UI = SettingsBehaviorTestSupport

    @Test(arguments: [InterfaceStyle.classic, .liquidGlass])
    func metricsUseReadableGroupedRows(style: InterfaceStyle) async throws {
        try await UI.withFixture { _ in
            for language in [AppLanguage.english, .simplifiedChinese, .japanese, .korean] {
                AppLocalization.shared.setLanguage(language)
                for width: CGFloat in [480, 640, 900] {
                    let content = TypefluxForm {
                        OverviewSettingsMetrics(completionRate: 97, transcriptionMinutesText: "999,999",
                                                totalCharacters: 99999999, savedMinutes: 999999, averagePaceWPM: 999)
                    }.environment(\.interfaceStyle, style)
                    try await UI.withWindow(content, width: width, height: 640) { window, host in
                        try await UI.wait { UI.contains("999,999 min", in: host) }
                        let bounds = window.convertToScreen(host.convert(host.bounds, to: nil))
                        for text in ["97%", "999,999 min", "99999999", "999999 min", "999 wpm"] {
                            let value = try #require(UI.elements(in: host).first { $0.text == text })
                            #expect(value.frame.width > 0 && value.frame.height > 0)
                            #expect(value.frame.minX >= bounds.minX && value.frame.maxX <= bounds.maxX)
                        }
                        #expect(UI.contains(L("home.activity.privacy"), in: host))
                    }
                }
            }
        }
    }

    @Test(arguments: [HistorySettingsFilter.all, .failures])
    func overviewOpensTheChosenRecentRecord(previousFilter: HistorySettingsFilter) async throws {
        try await UI.withFixture { settings in
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let store = SQLiteHistoryStore(baseDir: root)
            let record = HistoryRecord(date: Date(), transcriptText: "Overview record")
            store.save(record: record)
            store.save(record: HistoryRecord(date: Date().addingTimeInterval(-60), transcriptText: "Another record"))
            let model = StudioViewModel(settingsStore: settings, historyStore: store, initialSection: .home,
                                        modelLibrary: AskModelLibrary(defaults: settings.defaults,
                                                                      automaticallyLoadsCatalog: false))
            model.historyFilter = previousFilter
            model.searchQuery = "Overview"
            try await UI.wait("Recent record loaded for Overview") {
                model.displayedHistory.contains { $0.id == record.id }
            }
            try await UI.withWindow(StudioView(viewModel: model), width: 1100, height: 800) { window, host in
                try await UI.wait("Overview recent-record navigation row") { UI.contains("Overview record", in: host) }
                try UI.button("Overview record", in: host).press()
                #expect(model.displayedHistory.contains { $0.id == record.id })
                try await UI.wait("History section after opening a recent record") { model.currentSection == .history }
                #expect(model.historyFilter == .all)
                try await UI.wait("Chosen record detail after the history page reload") {
                    UI.contains(L("history.detail.rawTranscript"), in: host)
                }
                #expect(UI.contains("Overview record", in: host))
                #expect(!UI.contains("Another record", in: host))
                model.refreshHistory()
                #expect(model.displayedHistory.contains { $0.id == record.id })
                try await UI.wait("Chosen record detail remains visible during refresh") {
                    UI.contains(L("history.detail.rawTranscript"), in: host)
                }
                try await UI.wait("Native history toolbar search field") {
                    window.toolbar?.items.contains { $0 is NSSearchToolbarItem } == true
                }
                let field = try #require(window.toolbar?.items.compactMap { $0 as? NSSearchToolbarItem }
                    .first?.searchField)
                try TypefluxNavigationTestSupport.changeText("Another", in: field)
                let action = try #require(field.action)
                #expect(NSApp.sendAction(action, to: field.target, from: field))
                try await UI.wait("Typing a history query returns from detail to the matching list") {
                    model.searchQuery == "Another" && UI.contains("Another record", in: host)
                        && !UI.contains("Overview record", in: host)
                        && !UI.contains(L("history.detail.rawTranscript"), in: host)
                }
            }
        }
    }

    @Test func emptyOverviewOffersTheHistoryRoute() async throws {
        try await UI.withFixture { settings in
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let model = StudioViewModel(settingsStore: settings, historyStore: SQLiteHistoryStore(baseDir: root),
                                        initialSection: .home,
                                        modelLibrary: AskModelLibrary(defaults: settings.defaults,
                                                                      automaticallyLoadsCatalog: false))
            try await UI.withWindow(StudioView(viewModel: model), width: 720, height: 800) { _, host in
                try await UI.wait { UI.contains(L("home.openHistory"), in: host) }
                #expect(UI.contains(L("history.empty"), in: host))
                try UI.button(L("home.openHistory"), in: host).press()
                try await UI.wait { model.currentSection == .history }
            }
        }
    }
}
