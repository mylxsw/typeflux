import Foundation

extension AskPluginAction.Kind {
    /// Only the case name; associated content never enters analytics.
    var analyticsName: String {
        switch self {
        case .killApp: "killApp"
        case .openApplication: "openApplication"
        case .openChat: "openChat"
        case .emoji: "emoji"
        case .systemCommand: "systemCommand"
        case .terminalCommand: "terminalCommand"
        case .terminalAutomationSettings: "terminalAutomationSettings"
        case .openSettings: "openSettings"
        case .openHelp: "openHelp"
        case .configureTranslation: "configureTranslation"
        case .manageTranslationLanguages: "manageTranslationLanguages"
        case .downloadTranslationLanguages: "downloadTranslationLanguages"
        case .swapTranslation: "swapTranslation"
        case .signIn: "signIn"
        case .openConversation: "openConversation"
        case .copy: "copy"
        case .pasteClipboard: "pasteClipboard"
        case .copyClipboard: "copyClipboard"
        case .previewClipboard: "previewClipboard"
        case .writeBack: "writeBack"
        case .speak: "speak"
        case .rerun: "rerun"
        case .compare: "compare"
        case .askAI: "askAI"
        case .focusBrowserTab: "focusBrowserTab"
        case .open: "open"
        case .fileAction: "fileAction"
        case .openIn: "openIn"
        case .reveal: "reveal"
        case .copyImage: "copyImage"
        case .runWith: "runWith"
        case .enterKeyword: "enterKeyword"
        case .editWorkflow: "editWorkflow"
        case .fixWorkflow: "fixWorkflow"
        case .toggleStar: "toggleStar"
        case .openWordBook: "openWordBook"
        case .lookUpInWordBook: "lookUpInWordBook"
        case .copyRich: "copyRich"
        case .openInWindow: "openInWindow"
        case .toggleNote: "toggleNote"
        case .openNotes: "openNotes"
        case .openNote: "openNote"
        case .createNote: "createNote"
        case .capture: "capture"
        case .screenshotFollowUp: "screenshotFollowUp"
        case .translate: "translate"
        }
    }
}

extension ScreenshotOutputAction {
    var analyticsName: String {
        switch self {
        case .copy: "copy"
        case .save: "save"
        case .copyAndSave: "copyAndSave"
        case .record: "record"
        case .pin: "pin"
        case let .followUp(action): action.rawValue
        }
    }
}

extension AskPluginOutput {
    var analyticsOutcome: FeatureUsageAnalytics.Outcome {
        if analyticsFailureKind != nil { return .failed }
        if let translation, !translation.results.contains(where: { $0.completedText != nil }) { return .failed }
        return .completed
    }

    var analyticsResultProperties: [String: String] {
        if let analyticsFailureKind { return ["error_kind": analyticsFailureKind] }
        if analyticsOutcome == .failed { return ["error_kind": "all_services_failed"] }
        if let translation, translation.results.contains(where: { if case .failed = $0.state { return true }; return false }) {
            return ["result_type": "partial_success"]
        }
        if let target = translation?.target {
            return ["target_language": AskTranslationLanguages.common.first { AskTranslationLanguages.sameLanguage($0, target) } ?? "other"]
        }
        return [:]
    }
}
