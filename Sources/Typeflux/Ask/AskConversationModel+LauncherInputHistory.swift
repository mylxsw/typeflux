import Foundation

extension AskConversationModel {
    var launcherHistoryEntries: [AskLauncherInputHistory.Entry] { launcherInputHistory.matches(launcherDraft.text) }

    var highlightedLauncherHistory: AskLauncherInputHistory.Entry? {
        let entries = launcherHistoryEntries
        guard !entries.isEmpty else { return nil }
        return entries[min(max(0, launcherHistoryIndex), entries.count - 1)]
    }

    func openLauncherInputHistory() {
        guard !launcherDraft.hasText, !plugins.isActive, !voiceInput.isActive else { return }
        launcherDraft.text = ""
        launcherHistoryIndex = 0
        launcherHistoryMode = true
        plugins.deactivate()
        quickSearch.cancel()
        quickSearch.results = nil
    }

    func leaveLauncherInputHistory() {
        launcherHistoryMode = false
        launcherHistoryIndex = 0
        launcherDraft.text = ""
    }

    @discardableResult
    func fillLauncherInputHistory(_ entry: AskLauncherInputHistory.Entry) -> Bool {
        guard launcherHistoryMode, launcherInputHistory.enabled,
              let current = launcherHistoryEntries.first(where: { $0.id == entry.id }) else { return false }
        launcherHistoryMode = false
        launcherHistoryIndex = 0
        launcherDraft.text = current.text
        launcherHistoryFillID = UUID()
        // Normal keyword matching/search runs from the composer's text change observer.
        return true
    }

    // One branch per history shortcut keeps the routing together.
    // swiftlint:disable:next cyclomatic_complexity
    func launcherInputHistoryKey(_ key: AskCommandKey) -> Bool {
        guard launcherHistoryMode, !voiceInput.isActive else { return false }
        switch key {
        case .up, .down:
            launcherHistoryIndex = min(max(0, launcherHistoryIndex + (key == .up ? -1 : 1)),
                                       max(0, launcherHistoryEntries.count - 1))
        case .enter, .right, .tab:
            if let entry = highlightedLauncherHistory { fillLauncherInputHistory(entry) }
        case let .number(number):
            let entries = launcherHistoryEntries
            if entries.indices.contains(number - 1) { fillLauncherInputHistory(entries[number - 1]) }
        case .commandEnter:
            if let entry = highlightedLauncherHistory { askFromLauncherInputHistory(entry) }
        case .commandDelete:
            if let entry = highlightedLauncherHistory { deleteLauncherInputHistory(entry) }
        case .escape:
            if launcherDraft.text.isEmpty {
                leaveLauncherInputHistory()
            } else {
                launcherDraft.text = ""; launcherHistoryIndex = 0
            }
        default: return false
        }
        return true
    }

    func askFromLauncherInputHistory(_ entry: AskLauncherInputHistory.Entry) {
        guard fillLauncherInputHistory(entry) else { return }
        submitLauncher()
    }

    func deleteLauncherInputHistory(_ entry: AskLauncherInputHistory.Entry) {
        launcherInputHistory.delete(entry.id)
        launcherHistoryIndex = min(launcherHistoryIndex, max(0, launcherHistoryEntries.count - 1))
    }

    /// A fresh opening clears input state before capture starts; prepared keyword actions run afterwards.
    func resetLauncherForPresentation() {
        if let current = session(), owner != current.owner { resetSession(); owner = current.owner }
        captureGeneration = UUID()
        clearCapturedContentFeedback(launcher: true)
        releaseLauncherScreenshot()
        launcherClipboardPreview = nil
        answerWorkflowApproval(false)
        plugins.deactivate()
        launcherHistoryMode = false
        launcherHistoryIndex = 0
        launcherHistoryFillID = nil
        launcherExecutedInput = nil
        launcherDraft = newQuestionDraft()
        restoreLauncherContextMarker(false)
        captureWarning = nil
        submissionIssues[true] = nil
        launcherPresentationID = UUID()
        attachmentLoads[visionDraftKey(launcher: true)] = nil
        persistDrafts()
    }

    /// Called before keyword mode is folded and the panel is hidden. A filter is never a draft.
    func recordAbandonedLauncherInput() {
        guard !launcherHistoryMode else { return }
        let input = plugins.keyword.map { $0.keyword + " " + launcherDraft.text } ?? launcherDraft.text
        guard AskLauncherInputHistory.identity(input) != launcherExecutedInput else { return }
        recordLauncherInput(destination: .unsent)
    }

    func recordLauncherInput(destination: AskLauncherInputHistory.Destination, label: String = "",
                             text: String? = nil, keyword: String? = nil) {
        // Chained workflows supply generated arguments rather than a user's input.
        guard text != nil || plugins.request?.chain.isEmpty != false else { return }
        let argument = text ?? launcherDraft.text
        let prefix = keyword ?? (text == nil ? plugins.keyword?.keyword : nil)
        guard !argument.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let input = prefix.map { $0 + " " + argument } ?? argument
        let identity = AskLauncherInputHistory.identity(input)
        let bareKeyword = launcherKeywords.contains { $0.allKeywords.contains { $0.lowercased() == identity } }
        guard !bareKeyword else { return }
        if destination != .unsent { launcherExecutedInput = identity }
        launcherInputHistory.record(input, destination: destination, label: label, keyword: prefix)
    }
}
