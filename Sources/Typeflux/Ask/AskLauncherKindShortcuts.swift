import AppKit

/// Command-M toggles Chat/Work without taking over Copy or Close.
enum AskLauncherKindShortcuts {
    static func key(for kind: AskConversationKind) -> String { "M" }

    static func matches(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              event.modifierFlags.intersection([.command, .option, .control, .shift]) == .command else { return false }
        if let characters = event.charactersIgnoringModifiers, !characters.isEmpty {
            return characters.lowercased() == "m"
        }
        return event.keyCode == 46
    }
}
