import SwiftUI

extension CalendarLauncherView {
    func intervalView(_ interval: HolidaySchedule.Interval) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if case let .range(start, end) = model.query {
                Text(model.dates.format(start, "yMMMEd", locale: model.locale) + "\n→ "
                    + model.dates.format(end, "yMMMEd", locale: model.locale))
                    .font(.system(size: 10.5)).foregroundStyle(StudioTheme.textTertiary)
            }
            Text(L("calendar.interval")).font(.system(size: 11)).foregroundStyle(StudioTheme.textTertiary)
            Text(L("calendar.days", interval.days)).font(.system(size: 34, weight: .bold))
            Text(L("calendar.weeksDays", interval.days / 7, interval.days % 7)).font(.system(size: 12))
            Text(L("calendar.months", Double(interval.days) / 30.4375)).font(.system(size: 11))
            Text(L("calendar.inclusive", interval.inclusive)).font(.system(size: 11))
                .foregroundStyle(StudioTheme.textSecondary)
            Text(L("calendar.workingResting", interval.working, interval.resting)).font(.system(
                size: 13,
                weight: .semibold
            ))
            if !interval.estimatedYears.isEmpty {
                Text(L("calendar.estimated", interval.estimatedYears.map(String.init).joined(separator: ", ")))
                    .font(.system(size: 10)).foregroundStyle(.orange).lineLimit(3)
            } else if !model.preferences.showsHolidays {
                Text(L("calendar.weekendsOnly")).font(.system(size: 10)).foregroundStyle(StudioTheme.textTertiary)
            }
            HStack(spacing: 8) {
                Button(L("calendar.copyDays")) { onEffect(.copy(L("calendar.days", interval.days))) }
                    .buttonStyle(.borderedProminent).tint(.blue).controlSize(.mini)
                Button(L("calendar.copyWorking")) { onEffect(.copy(L("calendar.working", interval.working))) }
                    .buttonStyle(.bordered).controlSize(.mini)
            }
        }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(StudioTheme.textPrimary)
    }
}
