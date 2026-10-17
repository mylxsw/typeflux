import SwiftUI

/// A fixed six-week grid with a scrollable detail pane, matching the approved launcher design.
struct CalendarLauncherView: View {
    @ObservedObject var model: CalendarLauncherModel
    var onEffect: (CalendarEffect) -> Void
    var onSelect: (Date) -> Void
    var onHideEvents: () -> Void = {}
    var feedback: String?
    static let height: CGFloat = 448
    var viewportHeight: CGFloat = Self.height
    var additionalHeight: CGFloat { max(0, viewportHeight - Self.height) }
    let columns = Array(repeating: GridItem(.flexible(), spacing: 3), count: 7)

    var body: some View {
        VStack(spacing: 0) {
            Divider().overlay(AskTheme.separator)
            VStack(alignment: .leading, spacing: 8) {
                toolbar
                if case let .year(year) = model.query {
                    yearView(year)
                } else if case .search = model.query {
                    searchView
                } else {
                    HStack(alignment: .top, spacing: 28) {
                        monthView.frame(width: 382)
                        detail.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                Spacer(minLength: 0)
            }.padding(.horizontal, 16).padding(.top, 8)
            Divider().overlay(AskTheme.separator)
            Text(feedback ?? keyHint)
                .font(.system(size: 10.5)).foregroundStyle(StudioTheme.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).frame(height: 32)
        }
        .foregroundStyle(StudioTheme.textPrimary)
        .frame(height: viewportHeight, alignment: .top)
        .accessibilityIdentifier("calendar.launcher")
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Button { model.showYear() } label: {
                Text(model.dates.format(
                    model.selected,
                    {
                        if case .year = model.query {
                            "y"
                        } else {
                            "yMMMM"
                        }
                    }(),
                    locale: model.locale
                ))
                .font(.system(size: 17, weight: .bold))
            }.buttonStyle(.plain).accessibilityIdentifier("calendar.year")
            if model.preferences.showsLunar {
                Text(headerZodiac).font(.system(size: 11)).foregroundStyle(StudioTheme.textTertiary)
            }
            Spacer()
            HStack(spacing: 6) {
                Button { onEffect(model.handle(.commandT, inputEmpty: true)) } label: {
                    HStack(spacing: 4) {
                        Text(L("calendar.today"))
                        Text("⌘T").foregroundStyle(StudioTheme.textTertiary)
                    }.padding(.horizontal, 10).frame(height: 26)
                }
                .disabled(model.isAtToday)
                .help(L("calendar.today.help"))
                .accessibilityIdentifier("calendar.today")
                Button { navigate(-1) } label: {
                    Image(systemName: "chevron.left").frame(width: 28, height: 26)
                }
                .help(L("calendar.previous"))
                .accessibilityLabel(L("calendar.previous"))
                .accessibilityIdentifier("calendar.previous")
                Button { navigate(1) } label: {
                    Image(systemName: "chevron.right").frame(width: 28, height: 26)
                }
                .help(L("calendar.next"))
                .accessibilityLabel(L("calendar.next"))
                .accessibilityIdentifier("calendar.next")
            }.font(.system(size: 11.5)).buttonStyle(CalendarToolbarButtonStyle())
        }.frame(height: 30)
    }

    private var keyHint: String {
        switch model.query {
        case .year: L("calendar.keys.year")
        case .range: L("calendar.keys.range")
        case .search: L("calendar.keys.search")
        default: L(model.eventFocus ? "calendar.keys.agenda" : "calendar.keys")
        }
    }

    private func navigate(_ step: Int) {
        if case let .year(year) = model.query {
            model.update(String(max(1901, min(2099, year + step))))
        } else {
            onSelect(model.dates.adding(step, .month, to: model.selected))
        }
    }

    private var headerZodiac: String {
        if case let .year(year) = model.query, let date = model.dates.date(year, 7, 1) {
            return CalendarDayInfo(date, dates: model.dates).zodiac
        }
        return model.info.zodiac
    }

    private var monthView: some View {
        VStack(spacing: 5) {
            HStack(spacing: 3) {
                if model.preferences.showsWeeks {
                    Text("#").frame(width: 20)
                }
                ForEach(0 ..< 7, id: \.self) { index in
                    let day = model.dates.adding((index + model.dates.calendar.firstWeekday + 7
                            - model.dates.calendar.component(.weekday, from: model.month)) % 7, to: model.month)
                    Text(model.dates.format(day, "EEEEE", locale: model.locale)).frame(maxWidth: .infinity)
                }
            }.font(.system(size: 10.5, weight: .semibold)).foregroundStyle(StudioTheme.textTertiary).frame(height: 17)
            let grid = model.dates.grid(model.month)
            ForEach(0 ..< 6, id: \.self) { row in
                HStack(spacing: 3) {
                    if model.preferences.showsWeeks {
                        Text(String(CalendarDayInfo(grid[row * 7], dates: model.dates).week))
                            .font(.system(size: 9)).foregroundStyle(StudioTheme.textTertiary).frame(width: 20)
                    }
                    ForEach(Array(grid[row * 7 ..< row * 7 + 7]), id: \.self) { day in dayCell(day) }
                }
            }
            legend.padding(.top, 5)
        }
    }

    private func dayCell(_ day: Date) -> some View {
        let dates = model.dates, info = CalendarDayInfo(day, dates: dates)
        let selected = dates.calendar.isDate(day, inSameDayAs: model.selected)
        let today = dates.calendar.isDate(day, inSameDayAs: model.today)
        let holiday = model.preferences.showsHolidays ? model.holidays.status(on: day, dates: dates) : nil
        let inMonth = dates.calendar.isDate(day, equalTo: model.month, toGranularity: .month)
        let colors = Array(Set(model.events.filter { $0.occurs(on: day, dates: dates) }.map(\.calendar.color))).sorted()
        let label = holiday?.day == 1 ? L(holiday?.name ?? "") : info.festival ?? info.solarTerm ?? info.lunarDay
        let inRange: Bool = {
            guard case let .range(first, last) = model.query else { return false }
            return min(first, last) <= day && day <= max(first, last)
        }()
        return Button { onSelect(day) } label: {
            VStack(spacing: 0) {
                Text(String(dates.calendar.component(.day, from: day)))
                    .font(.system(size: 14, weight: today ? .bold : .medium))
                    .foregroundStyle(today ? .white : StudioTheme.textPrimary)
                    .frame(width: 23, height: 23).background(today ? AskTheme.accent : .clear, in: Circle())
                if model.preferences.showsLunar || holiday != nil {
                    Text(label).font(.system(size: 9.5)).lineLimit(1)
                        .foregroundStyle(info.festival != nil || info.solarTerm != nil ? Color.teal : StudioTheme
                            .textTertiary)
                }
                HStack(spacing: 3) {
                    ForEach(Array(colors.prefix(3)), id: \.self) { color in Circle().fill(tint(color)).frame(
                        width: 3,
                        height: 3
                    ) }
                }.frame(height: 5)
            }.frame(maxWidth: .infinity).frame(height: 48 + additionalHeight / 6)
                .background(holiday.map { ($0.working ? Color.orange : Color.green).opacity(0.12) }
                    ?? (inRange ? Color.blue.opacity(0.12) : .clear), in: RoundedRectangle(cornerRadius: 9))
                .overlay(alignment: .topTrailing) {
                    if let holiday {
                        Text(L(holiday.working ? "calendar.workBadge" : "calendar.restBadge"))
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(holiday.working ? Color.orange : Color.green).padding(3)
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(selected ? AskTheme.accent : .clear, lineWidth: 1.5))
                .opacity(inMonth ? 1 : 0.35)
        }.buttonStyle(.plain)
            .onTapGesture(count: 2) { onEffect(.open(day, event: nil, join: false)) }
            .accessibilityLabel(model.dates
                .format(day, "yMMMEd", locale: model.locale) + (holiday.map { ", " + L($0.name) } ?? ""))
            .accessibilityIdentifier("calendar.day." + dates.key(day))
    }

    private var legend: some View {
        HStack(spacing: 8) {
            if model.preferences.showsHolidays {
                Label(L("calendar.rest"), systemImage: "square").foregroundStyle(.green)
                Label(L("calendar.work"), systemImage: "square").foregroundStyle(.orange)
            }
            ForEach(Array(model.sources.filter { source in
                model.events.contains { $0.calendar.id == source.id }
            }.prefix(3))) { source in
                HStack(spacing: 3) {
                    Circle().fill(tint(source.color)).frame(width: 6, height: 6); Text(source.title).lineLimit(1)
                }
            }
        }.font(.system(size: 9.5)).foregroundStyle(StudioTheme.textTertiary).frame(
            maxWidth: .infinity,
            alignment: .leading
        )
    }

    func tint(_ hex: String) -> Color {
        let value = UInt32(hex, radix: 16) ?? 0x4088FF
        return Color(red: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255,
                     blue: Double(value & 255) / 255)
    }
}
