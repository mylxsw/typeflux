import Foundation

enum AskImageCapability: Equatable {
    /// `unknown`: a Cloud model the catalog says nothing about, so images stay off.
    /// `untested`: one of the user's own models nobody has confirmed either way; it gets a try,
    /// and a failed run brings up the image recovery card.
    case supported, unsupported, unknown, untested, unavailable

    /// A screenshot can be attached: the model reads images, or it is the user's own and gets a try.
    var canAttach: Bool { self == .supported || self == .untested }

    var hint: String? {
        switch self {
        case .supported: return nil
        case .unsupported: return L("ask.image.unsupported")
        case .unknown: return L("ask.image.unknown")
        case .untested: return L("ask.image.untested")
        case .unavailable: return L("ask.models.unavailable")
        }
    }
}

extension AskModelLibrary {
    func imageCapability(_ reference: String) -> AskImageCapability {
        guard let (provider, model) = registry.resolve(reference) else { return .unavailable }
        switch model.effectiveVision {
        case true?: return .supported
        case false?: return .unsupported
        case nil: return provider.isCloud ? .unknown : .untested
        }
    }
}

struct AskImageRecoveryTarget: Equatable, Identifiable {
    let conversationID: String
    let runID: String
    var id: String { conversationID + "/" + runID }
}

extension AskConversationModel {
    var hasConversationImages: Bool {
        selected?.messages.contains(where: { $0.image != nil }) == true
    }

    var recoveringImage: AskImageRecoveryTarget? {
        selectedId.flatMap { recoveringImages[$0] }
    }

    func screenshotCapability(launcher: Bool) -> AskImageCapability {
        modelLibrary.imageCapability(modelReference(launcher: launcher))
    }

    func normalizeScreenshotChoices() {
        if !screenshotCapability(launcher: true).canAttach, launcherDraft.includeScreenshot {
            launcherDraft.includeScreenshot = false
        }
        if !isLoadingSelection, !screenshotCapability(launcher: false).canAttach, draft.includeScreenshot {
            draft.includeScreenshot = false
        }
    }

    func selectModel(_ reference: String, launcher: Bool) {
        let wasAttached = launcher ? launcherDraft.includeScreenshot : draft.includeScreenshot
        if launcher { launcherDraft.modelRef = reference } else { draft.modelRef = reference }
        snapReasoningEffort(launcher: launcher)
        let notice = wasAttached && !screenshotCapability(launcher: launcher).canAttach
            ? L("ask.image.detached") : nil
        if launcher { launcherScreenshotNotice = notice } else { screenshotNotice = notice }
        if !launcher, imageRecoveryTarget != nil { error = nil }
        persistDrafts()
    }

    /// Only terminal runs can use the retry API. Pending tools keep their approval flow.
    /// A failed run on a model of unknown vision support lands here too, so the card
    /// can suggest a vision model or marking the model in settings.
    var imageRecoveryTarget: AskImageRecoveryTarget? {
        guard !hasPendingSubmission, let value = selected, let run = value.run,
              value.messages.contains(where: { $0.image != nil }) else { return nil }
        if let target = recoveringImage, target.conversationID == value.id { return target }
        guard ["failed", "cancelled"].contains(run.status),
              modelLibrary.imageCapability(run.modelRef ?? value.modelRef ?? "cloud:default") != .supported
                || screenshotCapability(launcher: false) != .supported else { return nil }
        return AskImageRecoveryTarget(conversationID: value.id, runID: run.id)
    }

    var canResumeImage: Bool {
        guard screenshotCapability(launcher: false) == .supported,
              let (provider, selectedModel) = modelLibrary.registry.resolve(modelReference(launcher: false)) else { return false }
        return modelLibrary.selectionReason(selectedModel, provider: provider, hasImage: true, loggedIn: true,
                                            confirmedVision: true) == nil
    }

    func resumeImage(_ target: AskImageRecoveryTarget, reference: String) {
        guard imageRecoveryTarget == target, selectedId == target.conversationID,
              selected?.run?.id == target.runID, !isBusy, !isLoadingSelection,
              modelLibrary.imageCapability(reference) == .supported else { return }
        selectModel(reference, launcher: false)
        resume()
    }
}
