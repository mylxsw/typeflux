import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@Suite(.serialized, .exclusiveUIState)
@MainActor
struct StudioOverviewPanelTests {
    private typealias UI = SettingsBehaviorTestSupport

    @Test(arguments: [AppLanguage.english, .simplifiedChinese, .traditionalChinese, .japanese, .korean])
    func `statistics stay aligned and readable across window sizes`(language: AppLanguage) async throws {
        try await UI.withFixture { _ in
            AppLocalization.shared.setLanguage(language)
            for windowWidth: CGFloat in [720, 1040, 1100, 1190, 1200, 1440] {
                let width = StudioShellLayout(width: windowWidth).contentWidth
                let panel = StudioOverviewPanel(width: width, completionRate: 97,
                                                transcriptionMinutesText: "1,391", totalCharacters: 263995,
                                                savedMinutes: 3473, averagePaceWPM: 108)
                let content = VStack(alignment: .leading, spacing: 24) {
                    panel
                    Text(L("home.recentTranscriptions"))
                }
                .padding(24)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.interfaceStyle, .liquidGlass)
                .environment(\.colorScheme, .light)
                try await UI.withWindow(content, width: width + 48, height: 340) { window, host in
                    try await UI.wait { UI.contains("1,391 min", in: host) }
                    let bounds = window.convertToScreen(host.convert(host.bounds, to: nil))
                    let elements = UI.elements(in: host)
                    let first = try #require(elements.first { $0.text == "1,391 min" })
                    let second = try #require(elements.first { $0.text == "263995" })
                    let third = try #require(elements.first { $0.text == "3473 min" })
                    let fourth = try #require(elements.first { $0.text == "108 wpm" })
                    let activity = try #require(elements.first { $0.text == "97%" })
                    #expect(first.frame.minX > activity.frame.maxX)
                    #expect(abs(first.frame.midY - second.frame.midY) < 1)
                    #expect(abs(third.frame.midY - fourth.frame.midY) < 1)
                    #expect(first.frame.minY > third.frame.maxY)
                    for value in [first, second, third, fourth] {
                        #expect(value.frame.height <= 25, "Metric values occupy one line")
                        #expect(value.frame.minX >= bounds.minX && value.frame.maxX <= bounds.maxX)
                    }
                    for title in ["home.metric.totalDictation", "home.metric.charactersDictated",
                                  "home.metric.timeSaved", "home.metric.averagePace", "home.activity.privacy"] {
                        let text = try #require(elements.first { $0.text == L(title) })
                        #expect(text.frame.minX >= bounds.minX && text.frame.maxX <= bounds.maxX)
                        #expect(text.frame.minY > bounds.minY)
                    }
                    for (key, value) in zip(["home.metric.totalDictation", "home.metric.charactersDictated",
                                              "home.metric.timeSaved", "home.metric.averagePace"],
                                             [first, second, third, fourth]) {
                        let title = try #require(elements.first { $0.text == L(key) })
                        #expect(title.frame.maxY <= value.frame.minY, "Titles do not overlap their values")
                        #expect(title.frame.height <= 30)
                    }
                    let recent = try #require(elements.first { $0.text == L("home.recentTranscriptions") })
                    #expect(recent.frame.maxY < third.frame.minY)
                    try UI.snapshot(host, name: "overview-\(language.rawValue)-\(Int(windowWidth))")
                }
            }
        }
    }

    @Test func `large accumulated values stay on one line in the narrowest content`() async throws {
        try await UI.withFixture { _ in
            let width = StudioShellLayout(width: 1040).contentWidth
            let panel = StudioOverviewPanel(width: width, completionRate: 100,
                                            transcriptionMinutesText: "999,999", totalCharacters: 99999999,
                                            savedMinutes: 999999, averagePaceWPM: 999)
            try await UI.withWindow(panel, width: width, height: 260) { _, host in
                try await UI.wait { UI.contains("999,999 min", in: host) }
                for text in ["999,999 min", "99999999", "999999 min", "999 wpm"] {
                    let value = try #require(UI.elements(in: host).first { $0.text == text })
                    #expect(value.frame.height <= 25)
                    #expect(value.frame.width > 0)
                }
                try UI.snapshot(host, name: "overview-large-values")
            }
        }
    }
}
