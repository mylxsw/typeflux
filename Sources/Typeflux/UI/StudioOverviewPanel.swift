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

        return StudioCard(padding: StudioTheme.Insets.cardDense) {
            VStack(alignment: .leading, spacing: StudioTheme.Spacing.small) {
                HStack(
                    alignment: .center,
                    spacing: StudioTheme.Spacing.smallMedium
                ) {
                    VStack(alignment: .leading, spacing: StudioTheme.Spacing.small) {
                        HStack(spacing: StudioTheme.Spacing.small) {
                            RoundedRectangle(
                                cornerRadius: StudioTheme.CornerRadius.medium, style: .continuous
                            )
                            .fill(StudioTheme.iconTileSurface)
                            .frame(
                                width: StudioTheme.ControlSize.overviewBadge,
                                height: StudioTheme.ControlSize.overviewBadge
                            )
                            .overlay(
                                Image(systemName: "waveform.and.magnifyingglass")
                                    .font(
                                        .system(
                                            size: StudioTheme.Typography.iconSmall,
                                            weight: .semibold
                                        )
                                    )
                                    .foregroundStyle(StudioTheme.accent)
                            )

                            Text(L("home.activity.title"))
                                .font(
                                    .studioBody(StudioTheme.Typography.bodySmall, weight: .semibold)
                                )
                                .foregroundStyle(StudioTheme.textSecondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.85)
                        }

                        Text("\(completionRate)%")
                            .font(.studioDisplay(StudioTheme.Typography.displayLarge, weight: .bold))
                            .foregroundStyle(StudioTheme.textPrimary)
                            .minimumScaleFactor(0.72)
                            .lineLimit(1)

                        Text(L("home.activity.completionRate"))
                            .font(.studioBody(StudioTheme.Typography.body))
                            .foregroundStyle(StudioTheme.textSecondary)
                            .lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Circle()
                        .stroke(
                            StudioTheme.controlSurface,
                            lineWidth: donutLineWidth
                        )
                        .frame(
                            width: donutSize,
                            height: donutSize
                        )
                        .overlay(
                            Circle()
                                .trim(from: 0, to: CGFloat(completionRate) / 100)
                                .stroke(
                                    LinearGradient(
                                        colors: [
                                            StudioTheme.accent.opacity(0.52),
                                            StudioTheme.accent.opacity(StudioTheme.Opacity.overviewProgress)
                                        ],
                                        startPoint: .bottomLeading,
                                        endPoint: .topTrailing
                                    ),
                                    style: StrokeStyle(
                                        lineWidth: donutLineWidth,
                                        lineCap: .round
                                    )
                                )
                                .rotationEffect(.degrees(StudioTheme.Angles.overviewProgressStart))
                        )
                }

                Spacer(minLength: StudioTheme.Spacing.smallMedium)

                Text(L("home.activity.privacy"))
                    .font(.studioBody(StudioTheme.Typography.caption))
                    .foregroundStyle(StudioTheme.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func metricsGrid(width: CGFloat) -> some View {
        let spacing = StudioTheme.Spacing.large
        let cardWidth = max((width - spacing) / 2, 0)
        let cardHeight = max((StudioTheme.Layout.overviewPrimaryMinHeight - spacing) / 2, 0)

        return VStack(spacing: spacing) {
            HStack(spacing: spacing) {
                metricCard(
                    icon: "clock",
                    value: "\(transcriptionMinutesText) min",
                    title: L("home.metric.totalDictation"),
                    size: CGSize(width: cardWidth, height: cardHeight)
                )
                metricCard(
                    icon: "mic",
                    value: "\(totalCharacters)",
                    title: L("home.metric.charactersDictated"),
                    size: CGSize(width: cardWidth, height: cardHeight)
                )
            }

            HStack(spacing: spacing) {
                metricCard(
                    icon: "hourglass",
                    value: "\(savedMinutes) min",
                    title: L("home.metric.timeSaved"),
                    size: CGSize(width: cardWidth, height: cardHeight)
                )
                metricCard(
                    icon: "bolt",
                    value: averagePaceWPM > 0
                        ? "\(averagePaceWPM) wpm" : "--",
                    title: L("home.metric.averagePace"),
                    size: CGSize(width: cardWidth, height: cardHeight)
                )
            }
        }
        .frame(
            width: width,
            height: StudioTheme.Layout.overviewPrimaryMinHeight,
            alignment: .top
        )
    }

    private func metricCard(icon: String, value: String, title: String, size: CGSize)
        -> some View {
        StudioCard(padding: StudioTheme.Spacing.smallMedium) {
            VStack(alignment: .center, spacing: StudioTheme.Spacing.xxSmall) {
                RoundedRectangle(
                    cornerRadius: StudioTheme.CornerRadius.miniMetricIcon, style: .continuous
                )
                .fill(StudioTheme.iconTileSurface)
                .frame(
                    width: StudioTheme.ControlSize.overviewMiniIcon,
                    height: StudioTheme.ControlSize.overviewMiniIcon
                )
                .overlay(
                    Image(systemName: icon)
                        .font(.system(size: StudioTheme.Typography.iconXSmall, weight: .semibold))
                        .foregroundStyle(StudioTheme.accent)
                )

                Text(value)
                    .font(.studioDisplay(StudioTheme.Typography.sectionTitle, weight: .bold))
                    .foregroundStyle(StudioTheme.textPrimary)
                    .multilineTextAlignment(.center)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                Text(title)
                    .font(.studioBody(StudioTheme.Typography.bodySmall))
                    .foregroundStyle(StudioTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                    .frame(height: 30, alignment: .top)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        .frame(width: size.width, height: size.height, alignment: .center)
    }
}
