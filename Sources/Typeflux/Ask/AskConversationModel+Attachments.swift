import AppKit
import Foundation

extension AskConversationModel {
    func isLoadingAttachments(launcher: Bool) -> Bool {
        (attachmentLoads[visionDraftKey(launcher: launcher)] ?? 0) > 0
    }

    func attachmentNotice(launcher: Bool) -> String? {
        launcher ? launcherAttachmentNotice : attachmentNotice
    }

    func dismissAttachmentNotice(launcher: Bool) {
        if launcher { launcherAttachmentNotice = nil } else { attachmentNotice = nil }
    }

    /// Loads pasted, dropped or picked items off the main actor and adds them to
    /// the draft that was on screen when they arrived. A draft the user left in
    /// the meantime is not touched.
    func addAttachments(_ sources: [AskAttachmentSource], launcher: Bool,
                        load: @escaping @Sendable ([AskAttachmentSource]) -> AskAttachmentBatch = AskAttachmentBatch.load) {
        guard !sources.isEmpty else { return }
        let key = visionDraftKey(launcher: launcher)
        attachmentLoads[key, default: 0] += 1
        Task { [weak self] in
            let batch = await Task.detached(priority: .userInitiated) { load(sources) }.value
            guard let self else { return }
            let remaining = (attachmentLoads[key] ?? 1) - 1
            attachmentLoads[key] = remaining > 0 ? remaining : nil
            guard visionDraftKey(launcher: launcher) == key else { return }
            applyAttachments(batch, launcher: launcher)
        }
    }

    func applyAttachments(_ batch: AskAttachmentBatch, launcher: Bool) {
        var refusal = batch.failure
        if launcher { refusal = launcherDraft.append(batch.items) ?? refusal } else { refusal = draft.append(batch.items) ?? refusal }
        let message = refusal?.message
        if launcher { launcherAttachmentNotice = message } else { attachmentNotice = message }
        if batch.items.contains(where: { $0.kind == .image }) {
            switchToVisionModelIfNeeded(launcher: launcher, needsVision: true)
            if screenshotCapability(launcher: launcher) != .supported, message == nil {
                let hint = screenshotCapability(launcher: launcher).hint
                if launcher { launcherAttachmentNotice = hint } else { attachmentNotice = hint }
            }
        }
        persistDrafts()
    }

    func removeAttachment(_ id: String, launcher: Bool) {
        if launcher { launcherDraft.removeAttachment(id) } else { draft.removeAttachment(id) }
        dismissAttachmentNotice(launcher: launcher)
        persistDrafts()
    }

    /// Lets the user pick files and images, or folders, for the composer.
    func pickAttachments(folders: Bool, launcher: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = !folders
        panel.canChooseDirectories = folders
        panel.allowsMultipleSelection = true
        panel.message = L(folders ? "ask.attach.pickFolders" : "ask.attach.pickFiles")
        panel.prompt = L("ask.attach.add")
        // The launcher is a non-activating panel; the picker needs an active app.
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            self?.addAttachments(panel.urls.map { .file($0) }, launcher: launcher)
        }
    }
}

/// The attachments one paste, drop or pick produced, and the first failure.
struct AskAttachmentBatch: Equatable, Sendable {
    var items: [AskAttachment] = []
    var failure: AskAttachmentError?

    static func load(_ sources: [AskAttachmentSource]) -> AskAttachmentBatch {
        var batch = AskAttachmentBatch()
        for source in sources {
            do { batch.items += try AskAttachmentLoader.load(source) } catch let error as AskAttachmentError {
                batch.failure = batch.failure ?? error
            } catch {
                batch.failure = batch.failure ?? .unreadable(source.name)
            }
        }
        return batch
    }
}
