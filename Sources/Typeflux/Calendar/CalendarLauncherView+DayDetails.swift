import SwiftUI

extension CalendarLauncherView {
    @ViewBuilder var detail: some View {
        if let interval = model.interval {
            intervalView(interval).padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AskTheme.hoverFill, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(AskTheme.separator))
        } else {
            dayDetail
        }
    }

    private var dayDetail: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(model.dates.format(model.selected, "MMMd", locale: model.locale)).font(.system(
                    size: 23,
                    weight: .bold
                ))
                Text(model.dates.format(model.selected, "EEE", locale: model.locale)).font(.system(size: 11))
                if model.selected == model.today {
                    Text(L("calendar.today")).font(.system(size: 10, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 5).padding(.vertical, 2).background(
                            .red,
                            in: RoundedRectangle(cornerRadius: 4)
                        )
                }
            }
            if model.dates.calendar.component(.year, from: model.selected) != model.dates.calendar.component(
                .year,
                from: model.today
            ) {
                Text(String(model.dates.calendar.component(.year, from: model.selected))).font(.system(size: 12))
            }
            Text((model.preferences.showsLunar ? L("calendar.lunar", model.info.lunar) + " · " : "")
                + L("calendar.weekDay", model.info.week, model.info.ordinal))
                .font(.system(size: 10.5)).foregroundStyle(StudioTheme.textTertiary)
            if model.selected != model.today {
                Text(L(model.selected > model.today ? "calendar.after" : "calendar.before",
                       abs(model.dates.days(from: model.today, to: model.selected))))
                    .font(.system(size: 11)).foregroundStyle(.blue)
            }
            holidayDetail
            if case .invalid = model.query {
                Text(L("calendar.invalid")).font(.system(size: 12)).foregroundStyle(.orange)
            }
            Divider().padding(.vertical, 4)
            if model.preferences.showsEvents {
                agenda
            }
            Spacer(minLength: 0)
        }.frame(height: 346, alignment: .top)
    }

    @ViewBuilder private var holidayDetail: some View {
        if model.preferences.showsHolidays {
            if let status = model.holidays.status(on: model.selected, dates: model.dates) {
                Text(status.working ? L("calendar.workday") : L(
                    "calendar.holidayDetail",
                    L(status.name),
                    status.day,
                    status.total
                ))
                .font(.system(size: 10.5)).foregroundStyle(status.working ? .orange : .green)
            } else {
                let year = model.dates.calendar.component(.year, from: model.selected)
                let nextYear = model.holidays.years[String(year)] == nil ? year : year + 1
                if model.holidays.years[String(year)] == nil {
                    Text(L(year > model.dates.calendar.component(.year, from: model.today)
                            ? "calendar.unpublished" : "calendar.unavailable", String(year)))
                        .font(.system(size: 10)).foregroundStyle(StudioTheme.textTertiary)
                } else if let (start, name) = model.holidays.nextHoliday(after: model.selected, dates: model.dates) {
                    Text(L("calendar.nextHoliday", L(name), model.dates.days(from: model.selected, to: start)))
                        .font(.system(size: 10.5)).foregroundStyle(StudioTheme.textTertiary)
                } else if model.holidays.years[String(nextYear)] == nil {
                    Text(L(nextYear > model.dates.calendar.component(.year, from: model.today)
                            ? "calendar.unpublished" : "calendar.unavailable", String(nextYear)))
                        .font(.system(size: 10))
                        .foregroundStyle(StudioTheme.textTertiary).padding(.horizontal, 6).padding(.vertical, 3)
                        .background(AskTheme.hoverFill, in: RoundedRectangle(cornerRadius: 4))
                }
            }
        }
        if model.preferences.showsLunar, let festival = model.info.festival ?? model.info.solarTerm {
            Text(festival).font(.system(size: 11)).foregroundStyle(.teal)
        }
    }
}
