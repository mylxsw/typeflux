import SwiftUI

struct StudioOverviewPanelLayout: Equatable {
    let cardWidth: CGFloat
    let height: CGFloat
}

enum StudioOverviewPanelLayoutCalculator {
    static func layout(for availableWidth: CGFloat) -> StudioOverviewPanelLayout {
        let spacing = StudioTheme.Spacing.large
        return StudioOverviewPanelLayout(
            cardWidth: max((availableWidth - spacing * 3) / 4, 0),
            height: StudioTheme.Layout.overviewMetricHeight
        )
    }
}

struct StudioOverviewPanel: View {
    let width: CGFloat
    let transcriptionMinutesText: String
    let totalCharacters: Int
    let savedMinutes: Int
    let averagePaceWPM: Int

    var body: some View {
        let layout = StudioOverviewPanelLayoutCalculator.layout(for: width)
        let size = CGSize(width: layout.cardWidth, height: layout.height)
        HStack(spacing: StudioTheme.Spacing.large) {
            metricCard(icon: "clock", value: "\(transcriptionMinutesText) min",
                       title: L("home.metric.totalDictation"), size: size)
            metricCard(icon: "mic", value: "\(totalCharacters)",
                       title: L("home.metric.charactersDictated"), size: size)
            metricCard(icon: "hourglass", value: "\(savedMinutes) min",
                       title: L("home.metric.timeSaved"), size: size)
            metricCard(icon: "bolt", value: averagePaceWPM > 0 ? "\(averagePaceWPM) wpm" : "--",
                       title: L("home.metric.averagePace"), size: size)
        }
        .frame(width: width, height: layout.height, alignment: .topLeading)
    }

    private func metricCard(icon: String, value: String, title: String, size: CGSize) -> some View {
        TFCard {
            VStack(alignment: .center, spacing: 4) {
                TFIconTile(systemImage: icon, style: .soft)
                Text(value)
                    .font(.system(size: 18, weight: .bold).monospacedDigit())
                    .foregroundStyle(TFColors.textPrimary)
                    .multilineTextAlignment(.center)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(title)
                    .font(.system(size: 12))
                    .foregroundStyle(TFColors.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                    .frame(height: 30, alignment: .top)
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        .frame(width: size.width, height: size.height, alignment: .center)
    }
}
