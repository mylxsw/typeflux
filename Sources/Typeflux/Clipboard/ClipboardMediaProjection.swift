import SwiftUI
import TypefluxMediaProtocol

@MainActor final class ClipboardMediaProjection: ObservableObject, AskImageScopeObserver {
    typealias Request = ClipboardMediaInfoProvider.Request
    typealias Load = @Sendable (Request) async throws -> MediaClipboardResult
    struct Identity: Hashable { let request: Request?; let epoch: UUID? }
    @Published private(set) var value: MediaClipboardResult?
    private var identity: Identity?
    private var originalAccess: AskImagePresentationAccess?
    private var generation = UUID()
    private var operation: Task<MediaClipboardResult, Error>?
    private weak var scope: AskImagePresentationScope?
    private var registration: UUID?
    private let read: Load
    init(read: @escaping Load = { try await ClipboardMediaInfoProvider.shared.load($0) }) { self.read = read }
    func displayed(_ request: Request?, access: AskImagePresentationAccess) -> MediaClipboardResult? {
        guard identity == Identity(request: request, epoch: access.epoch), access.allows(), originalAccess?.allows() == true else { return nil }
        return value
    }
    func cancel() {
        generation = UUID(); operation?.cancel(); operation = nil; value = nil; identity = nil; originalAccess = nil
        if let registration { scope?.remove(registration) }
        registration = nil; scope = nil
    }
    func load(_ request: Request?, access: AskImagePresentationAccess) async {
        guard !Task.isCancelled else { return }
        guard access.allows() else { if identity?.epoch == access.epoch { cancel() }; return }
        guard let request else { cancel(); return }
        let next = Identity(request: request, epoch: access.epoch)
        guard identity != next else { return }
        cancel(); identity = next; originalAccess = access
        let current = generation
        do {
            guard let scope = access.scope, let epoch = access.epoch else { throw MediaFailure.unavailable }
            self.scope = scope; registration = try scope.register(self, epoch: epoch)
            let task = Task { [read] in try await read(request) }; operation = task
            let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            try Task.checkCancellation()
            guard current == generation else { return }
            guard access.allows() else { cancel(); return }
            try result.validate(for: request.options)
            value = result; operation = nil
        } catch {
            guard current == generation else { return }
            operation = nil; value = nil
            // Keep the attempted identity to avoid retries from body recomputation.
            if Task.isCancelled || !access.allows() { cancel() }
        }
    }
}

/// A stable view owns observation and task cancellation, including when its panel survives hiding.
struct ClipboardMediaValue<Content: View>: View {
    let request: ClipboardMediaInfoProvider.Request?
    @Environment(\.askContextImageAccess) private var access
    @StateObject private var model: ClipboardMediaProjection
    let content: (MediaClipboardResult?) -> Content
    init(request: ClipboardMediaInfoProvider.Request?, model: ClipboardMediaProjection? = nil,
         @ViewBuilder content: @escaping (MediaClipboardResult?) -> Content) {
        self.request = request; self.content = content; _model = StateObject(wrappedValue: model ?? ClipboardMediaProjection())
    }
    var body: some View {
        ZStack { content(model.displayed(request, access: access)) }
            .task(id: ClipboardMediaProjection.Identity(request: request, epoch: access.epoch)) { await model.load(request, access: access) }
            .onDisappear { model.cancel() }
    }
}
