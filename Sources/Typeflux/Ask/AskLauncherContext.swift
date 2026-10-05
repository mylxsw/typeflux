import Foundation

/// The launcher's captured context drawn as one token beside its editor: the
/// source app's icon, a short window title, the selected text's line count and
/// the screenshot's thumbnail. Pure, so it can be tested without a window.
enum AskLauncherContext {
    /// How the screenshot shows in the token.
    enum Screenshot: Equatable {
        case none, attached, off, capturing, failed
    }

    struct Token: Equatable {
        /// The source app, drawn as its icon; nil when nothing names it.
        var bundleID: String?
        var hasSource = false
        /// The source is captured but not sent with this question.
        var sourceOff = false
        /// Full app name and window title for the tooltip.
        var help: String?
        /// Short window title; nil once the editor has text.
        var title: String?
        /// Lines of selected text that ride along; nil when none, or once the editor has text.
        var selectionLines: Int?
        var screenshot: Screenshot = .none
        /// The source came from an earlier launcher session.
        var restored = false
    }

    /// The window title without the app name it usually ends with, which the
    /// icon already shows: "Issues | Multica - Google Chrome" → "Issues | Multica".
    /// A trailing profile name such as "- Google Chrome - Work" goes too.
    static func shortTitle(app: String, window: String?) -> String {
        let app = app.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var title = window?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return app }
        guard !app.isEmpty else { return title }
        for separator in [" - ", " — ", " – ", " | "] {
            guard let range = title.range(of: separator + app, options: [.backwards, .caseInsensitive]) else { continue }
            let rest = title[range.upperBound...]
            // Only the app's own name as the title's last part, or before a short profile name.
            guard rest.isEmpty || [" - ", " — ", " – "].contains(where: { rest.hasPrefix($0) }) else { continue }
            title = String(title[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            break
        }
        return title.isEmpty || title.caseInsensitiveCompare(app) == .orderedSame ? app : title
    }

    /// The token for the launcher's draft, or nil when nothing was captured.
    /// `collapsed` drops the words once the editor has text, leaving the icons.
    static func token(draft: AskDraft, screenshotState: AskScreenshotState, capturing: Bool,
                      restored: Bool, collapsed: Bool) -> Token? {
        var token = Token()
        if let source = draft.source?.trimmingCharacters(in: .whitespacesAndNewlines), !source.isEmpty {
            let parts = AskContextChips.sourceParts(source)
            token.hasSource = true
            token.bundleID = draft.sourceBundleID
            token.sourceOff = draft.sourceOff == true
            token.help = parts.window.map { parts.app + " · " + $0 } ?? parts.app
            token.restored = restored
            if !collapsed, !token.sourceOff {
                token.title = shortTitle(app: parts.app, window: parts.window)
            }
        }
        if !collapsed, let selection = draft.sentSelection, !selection.isEmpty {
            token.selectionLines = AskPresentation.lineCount(selection)
        }
        token.screenshot = screenshot(draft: draft, state: screenshotState, capturing: capturing)
        let selectionCaptured = draft.selection?.isEmpty == false
        guard token.hasSource || selectionCaptured || token.screenshot != .none else { return nil }
        return token
    }

    static func screenshot(draft: AskDraft, state: AskScreenshotState, capturing: Bool) -> Screenshot {
        guard draft.includeScreenshot else { return draft.screenshot == nil ? .none : .off }
        if capturing { return .capturing }
        switch state {
        case .attached: return draft.screenshot == nil ? .none : .attached
        case .failed, .unavailable: return .failed
        case .off: return draft.screenshot == nil ? .none : .off
        }
    }

    /// What ⌫ in an empty launcher takes off next: the screenshot the token
    /// shows, then the selected text, then the source. Nil when nothing is left.
    static func backspaceTarget(_ draft: AskDraft, screenshot: Screenshot) -> AskCapturedContentKind? {
        if draft.includeScreenshot, [.attached, .capturing, .failed].contains(screenshot) { return .screenshot }
        if let selection = draft.sentSelection, !selection.isEmpty { return .selection }
        if let source = draft.sentSource, !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .source
        }
        return nil
    }

    /// The keys the bottom bar explains: recording, the highlighted quick result,
    /// or sending, with ⌘K when there is context to open.
    static func hint(voice: AskVoiceInput.Phase, quickResults: AskQuickResults?, hasContext: Bool) -> String {
        switch voice {
        case .listening: return L("ask.launcher.hint.voice")
        case .transcribing: return L("ask.launcher.hint.transcribing")
        case .idle:
            if let quickResults { return AskQuickResultsView.hint(for: quickResults) }
            return L(hasContext ? "ask.launcher.hint.context" : "ask.launcher.hint")
        }
    }

    /// The send button is lit only when Return asks the AI, not while it would
    /// copy a calculation or open an application.
    static func sendIsProminent(quickResults: AskQuickResults?) -> Bool {
        guard let quickResults else { return true }
        return quickResults.highlightedRow == .askAI
    }

    /// "0:04", "1:30": time spent recording.
    static func elapsed(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
