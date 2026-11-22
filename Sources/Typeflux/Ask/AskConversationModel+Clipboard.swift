import Foundation

extension AskConversationModel {
    /// Resolves a live entry again so deleted records and missing files cannot be applied from stale results.
    func applyLauncherClipboard(id: String, paste: Bool, completed: @escaping @MainActor () -> Void = {}) -> PluginActionOutcome {
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
        let access = contextImageAccess(launcher: true), account = session(), generation = plugins.resultGeneration
        clipboardAction.start(entry: entry, plainText: false, paste: paste, actions: clipboardContentActions,
            authorized: { [weak self] in
                guard let self else { return false }
                let live = self.session()
                return account?.owner == live?.owner && account?.token == live?.token && self.clipboardEntries().contains(entry)
            }, beforeCommit: { [weak self] in access.allows() && self?.plugins.resultGeneration == generation },
            committed: { [weak self] in
                guard let self else { return }
                if paste { self.finishPluginResult(); completed() }
                else { self.confirm(L("ask.plugin.copied")) }
            }, failed: { [weak self] in self?.confirm(L("ask.plugin.clip.unavailable")) })
        return .stay
    }
}
