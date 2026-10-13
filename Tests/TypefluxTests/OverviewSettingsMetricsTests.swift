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

    @Test func overviewOpensTheChosenRecentRecord() async throws {
        try await UI.withFixture { settings in
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let store = SQLiteHistoryStore(baseDir: root)
            let record = HistoryRecord(date: Date(), transcriptText: "Overview record")
            store.save(record: record)
            let model = StudioViewModel(settingsStore: settings, historyStore: store, initialSection: .home,
                                        modelLibrary: AskModelLibrary(defaults: settings.defaults,
                                                                      automaticallyLoadsCatalog: false))
            try await UI.wait { model.displayedHistory.contains { $0.id == record.id } }
            try await UI.withWindow(StudioView(viewModel: model), width: 1100, height: 800) { _, host in
                try await UI.wait { UI.contains("Overview record", in: host) }
                try UI.button("Overview record", in: host).press()
                try await UI.wait { model.currentSection == .history && UI.contains(L("history.detail.rawTranscript"),
                                                                                    in: host) }
                #expect(UI.contains("Overview record", in: host))
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
