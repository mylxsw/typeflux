import AppKit

/// Mode shortcuts belong to the launcher; started conversations keep their kind.
enum AskLauncherKindShortcuts {
    static func key(for kind: AskConversationKind) -> String {
        kind == .chat ? "C" : "W"
    }

    static func kind(for event: NSEvent, hasSelection: Bool = false) -> AskConversationKind? {
        guard event.type == .keyDown,
              event.modifierFlags.intersection([.command, .option, .control, .shift]) == .command else { return nil }
        if let characters = event.charactersIgnoringModifiers, !characters.isEmpty {
            switch characters.lowercased() {
            case "c": return hasSelection ? nil : .chat
            case "w": return .work
            default: return nil
            }
        }
        switch event.keyCode {
        case 8: return hasSelection ? nil : .chat
        case 13: return .work
        default: return nil
        }
    }
}
