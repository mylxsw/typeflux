import AppKit
import EventKit
import Foundation

enum CalendarEffect: Equatable {
    case unhandled, handled, clearInput, settings
    case copy(String), insert(String)
    case open(Date, event: CalendarEvent?, join: Bool)
}

@MainActor
final class CalendarLauncherModel: ObservableObject {
    @Published private(set) var selected: Date
    @Published private(set) var query: CalendarQuery
    @Published private(set) var events: [CalendarEvent] = []
    @Published private(set) var access: CalendarAccess = .unknown
    @Published private(set) var sources: [CalendarSource] = []
    @Published private(set) var eventFocus = false
    @Published private(set) var selectedEventID: String?
    @Published private(set) var loading = false
    @Published private(set) var requesting = false
    @Published private(set) var error: String?
    @Published private(set) var preferences: CalendarPreferences
    let dates: CalendarDates
    let holidays: HolidaySchedule
    var now: () -> Date
    var provider: any CalendarEventProviding
    var locale: Locale = .current
    var openURL: (URL) -> Bool = { NSWorkspace.shared.open($0) }
    private var task: Task<Void, Never>?
    private var observer: NSObjectProtocol?
    private var generation = 0
    private var active = false

    init(provider: any CalendarEventProviding = EventKitEventProvider(), dates: CalendarDates = .init(),
         holidays: HolidaySchedule = .bundled, now: @escaping () -> Date = Date.init,
         preferences: CalendarPreferences = .init()) {
        self.provider = provider
        self.dates = dates
        self.holidays = holidays
        self.now = now
        self.preferences = preferences
        let initial = dates.calendar.startOfDay(for: now())
        selected = initial
        query = .date(initial)
    }

    deinit {
        task?.cancel()
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    var today: Date {
        dates.calendar.startOfDay(for: now())
    }

    var info: CalendarDayInfo {
        CalendarDayInfo(selected, dates: dates)
    }

    var month: Date {
        dates.monthStart(selected)
    }

    var copiedDate: String {
        preferences.copiedDate(selected, dates: dates, locale: locale)
    }

    func untilEvent(_ event: CalendarEvent) -> String {
        let minutes = max(1, Int(ceil(event.start.timeIntervalSince(now()) / 60)))
        if minutes >= 1440 {
            return L("calendar.startsDays", minutes / 1440)
        }
        if minutes >= 60 {
            return L("calendar.startsHours", minutes / 60, minutes % 60)
        }
        return L("calendar.starts", minutes)
    }

    var dayEvents: [CalendarEvent] {
        CalendarEvent.sorted(events.filter { $0.occurs(on: selected, dates: dates) })
    }

    var searchEvents: [CalendarEvent] {
        guard case let .search(text) = query else { return [] }
        let matches = events.filter { $0.matches(text) }
        return matches.sorted {
            let firstPast = $0.end <= now(), secondPast = $1.end <= now()
            if firstPast != secondPast {
                return !firstPast
            }
            return $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start
        }
    }

    var visibleEvents: [CalendarEvent] {
        if case .search = query {
            searchEvents
        } else {
            dayEvents
        }
    }

    var chosenEvent: CalendarEvent? {
        visibleEvents.first { $0.id == selectedEventID }
    }

    var interval: HolidaySchedule.Interval? {
        guard case let .range(start, end) = query else { return nil }
        return holidays.interval(start, end, dates: dates, enabled: preferences.showsHolidays)
    }

    func activate(text: String, options: [String: String], language: AppLanguage) {
        active = true
        locale = Locale(identifier: language.localeIdentifier)
        preferences = CalendarPreferences(options: options, language: language)
        selected = today
        eventFocus = false
        selectedEventID = nil
        update(text, invalidate: true)
        if observer == nil {
            let changed: @Sendable (Notification) -> Void = { [weak self] _ in
                Task { @MainActor [weak self] in self?.refresh(invalidate: true) }
            }
            observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: nil,
                                                              queue: .main, using: changed)
        }
    }

    func updatePreferences(options: [String: String], language: AppLanguage) {
        preferences = CalendarPreferences(options: options, language: language)
        locale = Locale(identifier: language.localeIdentifier)
        if !preferences.showsEvents {
            eventFocus = false; selectedEventID = nil
        }
        refresh(invalidate: true)
    }

    func close() {
        active = false
        generation += 1
        task?.cancel()
        task = nil
        loading = false
        events = []
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        observer = nil
    }

    func update(_ text: String, invalidate: Bool = false) {
        query = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .date(selected)
            : CalendarQueryParser(today: today, dates: dates).parse(text)
        switch query {
        case let .date(day), let .month(day): selected = day
        case let .year(year): selected = dates
            .date(year, 1, 1) ?? selected
        case let .range(start, _): selected = start
        case .search, .invalid: break
        }
        eventFocus = false
        selectedEventID = nil
        refresh(invalidate: invalidate)
    }

    func select(_ date: Date) {
        guard (1901 ... 2099).contains(dates.calendar.component(.year, from: date)) else { return }
        let changedMonth = dates.monthStart(date) != month
        let wasSearch = isSearch
        selected = dates.calendar.startOfDay(for: date)
        query = .date(selected)
        eventFocus = false
        selectedEventID = nil
        if changedMonth || wasSearch {
            refresh()
        }
    }

    func showYear() {
        query = .year(dates.calendar.component(.year, from: selected)); eventFocus = false
    }

    func selectEvent(_ id: String) {
        guard visibleEvents.contains(where: { $0.id == id }) else { return }
        selectedEventID = id
        eventFocus = true
    }

    func refresh(invalidate: Bool = false) {
        task?.cancel()
        generation += 1
        let token = generation
        guard active, preferences.showsEvents else { events = []; loading = false; return }
        let start: Date, end: Date
        if case .search = query {
            start = dates.adding(-30, to: today)
            end = dates.adding(91, to: today)
        } else {
            start = dates.grid(month)[0]
            end = dates.adding(42, to: start)
        }
        let provider = provider, preferences = preferences
        events = []
        loading = true
        task = Task { [weak self] in
            if invalidate {
                await provider.invalidate()
            }
            let access = await provider.access()
            let sources = access == .allowed ? await provider.sources() : []
            let events = access == .allowed ? await provider.events(from: start, to: end,
                                                                    calendars: preferences.includedCalendars(sources)) :
                []
            guard !Task.isCancelled, let self, active, generation == token else { return }
            self.access = access
            self.sources = sources
            self.events = events
            loading = false
            if let selectedEventID, !visibleEvents.contains(where: { $0.id == selectedEventID }) {
                self.selectedEventID = nil
                eventFocus = false
            }
        }
    }

    func requestAccess() async {
        guard !requesting else { return }
        requesting = true
        error = nil
        defer { requesting = false }
        do {
            access = try await provider.requestAccess()
            if active {
                refresh(invalidate: true)
            }
        } catch { self.error = error.localizedDescription }
    }
}

extension CalendarLauncherModel {
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    func handle(_ key: AskCommandKey, inputEmpty: Bool) -> CalendarEffect {
        switch key {
        case .commandEnter: return .handled
        case .escape:
            if eventFocus {
                eventFocus = false; selectedEventID = nil; return .handled
            }
            return inputEmpty ? .unhandled : .clearInput
        case .commandT: select(today); return .clearInput
        case .commandLeft, .commandRight:
            select(dates.adding(key == .commandLeft ? -1 : 1, .month, to: selected))
            return .clearInput
        case .left, .right, .up, .down:
            if case .year = query {
                let step = key == .left ? -1 : key == .right ? 1 : key == .up ? -4 : 4
                let next = dates.adding(step, .month, to: selected)
                guard (1901 ... 2099).contains(dates.calendar.component(.year, from: next)) else { return .handled }
                selected = next
                query = .year(dates.calendar.component(.year, from: next))
                refresh()
                return .handled
            }
            if eventFocus || isSearch {
                if key == .up || key == .down {
                    moveEvent(key == .up ? -1 : 1); return .handled
                }
                return .unhandled
            }
            if !inputEmpty, key == .left || key == .right {
                return .unhandled
            }
            select(dates.adding(key == .left ? -1 : key == .right ? 1 : key == .up ? -7 : 7, to: selected))
            return .clearInput
        case .tab, .shiftTab:
            if isSearch, let event = chosenEvent {
                select(event.start); return .clearInput
            }
            guard !visibleEvents.isEmpty else { return .handled }
            eventFocus.toggle()
            selectedEventID = eventFocus ? (visibleEvents.first { $0.end > now() } ?? visibleEvents[0]).id : nil
            return .handled
        case .enter:
            if case .invalid = query {
                return .handled
            }
            if case .year = query {
                select(month); return .clearInput
            }
            if let interval {
                return .copy(L("calendar.days", interval.days))
            }
            if isSearch, chosenEvent == nil {
                return .handled
            }
            return .open(selected, event: chosenEvent, join: chosenEvent?.meeting != nil)
        case .commandO:
            return .open(selected, event: chosenEvent, join: false)
        case .commandN: return .open(selected, event: nil, join: false)
        case .optionEnter: return .insert(copiedDate)
        case .commandC:
            if let interval {
                return .copy(L("calendar.days", interval.days))
            }
            if isSearch, chosenEvent == nil {
                return .handled
            }
            return .copy(chosenEvent?.copied(dates: dates, preferences: preferences, locale: locale) ?? copiedDate)
        default: return .unhandled
        }
    }

    private var isSearch: Bool {
        if case .search = query {
            true
        } else {
            false
        }
    }

    private func moveEvent(_ step: Int) {
        let rows = visibleEvents
        guard !rows.isEmpty else { return }
        let index = selectedEventID.flatMap { id in rows.firstIndex { $0.id == id } }
        selectedEventID = rows[max(0, min(rows.count - 1, index.map { $0 + step } ?? (step > 0 ? 0 : rows.count - 1)))]
            .id
        eventFocus = true
    }
}
