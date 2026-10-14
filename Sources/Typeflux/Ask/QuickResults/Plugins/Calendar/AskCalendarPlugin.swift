import Foundation
import SwiftUI

struct AskCalendarPlugin: AskLauncherPlugin {
    static let id = "calendar"
    static let keywords = [AskKeyword(keyword: "cal", pluginID: id, aliases: ["日历", "rl"])]
    var id: String {
        Self.id
    }

    var title: String {
        L("calendar.title")
    }

    var symbol: String {
        "calendar"
    }

    var keywordColor: Color {
        .red
    }

    var defaultKeywords: [AskKeyword] {
        Self.keywords
    }

    var runsWithoutInput: Bool {
        true
    }

    var usesSelectionInput: Bool {
        false
    }

    var entersOnReturn: Bool {
        true
    }

    func placeholder(selectionLines _: Int?) -> String {
        L("calendar.placeholder")
    }

    func chipDetail(for _: AskKeyword, language _: AppLanguage) -> String? {
        nil
    }

    func plan(_: AskPluginRequest) async -> AskPluginPlan {
        AskPluginPlan(mode: .live, title: title, debounce: .zero)
    }

    func run(_ request: AskPluginRequest, plan _: AskPluginPlan,
             progress _: @escaping AskPluginProgress) async throws -> AskPluginOutput {
        AskPluginOutput(body: request.origin == .argument ? request.text : "", original: "", meta: [],
                        source: L("calendar.local"), actions: [])
    }

    func nextOptions(after _: AskPluginPlan, request _: AskPluginRequest, step _: Int) -> [String: String]? {
        nil
    }

    static func summary(now: Date = Date(), language: AppLanguage) -> String {
        let dates = CalendarDates(), info = CalendarDayInfo(now, dates: dates)
        let preferences = CalendarPreferences(language: language)
        return dates.format(now, "MMMdEEE", locale: Locale(identifier: language.localeIdentifier))
            + (preferences.showsLunar ? " · " + L("calendar.lunar", info.lunar) : "") + " · " + L(
                "calendar.week",
                info.week
            )
    }
}
