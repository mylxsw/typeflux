import Foundation

extension AskConversationModel {
    /// Resolves a live entry again so deleted records and missing files cannot be applied from stale results.
    func applyLauncherClipboard(id: String, paste: Bool) -> PluginActionOutcome {
        guard let entry = clipboardEntries().first(where: { $0.id == id }) else {
            confirm(L("ask.plugin.clip.unavailable"))
            return .stay
        }
        guard entry.contentURLs.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else {
            confirm(L("clipboard.notice.missingFile"))
            return .stay
        }
        if let text = entry.text, entry.kind.isTextual {
            if paste {
                AskQuickResults.copy(text)
                finishPluginResult()
                writeBack(text)
                return .close
            }
            copyPluginText(text)
            return .stay
        }
        guard clipboardContentActions.writeToPasteboard(entry, asPlainText: false) else {
            confirm(L("ask.plugin.clip.unavailable"))
            return .stay
        }
        guard paste else {
            confirm(L("ask.plugin.copied"))
            return .stay
        }
        finishPluginResult()
        let actions = clipboardContentActions
        Task {
            // Let the source app take keyboard focus back after the launcher closes.
            try? await Task.sleep(for: .milliseconds(150))
            actions.sendPasteShortcut()
        }
        return .close
    }
}
