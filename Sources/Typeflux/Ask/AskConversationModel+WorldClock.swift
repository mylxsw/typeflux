import Foundation

extension AskConversationModel {
    func performWorldClockEffect(_ effect: WorldClockEffect) -> PluginActionOutcome {
        switch effect {
        case .unhandled, .handled: return .stay
        case .clearInput: launcherDraft.text = ""; return .stay
        case let .copy(text): copyPluginText(text); return .stay
        case let .insert(text):
            return performPluginAction(.init(kind: .writeBack(text), title: "", symbol: ""))
        case let .save(preferences, clearInput, message):
            saveWorldClock(preferences)
            if clearInput { launcherDraft.text = "" }
            if !message.isEmpty { confirm(message) }
            return .stay
        }
    }

    /// Keeps a list changed in the launcher in the world clock keyword's options.
    func saveWorldClock(_ preferences: WorldClockPreferences) {
        guard let current = plugins.keyword, current.pluginID == AskWorldClockPlugin.id else { return }
        let settings = modelLibrary.settings
        var keywords = settings.effectiveAskLauncherKeywords(reserving: workflows?.workflows ?? [])
        guard let index = keywords.firstIndex(where: { $0.id == current.id && $0.pluginID == AskWorldClockPlugin.id })
        else { return }
        preferences.write(into: &keywords[index].options)
        settings.saveAskLauncherKeywords(keywords)
    }
}
