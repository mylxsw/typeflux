import Foundation
import SwiftUI

/// `tz`: the local time and the user's cities, time conversion, meeting times and timestamps.
/// The launcher shows `WorldClockLauncherView` in place of plugin results; see
/// `docs/design/launcher-world-clock.md`.
struct AskWorldClockPlugin: AskLauncherPlugin {
    static let id = "worldclock"
    static let keywords = [AskKeyword(keyword: "tz", pluginID: id, aliases: ["时间", "时区", "世界时钟"])]
    var id: String {
        Self.id
    }

    var title: String {
        L("worldclock.title")
    }

    var symbol: String {
        "globe"
    }

    var keywordColor: Color {
        AskTheme.accent
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
        L("worldclock.placeholder")
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
                        source: L("worldclock.local.source"), actions: [])
    }

    func nextOptions(after _: AskPluginPlan, request _: AskPluginRequest, step _: Int) -> [String: String]? {
        nil
    }

    /// The hint row: "Beijing 18:24 · San Francisco 03:24 · New York 06:24".
    static func summary(options: [String: String], now: Date = Date(), language: AppLanguage,
                        localZone: TimeZone = .autoupdatingCurrent,
                        directory: WorldCityDirectory = .shared) -> String {
        let preferences = WorldClockPreferences(options: options, localZone: localZone)
        let local = directory.representative(of: localZone)
            ?? directory.city(id: WorldClockCity.zonePrefix + localZone.identifier)
        let presenter = WorldClockPresenter(preferences: preferences, language: language, now: now,
                                            localZone: localZone, localName: local?.name(in: language) ?? "")
        let cities = preferences.cityIDs.compactMap { directory.city(id: $0) }.filter { $0.id != local?.id }
        return ((local.map { [$0] } ?? []) + cities.prefix(preferences.hintCount))
            .map { presenter.line($0, at: now, format: .city) }
            .joined(separator: " · ")
    }
}
