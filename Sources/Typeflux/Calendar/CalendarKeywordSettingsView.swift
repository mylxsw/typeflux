import SwiftUI

struct CalendarKeywordSettingsView: View {
    @Binding var options: [String: String]
    @State private var sources: [CalendarSource] = []

    private var preferences: CalendarPreferences {
        CalendarPreferences(options: options, language: AppLocalization.shared.language)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(L("calendar.settings.lunar"), isOn: flag("calendar.lunar", fallback: preferences.showsLunar))
            Toggle(
                L("calendar.settings.holidays"),
                isOn: flag("calendar.holidays", fallback: preferences.showsHolidays)
            )
            Toggle(L("calendar.settings.weeks"), isOn: flag("calendar.weeks", fallback: false))
            Toggle(L("calendar.settings.events"), isOn: flag("calendar.events", fallback: true))
            Picker(L("calendar.settings.format"), selection: Binding(get: { options["calendar.copyFormat"] ?? "full" },
                                                                     set: { options["calendar.copyFormat"] = $0 })) {
                Text(L("calendar.settings.full")).tag("full")
                Text("2026-10-14").tag("iso")
                Text(L("calendar.settings.short")).tag("short")
                Text(L("calendar.settings.system")).tag("system")
            }
            if preferences.showsEvents {
                Text(L("calendar.settings.calendars")).font(.system(size: 12, weight: .semibold))
                Toggle(
                    L(preferences.showsHolidays ? "calendar.settings.all" : "calendar.settings.allCalendars"),
                    isOn: Binding(get: { preferences.calendars.isEmpty }, set: { all in
                        options["calendar.calendars"] = all ? nil : "none"
                    })
                )
                ForEach(sources) { source in
                    Toggle(source.title, isOn: Binding(get: {
                        preferences.includedCalendars(sources).contains(source.id)
                    }, set: { included in
                        var ids = preferences.includedCalendars(sources).subtracting(["none"])
                        if included {
                            ids.insert(source.id)
                        } else {
                            ids.remove(source.id)
                        }
                        options["calendar.calendars"] = ids.isEmpty ? "none" : ids.sorted().joined(separator: ",")
                    }))
                }
                if sources.isEmpty {
                    Text(L("calendar.settings.permission")).font(.system(size: 11))
                        .foregroundStyle(StudioTheme.textTertiary)
                }
            }
        }.font(.system(size: 12))
            .task { sources = await EventKitEventProvider().sources() }
    }

    private func flag(_ key: String, fallback: Bool) -> Binding<Bool> {
        Binding(get: { options[key].map { $0 == "true" } ?? fallback }, set: { options[key] = String($0) })
    }
}
