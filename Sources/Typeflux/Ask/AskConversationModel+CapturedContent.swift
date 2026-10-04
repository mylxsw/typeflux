import Foundation

enum AskCapturedContentKind: String, CaseIterable {
    case source, selection, screenshot
}

struct AskCapturedContentFeedback {
    let text: String
    let canUndo: Bool
}

/// Only captured fields are retained for undo; typed text, files and memory are
/// never restored from a stale copy of the composer's draft.
struct AskCapturedContentSnapshot {
    let source: String?
    let sourceBundleID: String?
    let sourceOff: Bool?
    let selection: String?
    let selectionOff: Bool?
    let screenshot: String?
    let includeScreenshot: Bool

    init(_ draft: AskDraft) {
        source = draft.source; sourceBundleID = draft.sourceBundleID; sourceOff = draft.sourceOff
        selection = draft.selection; selectionOff = draft.selectionOff
        screenshot = draft.screenshot; includeScreenshot = draft.includeScreenshot
    }

    func matches(_ kind: AskCapturedContentKind, in draft: AskDraft) -> Bool {
        switch kind {
        case .source:
            return source == draft.source && sourceBundleID == draft.sourceBundleID && sourceOff == draft.sourceOff
        case .selection:
            return selection == draft.selection && selectionOff == draft.selectionOff
        case .screenshot:
            return screenshot == draft.screenshot && includeScreenshot == draft.includeScreenshot
        }
    }
}

enum AskCapturedContentAction {
    case inclusion(AskCapturedContentKind)
    case sourceReplacement(restored: Bool)
}

struct AskCapturedContentChange {
    let id = UUID()
    let key: String
    let account: String?
    let text: String
    let action: AskCapturedContentAction?
    let before: AskCapturedContentSnapshot
    let after: AskCapturedContentSnapshot
}

extension AskConversationModel {
    var launcherReplacementAppName: String? {
        let request = makeLauncherSelectionRequest()
        guard request.processID != nil, request.processID != ProcessInfo.processInfo.processIdentifier,
              let name = request.processName,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return name
    }

    func capturedContentKey(launcher: Bool) -> String {
        let queued = launcher ? nil : sendQueue.editing?.itemId
        return visionDraftKey(launcher: launcher) + (queued.map { "/queued/" + $0 } ?? "")
    }

    func capturedContentFeedback(launcher: Bool) -> AskCapturedContentFeedback? {
        guard let change = capturedContentChanges[launcher],
              change.key == capturedContentKey(launcher: launcher),
              change.account == capturedContentAccount else { return nil }
        return AskCapturedContentFeedback(text: change.text,
                                          canUndo: canUndoCapturedContent(change, launcher: launcher))
    }

    func removeCapturedContent(_ kind: AskCapturedContentKind, launcher: Bool) {
        setCapturedContent(kind, included: false, launcher: launcher)
    }

    func restoreCapturedContent(_ kind: AskCapturedContentKind, launcher: Bool) {
        setCapturedContent(kind, included: true, launcher: launcher)
    }

    private func setCapturedContent(_ kind: AskCapturedContentKind, included: Bool, launcher: Bool) {
        guard !capturing || kind == .screenshot else { return }
        var value = launcher ? launcherDraft : draft
        let before = AskCapturedContentSnapshot(value)
        switch kind {
        case .source:
            guard let source = value.source, !source.isEmpty, (value.sourceOff != true) != included else { return }
            value.sourceOff = included ? nil : true
        case .selection:
            guard let selection = value.selection, !selection.isEmpty,
                  (value.selectionOff != true) != included else { return }
            value.selectionOff = included ? nil : true
        case .screenshot:
            guard value.includeScreenshot != included,
                  !included || screenshotCapability(launcher: launcher).canAttach else { return }
            value.includeScreenshot = included
        }
        if launcher { launcherDraft = value } else { draft = value }
        recordCapturedContentChange(.inclusion(kind), before: before,
                                    text: L("ask.context.\(included ? "restored" : "removed").\(kind.rawValue)"), launcher: launcher)
        persistDrafts()
    }

    func recordCapturedContentChange(_ action: AskCapturedContentAction, before: AskCapturedContentSnapshot,
                                     text: String, launcher: Bool) {
        setCapturedContentFeedback(AskCapturedContentChange(
            key: capturedContentKey(launcher: launcher), account: capturedContentAccount, text: text,
            action: action, before: before, after: AskCapturedContentSnapshot(launcher ? launcherDraft : draft)),
            launcher: launcher)
    }

    func reportSourceRefreshFailure(_ text: String) {
        let snapshot = AskCapturedContentSnapshot(launcherDraft)
        setCapturedContentFeedback(AskCapturedContentChange(
            key: capturedContentKey(launcher: true), account: capturedContentAccount, text: text,
            action: nil, before: snapshot, after: snapshot), launcher: true)
    }

    func clearCapturedContentFeedback(launcher: Bool) {
        capturedContentFeedbackTasks[launcher]?.cancel()
        capturedContentFeedbackTasks[launcher] = nil
        capturedContentChanges[launcher] = nil
    }

    private func setCapturedContentFeedback(_ change: AskCapturedContentChange, launcher: Bool) {
        capturedContentFeedbackTasks[launcher]?.cancel()
        capturedContentChanges[launcher] = change
        let delay = capturedContentFeedbackDuration
        capturedContentFeedbackTasks[launcher] = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard let self, capturedContentChanges[launcher]?.id == change.id else { return }
            capturedContentChanges[launcher] = nil
            capturedContentFeedbackTasks[launcher] = nil
        }
    }

    private func canUndoCapturedContent(_ change: AskCapturedContentChange, launcher: Bool) -> Bool {
        guard !capturing, let action = change.action else { return false }
        let value = launcher ? launcherDraft : draft
        switch action {
        case let .inclusion(kind):
            return change.after.matches(kind, in: value)
                && (kind != .screenshot || !change.before.includeScreenshot
                    || screenshotCapability(launcher: launcher).canAttach)
        case .sourceReplacement:
            return change.after.matches(.source, in: value) && change.after.matches(.selection, in: value)
        }
    }

    func undoCapturedContent(launcher: Bool) {
        guard capturedContentFeedback(launcher: launcher)?.canUndo == true,
              let change = capturedContentChanges[launcher], let action = change.action else { return }
        var value = launcher ? launcherDraft : draft
        switch action {
        case .inclusion(.source): value.sourceOff = change.before.sourceOff
        case .inclusion(.selection): value.selectionOff = change.before.selectionOff
        case .inclusion(.screenshot): value.includeScreenshot = change.before.includeScreenshot
        case let .sourceReplacement(restored):
            value.source = change.before.source; value.sourceBundleID = change.before.sourceBundleID
            value.selection = change.before.selection; value.selectionOff = change.before.selectionOff
            if launcher { restoreLauncherContextMarker(restored) }
        }
        if launcher { launcherDraft = value } else { draft = value }
        setCapturedContentFeedback(AskCapturedContentChange(
            key: change.key, account: change.account, text: L("ask.context.undo.applied"), action: nil,
            before: change.before, after: AskCapturedContentSnapshot(value)), launcher: launcher)
        persistDrafts()
    }
}
