import AppKit
import SwiftUI

/// The period's daily credit bars and where the credits went, by feature.
struct AccountCreditBreakdownView: View {
    let breakdown: CloudUsageBreakdown
    @ObservedObject private var localization = AppLocalization.shared

    var body: some View {
        VStack(alignment: .leading) {
            box(title: L("account.page.dailyTitle"), hint: L("account.page.dailyHint")) { daily }
                .frame(maxWidth: .infinity)
            box(title: L("account.page.featureTitle"), hint: L("account.page.featureHint")) { features }

        }
    }

    private var daily: some View {
        let bars = AccountCreditChart.bars(breakdown)
        let peak = max(1, bars.map(\.credits).max() ?? 1)
        let calendar = AccountCreditChart.calendar(for: breakdown)
        return VStack(spacing: 5) {
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(Array(bars.enumerated()), id: \.offset) { _, bar in
                    Rectangle()
                        .fill(bar.isFuture || bar.credits == 0 ? AnyShapeStyle(TypefluxColor.controlBackground.color)
                            : AnyShapeStyle(TypefluxColor.accent.color.opacity(bar.isToday ? 1 : 0.8)))
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
                .font(.subheadline)
                .foregroundStyle(TypefluxColor.tertiaryLabel.color)
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
                    .font(.callout)
                    .foregroundStyle(TypefluxColor.tertiaryLabel.color)
                    .frame(maxWidth: .infinity, minHeight: 92, alignment: .center)
            } else {
                ForEach(shares, id: \.feature) { share in
                    HStack(spacing: 8) {
                        Text(Self.title(share.feature))
                            .font(.callout)
                            .foregroundStyle(TypefluxColor.secondaryLabel.color)
                            .lineLimit(1)
                            .frame(width: 74, alignment: .leading)
                        TypefluxProgress(Self.title(share.feature), value: share.fraction).labelsHidden()
                        Text(AccountStatusText.percent(share.fraction))
                            .font(.callout)
                            .foregroundStyle(TypefluxColor.label.color)
                            .monospacedDigit()
                            .frame(width: 40, alignment: .trailing)
                    }
                    .help(AccountUsageDisplayFormatter.creditAmount(share.credits))
                    .accessibilityElement(children: .combine)
                }
                Text(L("account.page.featureFootnote"))
                    .font(.subheadline)
                    .foregroundStyle(TypefluxColor.tertiaryLabel.color)
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

    private func day(_ date: Date, _ calendar: Calendar) -> String {
        AccountStatusText.shortDate(date, locale: localization.locale, timeZone: calendar.timeZone)
    }

    private func box(title: String, hint: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(TypefluxColor.label.color)
                Spacer()
                Text(hint)
                    .font(.subheadline)
                    .foregroundStyle(TypefluxColor.tertiaryLabel.color)
            }
            content()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxHeight: .infinity, alignment: .top)

    }
}
