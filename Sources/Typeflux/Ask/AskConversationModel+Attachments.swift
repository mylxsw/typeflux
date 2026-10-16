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
                        load: (@Sendable ([AskAttachmentSource]) -> AskAttachmentBatch)? = nil) {
        guard !sources.isEmpty else { return }
        guard attachmentWork.count < 2 else {
            if launcher { launcherAttachmentNotice = AskAttachmentError.busy.message }
            else { attachmentNotice = AskAttachmentError.busy.message }
            return
        }
        let key = visionDraftKey(launcher: launcher)
        let presentation = launcherPresentationID
        let generation = selectionGeneration
        let id = UUID()
        let sourceCount = sources.count
        attachmentLoads[key, default: 0] += 1
        let boundedSources = Array(sources.prefix(AskAttachmentLimits.maximumItems + AskAttachmentLimits.maximumFolders))
        let work = Task.detached(priority: .userInitiated) {
            load?(boundedSources) ?? AskAttachmentBatch.load(boundedSources, isCancelled: { Task.isCancelled })
        }
        attachmentWork.insert(id, launcher: launcher, cancel: { work.cancel() })
        Task { [weak self] in
            var batch = await work.value
            guard let self, attachmentWork.remove(id) else { return }
            let remaining = (attachmentLoads[key] ?? 1) - 1
            attachmentLoads[key] = remaining > 0 ? remaining : nil
            guard !work.isCancelled, launcher ? launcherPresentationID == presentation : selectionGeneration == generation else { return }
            guard visionDraftKey(launcher: launcher) == key else { return }
            if sourceCount > boundedSources.count { batch.failure = batch.failure ?? .tooMany }
            applyAttachments(batch, launcher: launcher)
        }
    }

    func cancelAttachmentWork(launcher: Bool? = nil) {
        attachmentWork.cancel(launcher: launcher)
        if let launcher { attachmentLoads[visionDraftKey(launcher: launcher)] = nil }
        else { attachmentLoads = [:] }
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

    static func load(_ sources: [AskAttachmentSource], isCancelled: @escaping @Sendable () -> Bool = { false }) -> AskAttachmentBatch {
        var batch = AskAttachmentBatch()
        for source in sources {
            if isCancelled() { break }
            do {
                for item in try AskAttachmentLoader.load(source, isCancelled: isCancelled) {
                    if let refusal = AskDraft.refusal(for: item, in: batch.items, screenshot: false) {
                        batch.failure = batch.failure ?? refusal
                    } else { batch.items.append(item) }
                }
            } catch let error as AskAttachmentError {
                batch.failure = batch.failure ?? error
            } catch {
                batch.failure = batch.failure ?? .unreadable(source.name)
            }
        }
        return batch
    }
}

/// A UI lifetime owns cancellation without a task retaining its model.
final class AskAttachmentWork {
    private var entries: [UUID: (launcher: Bool, cancelled: Bool, cancel: () -> Void)] = [:]
    var count: Int { entries.count }
    func insert(_ id: UUID, launcher: Bool, cancel: @escaping () -> Void) { entries[id] = (launcher, false, cancel) }
    func remove(_ id: UUID) -> Bool { entries.removeValue(forKey: id).map { !$0.cancelled } ?? false }
    func cancel(launcher: Bool? = nil) {
        let ids = entries.keys.filter { launcher == nil || entries[$0]?.launcher == launcher }
        for id in ids { entries[id]?.cancelled = true; entries[id]?.cancel() }
    }
    deinit { entries.values.forEach { $0.cancel() } }
}
