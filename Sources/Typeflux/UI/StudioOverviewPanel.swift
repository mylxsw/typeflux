import SwiftUI

struct StudioOverviewPanelLayout: Equatable {
    let activityWidth: CGFloat
    let metricsWidth: CGFloat
    let height: CGFloat
    let donutSize: CGFloat
}

enum StudioOverviewPanelLayoutCalculator {
    static func layout(for availableWidth: CGFloat) -> StudioOverviewPanelLayout {
        let width = max(availableWidth, 0)
        let spacing = StudioTheme.Spacing.large
        let metricsWidth = min(StudioTheme.Layout.overviewSideMetricsWidth, max((width - spacing) * 0.46, 0))
        let activityWidth = max(width - metricsWidth - spacing, 0)

        return StudioOverviewPanelLayout(
            activityWidth: activityWidth,
            metricsWidth: metricsWidth,
            height: StudioTheme.Layout.overviewPrimaryMinHeight,
            donutSize: min(154, max(104, activityWidth * 0.30))
        )
    }
}

struct StudioOverviewPanel: View {
    let width: CGFloat
    let completionRate: Int
    let transcriptionMinutesText: String
    let totalCharacters: Int
    let savedMinutes: Int
    let averagePaceWPM: Int

    var body: some View {
        let layout = StudioOverviewPanelLayoutCalculator.layout(for: width)
        HStack(alignment: .top, spacing: StudioTheme.Spacing.large) {
            activityCard(donutSize: layout.donutSize)
                .frame(width: layout.activityWidth, height: layout.height)
            metricsGrid(width: layout.metricsWidth)
        }
        .frame(width: width, height: layout.height, alignment: .topLeading)
    }

    private func activityCard(donutSize: CGFloat) -> some View {
        let donutLineWidth = donutSize * 0.12

        return TFCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            TFIconTile(systemImage: "waveform.and.magnifyingglass", style: .soft)
                            Text(L("home.activity.title"))
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(TFColors.textSecondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.85)
                        }
                        Text("\(completionRate)%")
                            .font(.system(size: 32, weight: .bold).monospacedDigit())
                            .foregroundStyle(TFColors.textPrimary)
                            .minimumScaleFactor(0.72)
                            .lineLimit(1)
                        Text(L("home.activity.completionRate"))
                            .font(.system(size: 13))
                            .foregroundStyle(TFColors.textSecondary)
                            .lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Circle()
                        .stroke(TFColors.control, lineWidth: donutLineWidth)
                        .frame(width: donutSize, height: donutSize)
                        .overlay(
                            Circle()
                                .trim(from: 0, to: CGFloat(completionRate) / 100)
                                .stroke(TFColors.accent,
                                        style: StrokeStyle(lineWidth: donutLineWidth, lineCap: .round))
                                .rotationEffect(.degrees(StudioTheme.Angles.overviewProgressStart))
                        )
                        .accessibilityHidden(true)
                }
                Spacer(minLength: 12)
                TFFootnote(text: L("home.activity.privacy"))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(18)
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    private func metricsGrid(width: CGFloat) -> some View {
        let spacing = StudioTheme.Spacing.large
        let cardWidth = max((width - spacing) / 2, 0)
        let cardHeight = max((StudioTheme.Layout.overviewPrimaryMinHeight - spacing) / 2, 0)
        let size = CGSize(width: cardWidth, height: cardHeight)

        return VStack(spacing: spacing) {
            HStack(spacing: spacing) {
                metricCard(icon: "clock", value: "\(transcriptionMinutesText) min",
                           title: L("home.metric.totalDictation"), size: size)
                metricCard(icon: "mic", value: "\(totalCharacters)",
                           title: L("home.metric.charactersDictated"), size: size)
            }
            HStack(spacing: spacing) {
                metricCard(icon: "hourglass", value: "\(savedMinutes) min",
                           title: L("home.metric.timeSaved"), size: size)
                metricCard(icon: "bolt", value: averagePaceWPM > 0 ? "\(averagePaceWPM) wpm" : "--",
                           title: L("home.metric.averagePace"), size: size)
            }
        }
        .frame(width: width, height: StudioTheme.Layout.overviewPrimaryMinHeight, alignment: .top)
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
