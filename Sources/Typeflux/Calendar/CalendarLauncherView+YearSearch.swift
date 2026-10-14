import SwiftUI

extension CalendarLauncherView {
    // The twelve month cards share one layout and selection state.
    // swiftlint:disable:next function_body_length
    func yearView(_ year: Int) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            if model.preferences.showsHolidays, model.holidays.years[String(year)] == nil {
                Text(L(year > model.dates.calendar.component(.year, from: model.today)
                        ? "calendar.unpublished" : "calendar.unavailable", String(year)))
                    .font(.system(size: 11)).foregroundStyle(.orange)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 8) {
                ForEach(1 ... 12, id: \.self) { month in
                    if let day = model.dates.date(year, month, 1) {
                        Button { onSelect(day) } label: {
                            VStack(spacing: 3) {
                                HStack {
                                    Text(model.dates.format(day, "MMM", locale: model.locale)).font(.system(
                                        size: 10.5,
                                        weight: .semibold
                                    ))
                                    Spacer()
                                    if model.preferences.showsHolidays, model.holidays.years[String(year)] != nil {
                                        Text(L("calendar.restCount", model.dates.grid(day).filter {
                                            model.dates.calendar.isDate($0, equalTo: day, toGranularity: .month)
                                                && model.holidays.status(on: $0, dates: model.dates)?.working == false
                                        }.count)).font(.system(size: 9.5)).foregroundStyle(.green)
                                    }
                                }
                                LazyVGrid(columns: columns, spacing: 0) {
                                    ForEach(0 ..< 7, id: \.self) { index in
                                        let grid = model.dates.grid(day)
                                        Text(model.dates.format(grid[index], "EEEEE", locale: model.locale))
                                            .font(.system(size: 8)).foregroundStyle(StudioTheme.textTertiary)
                                    }
                                    ForEach(model.dates.grid(day), id: \.self) { date in
                                        let holiday = model.preferences.showsHolidays ? model.holidays.status(
                                            on: date,
                                            dates: model.dates
                                        ) : nil
                                        Text(String(model.dates.calendar.component(.day, from: date)))
                                            .font(.system(size: 9.5))
                                            .foregroundStyle(holiday.map { $0.working ? Color.orange : .green }
                                                ??
                                                (model.dates.calendar
                                                    .isDate(date, inSameDayAs: model.today) ||
                                                    (model.preferences.showsLunar
                                                        && CalendarDayInfo(date, dates: model.dates).festival != nil) ?
                                                    .red : StudioTheme
                                                    .textSecondary))
                                            .opacity(model.dates.calendar.isDate(
                                                date,
                                                equalTo: day,
                                                toGranularity: .month
                                            ) ? 1 : 0)
                                    }
                                }
                            }.padding(7).frame(height: 108)
                                .background(AskTheme.hoverFill, in: RoundedRectangle(cornerRadius: 8))
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(
                                    model.dates.calendar
                                        .isDate(day, equalTo: model.month, toGranularity: .month) ? Color
                                        .blue : .clear
                                ))
                        }.buttonStyle(.plain).accessibilityIdentifier("calendar.month.\(month)")
                    }
                }
            }
        }
    }

    var searchView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("calendar.searchWindow")).font(.system(size: 11)).foregroundStyle(StudioTheme.textTertiary)
            if !model.preferences.showsEvents {
                Text(L("calendar.settings.eventsDisabled")).font(.system(size: 12))
                    .foregroundStyle(StudioTheme.textSecondary)
            } else if model.access != .allowed {
                permission.frame(width: 280)
            } else if model.loading {
                ProgressView()
            } else if model.searchEvents.isEmpty {
                Text(L("calendar.noResults")).font(.system(size: 13)).foregroundStyle(StudioTheme.textSecondary)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 7) {
                            ForEach([false, true], id: \.self) { past in
                                let rows = model.searchEvents.filter { ($0.end <= model.now()) == past }
                                if !rows.isEmpty {
                                    Text(L(past ? "calendar.past" : "calendar.upcoming")).font(.system(
                                        size: 11,
                                        weight: .semibold
                                    ))
                                    ForEach(rows) { event in
                                        VStack(alignment: .leading, spacing: 0) {
                                            Text(model.dates.format(event.start, "yMMMEd", locale: model.locale))
                                                .font(.system(size: 10)).foregroundStyle(StudioTheme.textTertiary)
                                                .padding(
                                                    .leading,
                                                    9
                                                )
                                            eventRow(event)
                                        }.id(event.id)
                                    }
                                }
                            }
                        }
                    }.onChange(of: model.selectedEventID) { id in
                        guard let id else { return }
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
        }.frame(height: 347, alignment: .top)
    }
}
