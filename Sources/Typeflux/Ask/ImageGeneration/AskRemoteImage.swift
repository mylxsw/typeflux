import SwiftUI
import TypefluxMediaProtocol

/// Read-only presentation. Neither the transport nor decoder can invoke the producer.
struct AskRemoteImageLoader: Sendable {
    typealias Decoder = @Sendable (Data) async throws -> AskFilePreviewPDF.Result
    static let maximumBytes = 16 * 1024 * 1024
    private static let admission = AskToolPixelBudget(limit: 2)
    var transport: any AskImageTransport = AskImageHTTP(maximumRedirects: 3)
    var decode: Decoder = { try await decodePixels($0) }

    static func eligible(_ image: AskGeneratedImage) -> URL? {
        guard !image.assetId.isEmpty, image.assetId.utf8.count <= 1024,
              image.url.utf8.count <= 16 * 1024 else { return nil }
        return image.safeURL
    }

    func load(_ image: AskGeneratedImage) async throws -> AskFilePreviewPDF.Result {
        try Task.checkCancellation()
        guard let url = Self.eligible(image) else { throw MediaFailure.unreadable }
        let slot = try Self.admission.acquire(bytes: 1)
        defer { withExtendedLifetime(slot) {} }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpMethod = "GET"
        let data = try await transport.send(request, limit: Self.maximumBytes)
        try Task.checkCancellation()
        guard !data.isEmpty, data.count <= Self.maximumBytes else { throw MediaFailure.unreadable }
        let result = try await decode(data)
        try Task.checkCancellation()
        guard result.images.count == 1, let pixels = result.images.first,
              pixels.width > 0, pixels.height > 0, pixels.width <= 1600, pixels.height <= 1600 else {
            throw MediaFailure.invalidProtocol
        }
        return result
    }

    static func decodePixels(_ data: Data) async throws -> AskFilePreviewPDF.Result {
        let cancellation = AskSearchCancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await Task.detached(priority: .utility) {
                // Type is detected only inside the media child. HTTP headers confer no validation proof.
                try MediaPreviewDisplay.renderImage(data, type: nil, cancellation: cancellation)
            }.value
        } onCancel: { cancellation.cancel() }
    }
}

/// Bounded, weak view registrations allow revocation to clear already displayed pixels too.
@MainActor protocol AskImageScopeObserver: AnyObject { func cancel() }

@MainActor final class AskImagePresentationScope {
    private struct Observer { weak var model: (any AskImageScopeObserver)? }
    private var observers: [UUID: Observer] = [:]
    private(set) var epoch = UUID()
    private(set) var visible = true
    func register(_ model: any AskImageScopeObserver, epoch: UUID) throws -> UUID {
        observers = observers.filter { $0.value.model != nil }
        guard visible, self.epoch == epoch, observers.count < 16 else { throw MediaFailure.unavailable }
        let id = UUID(); observers[id] = Observer(model: model); return id
    }
    func remove(_ id: UUID) { observers[id] = nil }
    func invalidate() {
        epoch = UUID()
        let previous = observers; observers.removeAll()
        for observer in previous.values { observer.model?.cancel() }
    }
    func setVisible(_ value: Bool) {
        guard visible != value else { return }
        visible = value; invalidate()
    }
}

typealias AskRemoteImageScope = AskImagePresentationScope
typealias AskRemoteImageAccess = AskImagePresentationAccess

struct AskImagePresentationAccess {
    var scope: AskRemoteImageScope?
    var epoch: UUID?
    var authorize: @MainActor () -> Bool = { false }
    @MainActor func allows() -> Bool {
        guard let scope, scope.visible, scope.epoch == epoch else { return false }
        return authorize()
    }
}
private struct AskRemoteImageAccessKey: EnvironmentKey { static let defaultValue = AskRemoteImageAccess() }
extension EnvironmentValues {
    var askRemoteImageAccess: AskRemoteImageAccess {
        get { self[AskRemoteImageAccessKey.self] }
        set { self[AskRemoteImageAccessKey.self] = newValue }
    }
}

extension AskConversationModel {
    var remoteImageAccess: AskRemoteImageAccess {
        guard let current = session(), let conversation = selectedId, !isDeletedConversation(conversation) else { return .init() }
        let generation = selectionGeneration
        return .init(scope: remoteImageScope, epoch: remoteImageScope.epoch, authorize: { [weak self] in
            guard let self, let live = self.session() else { return false }
            return live.owner == current.owner && live.token == current.token && self.selectedId == conversation &&
                self.selectionGeneration == generation && !self.isDeletedConversation(conversation)
        })
    }
    func invalidateRemoteImages() {
        workflowImageCopyTask?.cancel()
        remoteImageScope.invalidate(); conversationImageScope.invalidate(); launcherImageScope.invalidate(); objectWillChange.send()
    }
    func setRemoteImagesVisible(_ visible: Bool) {
        remoteImageScope.setVisible(visible); conversationImageScope.setVisible(visible); objectWillChange.send()
    }
}

@MainActor final class AskRemoteImageModel: ObservableObject, AskImageScopeObserver {
    @Published private(set) var source: AskGeneratedImage?
    @Published private(set) var image: NSImage?
    @Published private(set) var unavailable = false
    private var generation = UUID()
    private var registration: UUID?
    private weak var scope: AskRemoteImageScope?
    private var operation: Task<AskFilePreviewPDF.Result, Error>?
    private var pixels: AskToolPixelBudget.Lease?
    private let budget: AskToolPixelBudget
    private let loader: AskRemoteImageLoader
    init(loader: AskRemoteImageLoader = .init(), budget: AskToolPixelBudget = .shared) {
        self.loader = loader; self.budget = budget
    }
    func cancel() {
        generation = UUID(); operation?.cancel(); operation = nil
        if let registration { scope?.remove(registration) }
        registration = nil; scope = nil; source = nil; image = nil; pixels = nil; unavailable = false
    }
    func load(_ asset: AskGeneratedImage, access: AskRemoteImageAccess) async {
        cancel()
        let current = generation
        source = asset
        do {
            try Task.checkCancellation()
            guard access.allows(), let scope = access.scope, let epoch = access.epoch else { throw MediaFailure.unavailable }
            self.scope = scope; registration = try scope.register(self, epoch: epoch)
            let reservation = try budget.acquire(bytes: 1600 * 1600 * 4)
            let task = Task { [loader] in
                defer { withExtendedLifetime(reservation) {} }
                return try await loader.load(asset)
            }
            operation = task
            let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            try Task.checkCancellation()
            guard current == generation else { return }
            guard access.allows() else { cancel(); return }
            pixels = reservation
            image = NSImage(cgImage: result.images[0], size: .zero)
            operation = nil
        } catch {
            guard current == generation else { return }
            cancel()
            unavailable = !Task.isCancelled && access.allows()
        }
    }
}

struct AskRemoteImageView: View {
    let asset: AskGeneratedImage
    var enabled = true
    @Environment(\.askRemoteImageAccess) private var access
    @StateObject private var model: AskRemoteImageModel
    init(asset: AskGeneratedImage, enabled: Bool = true, loader: AskRemoteImageLoader = .init(), model: AskRemoteImageModel? = nil) {
        self.asset = asset; self.enabled = enabled; _model = StateObject(wrappedValue: model ?? AskRemoteImageModel(loader: loader))
    }
    private struct Identity: Hashable { let asset: String; let url: String; let epoch: UUID?; let enabled: Bool }
    private var taskIdentity: Identity { .init(asset: asset.assetId, url: asset.url, epoch: access.epoch, enabled: enabled) }
    var body: some View {
        ZStack {
            if access.allows(), let url = AskRemoteImageLoader.eligible(asset) {
                Link(destination: url) {
                    if model.source == asset, let image = model.image {
                        Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: 480, maxHeight: 360)
                    } else if model.unavailable || !enabled {
                        Label(L("ask.preview"), systemImage: "photo")
                    } else {
                        ProgressView().frame(width: 240, height: 160)
                    }
                }.accessibilityLabel(L("ask.preview"))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .task(id: taskIdentity) { if enabled { await model.load(asset, access: access) } else { model.cancel() } }
        .onDisappear { model.cancel() }
    }
}
