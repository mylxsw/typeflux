import Foundation

enum AskImageCapability: Equatable {
    case supported, unsupported, unknown, unavailable

    var hint: String? {
        switch self {
        case .supported: return nil
        case .unsupported: return L("ask.image.unsupported")
        case .unknown: return L("ask.image.unknown")
        case .unavailable: return L("ask.models.unavailable")
        }
    }
}

extension AskModelLibrary {
    func imageCapability(_ reference: String) -> AskImageCapability {
        guard let (_, model) = registry.resolve(reference) else { return .unavailable }
        guard let vision = model.vision else { return .unknown }
        return vision ? .supported : .unsupported
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
        if screenshotCapability(launcher: true) != .supported, launcherDraft.includeScreenshot {
            launcherDraft.includeScreenshot = false
        }
        if screenshotCapability(launcher: false) != .supported, draft.includeScreenshot {
            draft.includeScreenshot = false
        }
    }

    func selectModel(_ reference: String, launcher: Bool) {
        let wasAttached = launcher ? launcherDraft.includeScreenshot : draft.includeScreenshot
        if launcher { launcherDraft.modelRef = reference } else { draft.modelRef = reference }
        let notice = wasAttached && screenshotCapability(launcher: launcher) != .supported
            ? L("ask.image.detached") : nil
        if launcher { launcherScreenshotNotice = notice } else { screenshotNotice = notice }
        if !launcher, imageRecoveryTarget != nil { error = nil }
        persistDrafts()
    }

    /// Only terminal runs can use the retry API. Pending tools keep their approval flow.
    var imageRecoveryTarget: AskImageRecoveryTarget? {
        guard let value = selected, let run = value.run,
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
        return modelLibrary.selectionReason(selectedModel, provider: provider, hasImage: true, loggedIn: true) == nil
    }

    func resumeImage(_ target: AskImageRecoveryTarget, reference: String) {
        guard imageRecoveryTarget == target, selectedId == target.conversationID,
              selected?.run?.id == target.runID, !isBusy, !isLoadingSelection,
              modelLibrary.imageCapability(reference) == .supported else { return }
        selectModel(reference, launcher: false)
        resume()
    }
}
