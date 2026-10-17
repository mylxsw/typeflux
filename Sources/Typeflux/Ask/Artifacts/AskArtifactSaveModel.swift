import SwiftUI

/// One explicit destination choice and write. Memory ownership never replaces the final full load.
@MainActor final class AskArtifactSaveModel: ObservableObject {
    @Published private var error: String?
    private var source: AskArtifactPreviewSource?
    private var generation = UUID()

    func save(_ ref: AskArtifactRef, access: AskArtifactAccess,
              choose: (AskArtifactBundle) throws -> URL?,
              write: (AskArtifactBundle, URL) throws -> Void) {
        guard !Task.isCancelled else { return }
        let entry = generation
        let allowed = access.imageSource?.allows(ref) ?? true
        guard !Task.isCancelled, generation == entry else { return }
        if !allowed, let source {
            let original = source.access.imageSource?.allows(source.ref) ?? true
            guard !Task.isCancelled, generation == entry else { return }
            if original { return }
        }
        let current = UUID()
        let original = AskArtifactPreviewSource(ref: ref, access: access,
            isOwned: { [weak self] in self?.generation == current })
        generation = current; source = original; error = nil
        do {
            guard allowed else { throw AskArtifactError.denied }
            let initial = try access.load(ref)
            guard original.isCurrent(with: access) else { return }
            guard initial.manifest.ref == ref else { throw AskArtifactError.corrupt }
            let destination = try choose(initial)
            guard original.isCurrent(with: access), let destination else { return }
            // The modal may outlive grants or expiry. Keep the original full filesystem reload.
            let final = try access.load(ref)
            guard original.isCurrent(with: access) else { return }
            guard final.manifest.ref == ref, let bytes = final.files[final.manifest.entry],
                  AskToolPolicy.digest(bytes) == ref.sha256 else { throw AskArtifactError.corrupt }
            try write(final, destination)
            // An entered writer may already have changed its sink; never retry or roll it back.
            guard original.isCurrent(with: access) else { return }
            error = nil
        } catch {
            guard !Task.isCancelled, generation == current else { return }
            self.error = ((error as? AskArtifactError) ?? .unavailable).localizedDescription
        }
    }

    func projectedError(for ref: AskArtifactRef, access: AskArtifactAccess) -> String? {
        let current = generation
        guard let source, source.ref == ref,
              source.access.imageSource?.identity == access.imageSource?.identity else { return nil }
        let allowed = source.isCurrent(with: access)
        guard !Task.isCancelled, generation == current else { return nil }
        return allowed ? error : AskArtifactError.denied.localizedDescription
    }

    func cancel() {
        generation = UUID(); source = nil; error = nil
    }
}
