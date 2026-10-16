import SwiftUI

/// A retained bundle's original memory condition, never a filesystem or export grant.
@MainActor struct AskArtifactPreviewSource {
    let ref: AskArtifactRef
    let access: AskArtifactAccess
    private let isOwned: @MainActor () -> Bool

    init(ref: AskArtifactRef, access: AskArtifactAccess, isOwned: @escaping @MainActor () -> Bool = { true }) {
        self.ref = ref; self.access = access; self.isOwned = isOwned
    }

    func isCurrent(with fresh: AskArtifactAccess) -> Bool {
        guard !Task.isCancelled, isOwned(), access.imageSource?.identity == fresh.imageSource?.identity else { return false }
        let incoming = fresh.imageSource?.allows(ref) ?? true
        guard !Task.isCancelled, isOwned() else { return false }
        // Sample the retained source last; fresh access cannot revive an old bundle.
        let original = access.imageSource?.allows(ref) ?? true
        return !Task.isCancelled && isOwned() && incoming && original
    }
}

/// Explicit synchronous preview loads only. Projection and dismissal perform no artifact I/O.
@MainActor final class AskArtifactPreviewModel: ObservableObject {
    struct Loaded {
        let bundle: AskArtifactBundle
        let source: AskArtifactPreviewSource
    }
    struct Projection {
        var preview: Loaded?
        var error: String?
    }
    @Published private var bundle: AskArtifactBundle?
    @Published private var error: String?
    private var source: AskArtifactPreviewSource?
    private var generation = UUID()

    func open(_ ref: AskArtifactRef, access: AskArtifactAccess) {
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
        let original = AskArtifactPreviewSource(ref: ref, access: access, isOwned: { [weak self] in self?.generation == current })
        generation = current; source = original; bundle = nil; error = nil
        do {
            guard allowed else { throw AskArtifactError.denied }
            let loaded = try access.load(ref)
            guard !Task.isCancelled, generation == current else { return }
            guard loaded.manifest.ref == ref else { throw AskArtifactError.corrupt }
            guard original.isCurrent(with: access) else { return }
            bundle = loaded
        } catch {
            guard !Task.isCancelled, generation == current else { return }
            self.error = ((error as? AskArtifactError) ?? .unavailable).localizedDescription
        }
    }

    func projection(for ref: AskArtifactRef, access: AskArtifactAccess) -> Projection {
        let empty = Projection(), current = generation
        guard let source, source.ref == ref, source.access.imageSource?.identity == access.imageSource?.identity else { return empty }
        let allowed = source.isCurrent(with: access)
        guard !Task.isCancelled, generation == current else { return empty }
        guard allowed else { return .init(error: AskArtifactError.denied.localizedDescription) }
        return .init(preview: bundle.map { .init(bundle: $0, source: source) }, error: error)
    }

    func close() {
        generation = UUID(); source = nil; bundle = nil; error = nil
    }
}
