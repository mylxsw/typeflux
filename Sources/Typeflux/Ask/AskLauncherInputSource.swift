import Carbon.HIToolbox
import Foundation

@MainActor
protocol AskLauncherInputSourceSelecting {
    func selectEnglish()
}

struct SystemAskLauncherInputSourceSelector: AskLauncherInputSourceSelecting {
    nonisolated init() {}

    func selectEnglish() {
        // Use the user's most recently used enabled English source, rather than
        // hard-coding ABC or enabling a keyboard layout they have not chosen.
        guard let source = TISCopyInputSourceForLanguage("en" as CFString)?.takeRetainedValue() else { return }
        TISSelectInputSource(source)
    }
}
