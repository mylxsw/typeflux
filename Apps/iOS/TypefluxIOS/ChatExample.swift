import Foundation
import TypefluxChat

/// Bundled examples never create an account, contact a server or consume credits.
enum ChatExample: String, CaseIterable, Identifiable {
    case email, summary, translation
    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .email: NSLocalizedString("Make an email more professional", comment: "Example")
        case .summary: NSLocalizedString("Summarize meeting notes", comment: "Example")
        case .translation: NSLocalizedString("Translate a message", comment: "Example")
        }
    }

    var question: String {
        switch self {
        case .email: NSLocalizedString(
                "Rewrite politely: Tomorrow's meeting is now at 3. Send me the materials first.",
                comment: "Example"
            )
        case .summary: NSLocalizedString(
                "Summarize: We agreed to test the new design on Friday. Alex will prepare the prototype; Sam will gather feedback.",
                comment: "Example"
            )
        case .translation: NSLocalizedString(
                "Translate into Chinese: Thanks for your help. I'll send the revised proposal tomorrow.",
                comment: "Example"
            )
        }
    }

    var answer: String {
        switch self {
        case .email: NSLocalizedString(
                "Hello, tomorrow's meeting has been moved to 3 PM. Could you please share the materials beforehand? Thank you!",
                comment: "Example"
            )
        case .summary: NSLocalizedString(
                "• Friday: test the new design.\n• Alex: prepare the prototype.\n• Sam: gather feedback.",
                comment: "Example"
            )
        case .translation: NSLocalizedString("谢谢你的帮助。我会在明天发送修改后的方案。", comment: "Example")
        }
    }
}
