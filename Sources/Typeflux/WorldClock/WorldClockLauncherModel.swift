import Foundation

enum WorldClockEffect: Equatable {
    case unhandled, handled, clearInput
    case copy(String), insert(String)
    /// The city list changed in the launcher: keep it in the keyword's options.
    case save(WorldClockPreferences, clearInput: Bool, message: String)
}

/// The world clock (`tz`) inside the launcher: which moment it shows, which row is chosen, and its keys.
@MainActor
final class WorldClockLauncherModel: ObservableObject {
    struct Removed: Equatable {
        var id: String
        var index: Int
        var label: String?
    }

    @Published private(set) var query: WorldClockQuery = .list
    @Published private(set) var preferences: WorldClockPreferences
    @Published private(set) var now: Date
    /// The moment ←→ moved to; nil follows the clock.
    @Published private(set) var pinned: Date?
    @Published private(set) var selection = 0
    @Published private(set) var suggestion = 0
    /// ⌥←→ on a meeting suggestion.
    @Published private(set) var nudge: TimeInterval = 0
    @Published private(set) var removed: Removed?
    private(set) var language: AppLanguage = .english
    var clock: () -> Date
    var localZone: () -> TimeZone
    private let directoryLoader: () -> WorldCityDirectory
    private lazy var loadedDirectory = directoryLoader()
    private var ticker: Task<Void, Never>?

    init(directory: @autoclosure @escaping () -> WorldCityDirectory = .shared,
         clock: @escaping () -> Date = Date.init,
         localZone: @escaping () -> TimeZone = { .autoupdatingCurrent }) {
        directoryLoader = directory
        self.clock = clock
        self.localZone = localZone
        now = clock()
        preferences = WorldClockPreferences(options: [:], localZone: localZone())
    }

    deinit {
        ticker?.cancel()
    }

    var directory: WorldCityDirectory {
        loadedDirectory
    }

    var moment: Date {
        pinned ?? now
    }

    var isAtNow: Bool {
        pinned == nil && query == .list
    }

    var locale: Locale {
        Locale(identifier: language.localeIdentifier)
    }

    var localCity: WorldClockCity {
        let zone = localZone()
        return directory.representative(of: zone) ?? directory.city(id: WorldClockCity.zonePrefix + zone.identifier)
            ?? WorldClockCity(id: "local", timeZone: zone, countryCode: nil, population: 0,
                              names: [AppLanguage.english.rawValue: zone.identifier], aliases: [])
    }

    /// The user's cities after the local one; ids the directory no longer knows are skipped.
    var cities: [WorldClockCity] {
        preferences.cityIDs.compactMap { directory.city(id: $0) }
    }

    var presenter: WorldClockPresenter {
        WorldClockPresenter(preferences: preferences, language: language, now: now, localZone: localZone(),
                            localName: localCity.name(in: language))
    }

    /// The moment the bars and times show for the current query.
    var shownMoment: Date {
        switch query {
        case .list, .search, .unknown: moment
        case let .convert(conversion): conversion.date
        case let .timestamp(date, _): date
        case .meeting: chosenMeeting?.start ?? now
        }
    }

    var timeline: WorldClockTimeline {
        WorldClockTimeline(showing: shownMoment, localZone: localZone())
    }

    /// Local first, then the user's cities: what ↑↓ moves through in the list.
    var listCities: [WorldClockCity] {
        [localCity] + cities.filter { $0.id != localCity.id }
    }

    var searchResults: [WorldClockCity] {
        if case let .search(cities) = query { cities } else { [] }
    }

    /// The rows the list shows for the current query.
    var rowCities: [WorldClockCity] {
        switch query {
        case .list, .timestamp: listCities
        case .search: searchResults
        case let .convert(conversion):
            uniqued([conversion.source ?? localCity] + (conversion.target.map { [$0] } ?? []) + listCities)
        case let .meeting(cities): cities
        case .unknown: []
        }
    }

    func rows() -> [WorldClockRow] {
        let presenter = presenter, timeline = timeline, moment = shownMoment
        let localID = localCity.id
        return rowCities.map { presenter.row($0, isLocal: $0.id == localID, at: moment, timeline: timeline) }
    }

    var chosenCity: WorldClockCity? {
        let cities = query == .list ? listCities : searchResults
        return cities.indices.contains(selection) ? cities[selection] : nil
    }

    var meeting: MeetingSlotFinder.Result? {
        guard case let .meeting(cities) = query else { return nil }
        return MeetingSlotFinder(preferences: preferences).find(cities.map(\.timeZone), after: now)
    }

    var chosenMeeting: MeetingSlotFinder.Slot? {
        guard let suggestions = meeting?.suggestions, suggestions.indices.contains(suggestion) else { return nil }
        var slot = suggestions[suggestion]
        slot.start = slot.start.addingTimeInterval(nudge)
        return slot
    }

    // MARK: - Lifecycle

    func activate(text: String, options: [String: String], language: AppLanguage) {
        self.language = language
        preferences = WorldClockPreferences(options: options, localZone: localZone())
        now = clock()
        pinned = nil
        removed = nil
        update(text)
        startTicking()
    }

    func updatePreferences(options: [String: String]) {
        preferences = WorldClockPreferences(options: options, localZone: localZone())
        clampSelection()
    }

    func close() {
        ticker?.cancel()
        ticker = nil
        pinned = nil
    }

    func update(_ text: String) {
        now = clock()
        let next = WorldClockQueryParser(directory: directory, now: now, localZone: localZone()).parse(text)
        if next != query {
            selection = 0
            suggestion = 0
            nudge = 0
        }
        query = next
    }

    private func startTicking() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                let seconds = 60 - (Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 60))
                try? await Task.sleep(for: .seconds(max(1, seconds)))
                guard !Task.isCancelled, let self else { return }
                now = clock()
            }
        }
    }

    // MARK: - Moving

    func select(_ index: Int) {
        selection = index
        clampSelection()
    }

    func chooseSuggestion(_ index: Int) {
        guard meeting?.suggestions.indices.contains(index) == true else { return }
        suggestion = index
        nudge = 0
    }

    /// ←→: to the previous or next step boundary, so times stay round.
    func step(_ direction: Int) {
        let size = TimeInterval(preferences.step * 60)
        let current = moment.timeIntervalSinceReferenceDate + TimeInterval(localZone().secondsFromGMT(for: moment))
        let snapped = direction > 0 ? (floor(current / size) + 1) * size : (ceil(current / size) - 1) * size
        pinned = Date(timeIntervalSinceReferenceDate: snapped - TimeInterval(localZone().secondsFromGMT(for: moment)))
    }

    func moveDays(_ days: Int) {
        pinned = moment.addingTimeInterval(TimeInterval(days) * 86400)
    }

    /// A click on a bar: the nearest half hour at that point of the shown day.
    func moveTo(fraction: Double) {
        let raw = timeline.start.addingTimeInterval(max(0, min(1, fraction)) * 86400)
        let size = TimeInterval(preferences.step * 60)
        pinned = Date(timeIntervalSinceReferenceDate: (raw.timeIntervalSinceReferenceDate / size).rounded() * size)
    }

    func returnToNow() {
        now = clock()
        pinned = nil
        nudge = 0
    }

    func nudgeMeeting(_ direction: Int) {
        nudge += TimeInterval(direction * preferences.step * 60)
    }

    /// The list after an edit in the launcher; the caller saves it.
    func replacePreferences(_ next: WorldClockPreferences, showingList: Bool = false, removed: Removed? = nil) {
        preferences = next
        self.removed = removed
        if showingList { query = .list }
        clampSelection()
    }

    private func clampSelection() {
        let count = query == .list ? listCities.count : searchResults.count
        selection = max(0, min(selection, max(0, count - 1)))
    }

    private func uniqued(_ cities: [WorldClockCity]) -> [WorldClockCity] {
        var seen = Set<String>()
        return cities.filter { seen.insert($0.id).inserted }
    }
}
