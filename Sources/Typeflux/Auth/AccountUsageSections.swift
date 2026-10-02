import AppKit
import SwiftUI

/// Four tiles for the period: voice input, text produced, AI requests and the
/// time saved (the last one is this Mac's own count).
struct AccountUsageMetricsGrid: View {
    let stats: CloudUsageStats
    let savedMinutes: Int

    var body: some View {
        HStack(spacing: StudioTheme.Spacing.small) {
            metric(symbol: "waveform", tint: StudioTheme.accent, title: L("account.card.voice"),
                   value: L("account.card.times", AccountUsageDisplayFormatter.count(stats.asrCount)),
                   detail: L("account.page.voiceDetail",
                             AccountUsageDisplayFormatter.audioDuration(stats.asrAudioDurationMs)))
            metric(symbol: "text.cursor", tint: .purple, title: L("account.page.text"),
                   value: L("account.page.chars",
                            AccountUsageDisplayFormatter.count(stats.asrOutputChars + stats.chatOutputChars)),
                   detail: L("account.page.textDetail"))
            metric(symbol: "sparkles", tint: .teal, title: L("account.card.aiRequests"),
                   value: L("account.card.times", AccountUsageDisplayFormatter.count(stats.chatCount)),
                   detail: L("account.page.tokens", AccountUsageDisplayFormatter.count(stats.chatTotalTokens)))
            metric(symbol: "clock", tint: StudioTheme.success, title: L("account.page.saved"),
                   value: savedMinutes > 0
                       ? AccountUsageDisplayFormatter.audioDuration(Int64(savedMinutes) * 60000) : "—",
                   detail: L("account.page.savedDetail"))
        }
    }

    private func metric(symbol: String, tint: Color, title: String, value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 18, height: 18)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(tint.opacity(0.15)))
                Text(title)
                    .font(.studioBody(StudioTheme.Typography.caption, weight: .medium))
                    .foregroundStyle(StudioTheme.textSecondary)
                    .lineLimit(1)
            }
            Text(value)
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(StudioTheme.textPrimary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.top, 8)
            Text(detail)
                .font(.studioBody(StudioTheme.Typography.caption))
                .foregroundStyle(StudioTheme.textTertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(StudioTheme.surface))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(StudioTheme.border))
        .accessibilityElement(children: .combine)
    }
}

/// The period's daily credit bars and where the credits went, by feature.
struct AccountCreditBreakdownView: View {
    let breakdown: CloudUsageBreakdown
    @ObservedObject private var localization = AppLocalization.shared

    var body: some View {
        HStack(alignment: .top, spacing: StudioTheme.Spacing.small) {
            box(title: L("account.page.dailyTitle"), hint: L("account.page.dailyHint")) { daily }
                .frame(maxWidth: .infinity)
            box(title: L("account.page.featureTitle"), hint: L("account.page.featureHint")) { features }
                .frame(width: 270)
        }
    }

    private var daily: some View {
        let bars = AccountCreditChart.bars(breakdown)
        let peak = max(1, bars.map(\.credits).max() ?? 1)
        let calendar = AccountCreditChart.calendar(for: breakdown)
        return VStack(spacing: 5) {
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(Array(bars.enumerated()), id: \.offset) { _, bar in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(bar.isFuture || bar.credits == 0 ? AnyShapeStyle(AskAccountTone.chip)
                            : AnyShapeStyle(StudioTheme.accent.opacity(bar.isToday ? 1 : 0.8)))
                        .frame(height: bar.isFuture || bar.credits == 0
                            ? 3 : max(4, 86 * CGFloat(bar.credits) / CGFloat(peak)))
                        .frame(maxWidth: .infinity)
                        .help("\(day(bar.day, calendar)): \(AccountUsageDisplayFormatter.creditAmount(bar.credits))")
                }
            }
            .frame(height: 92, alignment: .bottom)
            .accessibilityElement()
            .accessibilityLabel(L("account.page.dailyTitle"))
            .accessibilityValue(bars.filter { $0.credits > 0 }
                .map { "\(day($0.day, calendar)) \(AccountUsageDisplayFormatter.creditAmount($0.credits))" }
                .joined(separator: ", "))
            axis(bars, calendar: calendar)
                .font(.system(size: 10.5))
                .foregroundStyle(StudioTheme.textTertiary)
        }
    }

    /// First and last day at the ends, "Today" under today's bar when it
    /// does not collide with either end label.
    private func axis(_ bars: [AccountCreditChart.Bar], calendar: Calendar) -> some View {
        HStack {
            if let first = bars.first { Text(day(first.day, calendar)) }
            Spacer()
            if let last = bars.last { Text(day(last.day, calendar)) }
        }
        .overlay {
            GeometryReader { proxy in
                if let index = bars.firstIndex(where: \.isToday),
                   let center = AccountCreditChart.todayLabelCenter(index: index, count: bars.count,
                                                               width: proxy.size.width, clearance: 56) {
                    Text(L("account.page.today"))
                        .fixedSize()
                        .position(x: center, y: proxy.size.height / 2)
                }
            }
        }
    }

    private var features: some View {
        let shares = AccountCreditChart.shares(breakdown)
        return VStack(alignment: .leading, spacing: 9) {
            if shares.isEmpty {
                Text(L("account.page.noUsage"))
                    .font(.studioBody(StudioTheme.Typography.bodySmall))
                    .foregroundStyle(StudioTheme.textTertiary)
                    .frame(maxWidth: .infinity, minHeight: 92, alignment: .center)
            } else {
                ForEach(shares, id: \.feature) { share in
                    HStack(spacing: 8) {
                        Text(Self.title(share.feature))
                            .font(.studioBody(StudioTheme.Typography.bodySmall))
                            .foregroundStyle(StudioTheme.textSecondary)
                            .lineLimit(1)
                            .frame(width: 74, alignment: .leading)
                        AskAccountProgressBar(progress: share.fraction, color: Self.color(share.feature))
                            .frame(height: 8)
                        Text(AccountStatusText.percent(share.fraction))
                            .font(.studioBody(StudioTheme.Typography.bodySmall))
                            .foregroundStyle(StudioTheme.textPrimary)
                            .monospacedDigit()
                            .frame(width: 40, alignment: .trailing)
                    }
                    .help(AccountUsageDisplayFormatter.creditAmount(share.credits))
                    .accessibilityElement(children: .combine)
                }
                Text(L("account.page.featureFootnote"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(StudioTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    static func title(_ feature: AccountCreditChart.Feature) -> String {
        switch feature {
        case .voice: L("account.page.featureVoice")
        case .rewrite: L("account.page.featureRewrite")
        case .ask: L("account.page.featureAsk")
        }
    }

    private static func color(_ feature: AccountCreditChart.Feature) -> Color {
        switch feature {
        case .voice: StudioTheme.accent
        case .rewrite: .purple
        case .ask: .teal
        }
    }

    private func day(_ date: Date, _ calendar: Calendar) -> String {
        AccountStatusText.shortDate(date, locale: localization.locale, timeZone: calendar.timeZone)
    }

    private func box(title: String, hint: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.studioBody(StudioTheme.Typography.body, weight: .semibold))
                    .foregroundStyle(StudioTheme.textPrimary)
                Spacer()
                Text(hint)
                    .font(.system(size: 11))
                    .foregroundStyle(StudioTheme.textTertiary)
            }
            content()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(StudioTheme.surface))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(StudioTheme.border))
    }
}
