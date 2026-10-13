import SwiftUI

/// Metrics stay in a grouped form and use system text styles at every window size.
struct OverviewSettingsMetrics: View {
    let completionRate: Int
    let transcriptionMinutesText: String
    let totalCharacters: Int
    let savedMinutes: Int
    let averagePaceWPM: Int

    var body: some View {
        TypefluxFormSection(L("home.activity.title"), footer: L("home.activity.privacy")) {
            metric(L("home.activity.completionRate"), value: "\(min(100, max(0, completionRate)))%")
            metric(L("home.metric.totalDictation"), value: "\(transcriptionMinutesText) min")
            metric(L("home.metric.charactersDictated"), value: "\(totalCharacters)")
            metric(L("home.metric.timeSaved"), value: "\(savedMinutes) min")
            metric(L("home.metric.averagePace"), value: averagePaceWPM > 0 ? "\(averagePaceWPM) wpm" : "--")
        }
    }

    private func metric(_ title: String, value: String) -> some View {
        TypefluxSettingsRow(title) {
            Text(value).font(.largeTitle).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                .textSelection(.enabled)
        }
    }
}
