import Foundation

extension AskConversationModel {
    /// One explicit clipboard mutation, after bounded read-only preparation. Never rerun the workflow.
    func copyWorkflowImage(_ url: URL, completed: @escaping @MainActor () -> Void,
                           prepare: (@Sendable (URL, String?) async throws -> AskWorkflowImage.Clipboard)? = nil,
                           write: @escaping @MainActor (URL, AskWorkflowImage.Clipboard) -> Bool = { AskQuickResults.copyImage($0, data: $1) }) {
        guard workflowImageCopyTask == nil else { return }
        let access = contextImageAccess(launcher: true), current = plugins, generation = plugins.resultGeneration
        guard access.allows(), let image = current.currentOutput?.image, image.url == url,
              current.isPlanCurrent else { return }
        let load = prepare ?? { [worker = workflowImageWorker] url, digest in
            try await AskWorkflowImage.clipboard(url, digest: digest, worker: worker)
        }
        workflowImageCopyTask = Task { [weak self] in
            guard let self else { return }
            defer { workflowImageCopyTask = nil }
            do {
                let data = try await load(url, image.digest)
                guard !Task.isCancelled, access.allows(), plugins === current,
                      current.resultGeneration == generation, current.currentOutput?.image == image,
                      current.isPlanCurrent else { return }
                guard write(url, data) else { confirm(L("ask.workflow.image.copyFailed")); return }
                finishPluginResult(); completed()
            } catch {
                if !Task.isCancelled, access.allows(), current.resultGeneration == generation {
                    confirm(L("ask.workflow.image.copyFailed"))
                }
            }
        }
    }
}
