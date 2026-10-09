import Foundation

/// A local draft moved from a model that cannot read images to one that can.
struct AskVisionSwitch: Equatable {
    /// `AskConversationModel.visionDraftKey` of the draft that switched.
    let draftKey: String
    let from: String
    let to: String
}

/// What the "explain this screen" suggestion can do with the current model.
enum AskScreenshotSuggestion: Equatable {
    /// The current model reads images.
    case ready
    /// Picking it moves the draft to this vision model on the Mac.
    case switches(model: String)
    /// Ask runs locally and none of the user's models reads images.
    case needsVisionModel
    /// Another reason the screenshot cannot be sent.
    case unavailable(reason: String)

    var enabled: Bool {
        switch self {
        case .ready, .switches: return true
        case .needsVisionModel, .unavailable: return false
        }
    }

    /// The caption under the suggestion, in place of its default one.
    func caption(default value: String) -> String {
        switch self {
        case .ready: return value
        case let .switches(model): return String(format: L("ask.vision.willUse"), model)
        case .needsVisionModel: return L("ask.vision.none")
        case let .unavailable(reason): return reason
        }
    }
}

extension AskConversationModel {
    /// The launcher has one draft; each conversation, and the new one, has its own.
    func visionDraftKey(launcher: Bool) -> String {
        launcher ? "launcher" : selectedId ?? "new"
    }

    /// The model a local draft would move to so that it can send images, if it needs one.
    func visionCandidate(launcher: Bool) -> String? {
        // A model of unknown support keeps the draft: it gets a try before anything moves.
        guard !cloudAvailable(launcher: launcher), !screenshotCapability(launcher: launcher).canAttach,
              let reference = modelLibrary.firstLocalReference(hasImage: true),
              reference != modelReference(launcher: launcher) else { return nil }
        return reference
    }

    /// Moves a local draft that has to send images onto a model that can read them,
    /// unless the user already switched this draft back. Returns whether it switched.
    @discardableResult
    func switchToVisionModelIfNeeded(launcher: Bool, needsVision: Bool? = nil) -> Bool {
        let key = visionDraftKey(launcher: launcher)
        guard needsVision ?? requiresVision(launcher: launcher), !visionSwitchDeclined.contains(key),
              let target = visionCandidate(launcher: launcher) else { return false }
        let from = modelReference(launcher: launcher)
        if launcher { launcherDraft.modelRef = target } else { draft.modelRef = target }
        // The launcher closes on send; its conversation then shows the model it ran on.
        if !launcher { visionSwitch = AskVisionSwitch(draftKey: key, from: from, to: target) }
        persistDrafts()
        return true
    }

    /// The banner for the draft on screen, if it switched.
    var visibleVisionSwitch: AskVisionSwitch? {
        visionSwitch.flatMap { $0.draftKey == visionDraftKey(launcher: false) ? $0 : nil }
    }

    /// Puts the draft back on the model it had and keeps it there.
    func revertVisionSwitch() {
        guard let change = visibleVisionSwitch else { return }
        visionSwitchDeclined.insert(change.draftKey)
        visionSwitch = nil
        selectModel(change.from, launcher: false)
    }

    func screenshotSuggestion(launcher: Bool) -> AskScreenshotSuggestion {
        let capability = screenshotCapability(launcher: launcher)
        if capability.canAttach { return .ready }
        if let candidate = visionCandidate(launcher: launcher) {
            return .switches(model: modelLibrary.name(for: candidate))
        }
        if !cloudAvailable(launcher: launcher) { return .needsVisionModel }
        return .unavailable(reason: capability.hint ?? L("ask.models.unavailable"))
    }

    /// Prepares a draft for the "explain this screen" suggestion: a vision model, then the screenshot.
    func attachScreenshotForSuggestion(launcher: Bool) {
        switchToVisionModelIfNeeded(launcher: launcher, needsVision: true)
        guard screenshotCapability(launcher: launcher).canAttach else { return }
        if launcher { launcherDraft.includeScreenshot = true } else { draft.includeScreenshot = true }
        if (launcher ? launcherDraft : draft).screenshot == nil {
            Task { await refreshScreenshot(launcher: launcher) }
        }
    }
}
