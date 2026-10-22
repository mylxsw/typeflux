import SwiftUI

/// Settings → Keywords → World Clock: the cities and how times read.
struct WorldClockKeywordSettingsView: View {
    @Binding var options: [String: String]
    @State private var search = ""

    private var preferences: WorldClockPreferences {
        WorldClockPreferences(options: options)
    }

    private var language: AppLanguage {
        AppLocalization.shared.language
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("worldclock.settings.cities")).font(.system(size: 12, weight: .semibold))
            cityList
            addField
            Picker(L("worldclock.settings.hourFormat"), selection: binding(\.hourFormat)) {
                Text(L("worldclock.settings.hourFormat.system")).tag(WorldClockPreferences.HourFormat.system)
                Text(L("worldclock.settings.hourFormat.24")).tag(WorldClockPreferences.HourFormat.twentyFour)
                Text(L("worldclock.settings.hourFormat.12")).tag(WorldClockPreferences.HourFormat.twelve)
            }
            HStack(spacing: 8) {
                Text(L("worldclock.settings.workHours"))
                Spacer()
                hourPicker(binding(\.workStart), range: 0 ..< 24)
                Text("–")
                hourPicker(binding(\.workEnd), range: 1 ..< 25)
            }
            HStack(spacing: 4) {
                Text(L("worldclock.settings.workdays"))
                Spacer()
                ForEach([2, 3, 4, 5, 6, 7, 1], id: \.self) { weekday in
                    workdayToggle(weekday)
                }
            }
            Picker(L("worldclock.settings.step"), selection: binding(\.step)) {
                ForEach(WorldClockPreferences.steps, id: \.self) { minutes in
                    Text(WorldClockFormat.duration(minutes: minutes)).tag(minutes)
                }
            }
            Stepper(L("worldclock.settings.hintCount", preferences.hintCount), value: binding(\.hintCount), in: 0 ... 6)
            Picker(L("worldclock.settings.copyFormat"), selection: binding(\.copyFormat)) {
                ForEach(WorldClockPreferences.CopyFormat.allCases, id: \.self) { format in
                    Text(example(format)).tag(format)
                }
            }
            Toggle(L("worldclock.settings.meetingZones"), isOn: binding(\.meetingAbbreviations))
        }.font(.system(size: 12))
    }

    private var cityList: some View {
        let directory = WorldCityDirectory.shared
        let ids = preferences.cityIDs
        return VStack(spacing: 0) {
            ForEach(Array(ids.enumerated()), id: \.element) { index, id in
                let city = directory.city(id: id)
                HStack(spacing: 8) {
                    Text(city?.name(in: language) ?? id).font(.system(size: 12, weight: .semibold))
                        .frame(width: 110, alignment: .leading).lineLimit(1)
                    Text(city.map { WorldClockAbbreviations.abbreviation($0.timeZone, at: Date()) + " · "
                            + WorldClockFormat.utcOffset(seconds: $0.timeZone.secondsFromGMT()) } ?? "")
                        .foregroundStyle(StudioTheme.textTertiary).frame(width: 120, alignment: .leading)
                    TextField(L("worldclock.settings.label"), text: labelBinding(id)).textFieldStyle(.roundedBorder)
                    Button { move(index, by: -1) } label: { Image(systemName: "chevron.up") }
                        .disabled(index == 0).accessibilityLabel(L("worldclock.settings.moveUp"))
                    Button { move(index, by: 1) } label: { Image(systemName: "chevron.down") }
                        .disabled(index == ids.count - 1).accessibilityLabel(L("worldclock.settings.moveDown"))
                    Button { remove(id) } label: { Image(systemName: "xmark") }
                        .accessibilityLabel(L("worldclock.action.remove"))
                }
                .buttonStyle(.borderless).padding(.vertical, 4)
                .accessibilityIdentifier("worldclock.settings.city." + id)
            }
            if ids.isEmpty {
                Text(L("worldclock.settings.empty")).foregroundStyle(StudioTheme.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var addField: some View {
        let matches = search.isEmpty ? [] : WorldCityDirectory.shared.search(search, limit: 6)
            .filter { !preferences.cityIDs.contains($0.id) }
        return VStack(alignment: .leading, spacing: 4) {
            TextField(L("worldclock.settings.add"), text: $search).textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("worldclock.settings.add")
            ForEach(matches) { city in
                Button {
                    update { $0.cityIDs.append(city.id) }
                    search = ""
                } label: {
                    HStack {
                        Image(systemName: "plus.circle")
                        Text(city.name(in: language))
                        Text([city.country(in: language), city.timeZone.identifier].compactMap { $0 }
                            .joined(separator: " · ")).foregroundStyle(StudioTheme.textTertiary)
                    }
                }.buttonStyle(.borderless)
            }
        }
    }

    private func hourPicker(_ value: Binding<Int>, range: Range<Int>) -> some View {
        Picker("", selection: value) {
            ForEach(range, id: \.self) { hour in
                Text(String(format: "%02d:00", hour)).tag(hour * 60)
            }
        }.labelsHidden().frame(width: 84)
    }

    private func workdayToggle(_ weekday: Int) -> some View {
        let isOn = preferences.workdays.contains(weekday)
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: language.localeIdentifier)
        let symbol = calendar.veryShortStandaloneWeekdaySymbols[weekday - 1]
        return Button {
            update { prefs in
                if isOn { prefs.workdays.remove(weekday) } else { prefs.workdays.insert(weekday) }
            }
        } label: {
            Text(symbol).font(.system(size: 11, weight: isOn ? .semibold : .regular)).frame(width: 22, height: 22)
                .foregroundStyle(isOn ? AskTheme.accent : StudioTheme.textSecondary)
                .background(isOn ? AskTheme.accent.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(AskTheme.separator))
        }.buttonStyle(.plain)
    }

    private func example(_ format: WorldClockPreferences.CopyFormat) -> String {
        let directory = WorldCityDirectory.shared
        guard let city = directory.city(id: "newyork") else { return format.rawValue }
        let presenter = WorldClockPresenter(preferences: preferences, language: language, now: Date(),
                                            localZone: .current, localName: "")
        return presenter.line(city, at: Date(), format: format)
    }

    private func labelBinding(_ id: String) -> Binding<String> {
        Binding(get: { preferences.labels[id] ?? "" }, set: { text in
            update { $0.labels[id] = text.isEmpty ? nil : text }
        })
    }

    private func binding<Value>(_ path: WritableKeyPath<WorldClockPreferences, Value>) -> Binding<Value> {
        Binding(get: { preferences[keyPath: path] }, set: { value in update { $0[keyPath: path] = value } })
    }

    private func move(_ index: Int, by step: Int) {
        update { prefs in
            let target = index + step
            guard prefs.cityIDs.indices.contains(index), prefs.cityIDs.indices.contains(target) else { return }
            prefs.cityIDs.swapAt(index, target)
        }
    }

    private func remove(_ id: String) {
        update { prefs in
            prefs.cityIDs.removeAll { $0 == id }
            prefs.labels[id] = nil
        }
    }

    private func update(_ change: (inout WorldClockPreferences) -> Void) {
        var next = preferences
        change(&next)
        if next.workEnd <= next.workStart { next.workEnd = min(24 * 60, next.workStart + 60) }
        next.write(into: &options)
    }
}
