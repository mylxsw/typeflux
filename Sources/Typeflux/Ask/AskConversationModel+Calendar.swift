import AppKit
import Foundation

extension AskConversationModel {
    func performCalendarEffect(_ effect: CalendarEffect) -> PluginActionOutcome {
        switch effect {
        case .unhandled, .handled: return .stay
        case .clearInput: launcherDraft.text = ""; return .stay
        case let .copy(text): copyPluginText(text); return .stay
        case let .insert(text):
            return performPluginAction(.init(kind: .writeBack(text), title: "", symbol: ""))
        case .settings:
            _ = calendarLauncher
                .openURL(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
            return .stay
        case let .open(date, event, join):
            let target = join ? event?.meeting : event.map(CalendarLinks.event)
            let opened = calendarLauncher.openURL(target ?? CalendarLinks.day(date))
            if !opened, target != nil, !calendarLauncher.openURL(CalendarLinks.day(date)) {
                confirm(L("calendar.openFailed")); return .stay
            }
            if !opened, target == nil {
                confirm(L("calendar.openFailed")); return .stay
            }
            finishPluginResult()
            return .close
        }
    }

    func hideCalendarEvents() {
        guard let current = plugins.keyword else { return }
        let settings = modelLibrary.settings
        var keywords = settings.effectiveAskLauncherKeywords(reserving: workflows?.workflows ?? [])
        guard let index = keywords.firstIndex(where: { $0.id == current.id && $0.pluginID == AskCalendarPlugin.id })
        else { return }
        keywords[index].options["calendar.events"] = "false"
        settings.saveAskLauncherKeywords(keywords)
        var options = current.options
        options["calendar.events"] = "false"
        calendarLauncher.updatePreferences(options: options, language: AppLocalization.shared.language)
    }
}
