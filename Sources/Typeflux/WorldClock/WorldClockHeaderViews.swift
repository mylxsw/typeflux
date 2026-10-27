import SwiftUI

/// The keyword chip, naming what the input is read as: "World Clock → Convert".
struct WorldClockKeywordChip: View {
    @ObservedObject var model: WorldClockLauncherModel

    var body: some View {
        AskKeywordChip(title: L("worldclock.title"), symbol: "globe", detail: detail, tint: AskTheme.accent,
                       keyword: .init(keyword: "tz", pluginID: AskWorldClockPlugin.id))
    }

    private var detail: String? {
        switch model.query {
        case .list: nil
        case .search, .unknown: L("worldclock.mode.search")
        case .convert: L("worldclock.mode.convert")
        case .meeting: L("worldclock.mode.meeting")
        case .timestamp: L("worldclock.mode.timestamp")
        }
    }
}

/// The hint row's times, refreshed every minute while it is visible.
struct WorldClockHintSummary: View {
    var options: [String: String]

    var body: some View {
        TimelineView(.everyMinute) { context in
            Text(AskWorldClockPlugin.summary(options: options, now: context.date,
                                             language: AppLocalization.shared.language))
                .font(.system(size: 11)).foregroundStyle(StudioTheme.textTertiary).lineLimit(1)
        }
    }
}
