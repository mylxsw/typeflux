import SwiftUI
import TypefluxMediaProtocol

/// Read-only presentation. Neither the transport nor decoder can invoke the producer.
struct AskRemoteImageLoader: Sendable {
    typealias Decoder = @Sendable (Data) async throws -> AskFilePreviewPDF.Result
    static let maximumBytes = 16 * 1024 * 1024
    private static let admission = AskToolPixelBudget(limit: 2)
    var transport: any AskImageTransport = AskImageHTTP(maximumRedirects: 3)
    var decode: Decoder? = nil
    var worker: MediaWorker = .previews
    var cache: AskGeneratedImageCache = .shared

    /// Custom decoders keep their own contract; default presentation retains its native epoch.
    func authorization() -> MediaWorker.Authorization? { decode == nil ? worker.authorization() : nil }

    static func eligible(_ image: AskGeneratedImage) -> URL? {
        guard !image.assetId.isEmpty, image.assetId.utf8.count <= 1024,
              image.url.utf8.count <= 16 * 1024 else { return nil }
        return image.safeURL
    }

    func load(_ image: AskGeneratedImage, authorization original: MediaWorker.Authorization? = nil,
              owner: String? = nil, forceDownload: Bool = false) async throws -> AskFilePreviewPDF.Result {
        try Task.checkCancellation()
        guard let url = Self.eligible(image) else { throw MediaFailure.unreadable }
        let authorization = decode == nil ? (original ?? worker.authorization()) : nil
        let current: @Sendable () -> Bool = { [worker] in authorization.map { worker.permits($0) } ?? true }
        guard current() else { throw MediaFailure.unavailable }
        let ticket: AskGeneratedImageCache.Ticket?
        if let owner, !owner.isEmpty { ticket = try? await cache.lookup(owner: owner, asset: image.assetId, force: forceDownload) }
        else { ticket = nil }
        if let ticket, let data = ticket.data {
            do {
                let result = try await pixels(data, authorization: authorization)
                try Task.checkCancellation()
                guard current() else { throw MediaFailure.unavailable }
                return result
            } catch {
                // Service outages and cancellation do not invalidate a good disk copy.
                guard let failure = error as? MediaFailure,
                      [.unreadable, .invalidProtocol, .tooLarge].contains(failure) else { throw error }
                try? await cache.remove(ticket)
            }
        }
        let data: Data
        if let ticket { data = try await cache.download(ticket: ticket) { try await fetch(url, authorization: authorization) } }
        else { data = try await fetch(url, authorization: authorization) }
        try Task.checkCancellation()
        guard current() else { throw MediaFailure.unavailable }
        let result = try await pixels(data, authorization: authorization)
        try Task.checkCancellation()
        guard current() else { throw MediaFailure.unavailable }
        if let ticket { try? await cache.store(data, ticket: ticket) }
        return result
    }

    private func pixels(_ data: Data, authorization: MediaWorker.Authorization?) async throws -> AskFilePreviewPDF.Result {
        guard !data.isEmpty, data.count <= Self.maximumBytes else { throw MediaFailure.unreadable }
        let result: AskFilePreviewPDF.Result
        if let decode { result = try await decode(data) }
        else { result = try await Self.decodePixels(data, worker: worker, authorization: authorization) }
        guard result.images.count == 1, let pixels = result.images.first,
              pixels.width > 0, pixels.height > 0, pixels.width <= 1600, pixels.height <= 1600 else {
            throw MediaFailure.invalidProtocol
        }
        return result
    }

    private func fetch(_ url: URL, authorization: MediaWorker.Authorization?) async throws -> Data {
        let slot = try Self.admission.acquire(bytes: 1)
        defer { withExtendedLifetime(slot) {} }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpMethod = "GET"
        do { return try await transport.send(request, limit: Self.maximumBytes) }
        catch {
            guard Self.shouldRetryDownload(error) else { throw error }
            try await Task.sleep(for: .milliseconds(300))
            try Task.checkCancellation()
            if let authorization, !worker.permits(authorization) { throw MediaFailure.unavailable }
            return try await transport.send(request, limit: Self.maximumBytes)
        }
    }

    static func shouldRetryDownload(_ error: Error) -> Bool {
        guard let network = error as? URLError else { return false }
        if [.timedOut, .networkConnectionLost, .cannotConnectToHost].contains(network.code) { return true }
        guard network.code == .secureConnectionFailed else { return false }
        // errSSLClosedNoNotify means a peer closed the connection. Certificate errors
        // are deliberately excluded; every attempt still uses normal TLS validation.
        let info = (error as NSError).userInfo
        let underlying = info[NSUnderlyingErrorKey] as? NSError
        return (info["_kCFStreamErrorCodeKey"] as? Int == -9816) ||
            (underlying?.userInfo["_kCFStreamErrorCodeKey"] as? Int == -9816)
    }

    static func decodePixels(_ data: Data) async throws -> AskFilePreviewPDF.Result {
        try await decodePixels(data, worker: .previews, authorization: nil)
    }

    static func decodePixels(_ data: Data, worker: MediaWorker,
                             authorization: MediaWorker.Authorization? = nil) async throws -> AskFilePreviewPDF.Result {
        try Task.checkCancellation()
        let authorization = authorization ?? worker.authorization()
        guard worker.permits(authorization) else { throw MediaFailure.unavailable }
        let cancellation = AskSearchCancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let result = try await Task.detached(priority: .utility) {
                if cancellation.isCancelled || !worker.permits(authorization) { throw CancellationError() }
                // Type is detected only inside the media child. HTTP headers confer no validation proof.
                return try MediaPreviewDisplay.renderImage(data, type: nil, cancellation: cancellation, worker: worker,
                                                           authorization: authorization)
            }.value
            try Task.checkCancellation()
            guard worker.permits(authorization) else { throw MediaFailure.unavailable }
            return result
        } onCancel: { cancellation.cancel() }
    }
}

/// Bounded, weak view registrations allow revocation to clear already displayed pixels too.
@MainActor protocol AskImageScopeObserver: AnyObject { func cancel() }

@MainActor final class AskImagePresentationScope {
    /// Small native icons use the shared pixel budget, so they do not need the
    /// separate 16-view ceiling that protects full-size image presentations.
    enum RegistrationKind { case standard, smallIcon }
    private struct Observer {
        weak var model: (any AskImageScopeObserver)?
        let kind: RegistrationKind
    }
    private var observers: [UUID: Observer] = [:]
    private(set) var epoch = UUID()
    private(set) var visible = true
    func register(_ model: any AskImageScopeObserver, epoch: UUID,
                  kind: RegistrationKind = .standard) throws -> UUID {
        observers = observers.filter { $0.value.model != nil }
        let standardCount = observers.values.filter { $0.kind == .standard }.count
        guard visible, self.epoch == epoch, kind == .smallIcon || standardCount < 16 else {
            throw MediaFailure.unavailable
        }
        let id = UUID(); observers[id] = Observer(model: model, kind: kind); return id
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
    var cacheOwner: String? = nil
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
        return .init(cacheOwner: current.owner, scope: remoteImageScope, epoch: remoteImageScope.epoch, authorize: { [weak self] in
            guard let self, let live = self.session() else { return false }
            return live.owner == current.owner && live.token == current.token && self.selectedId == conversation &&
                self.selectionGeneration == generation && !self.isDeletedConversation(conversation)
        })
    }
    func invalidateRemoteImages() {
        releaseLauncherScreenshot()
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
    @Published private(set) var failureDetail: String?
    private var generation = UUID()
    private var registration: UUID?
    private weak var scope: AskRemoteImageScope?
    private var originalAccess: AskRemoteImageAccess?
    private var operation: Task<AskFilePreviewPDF.Result, Error>?
    private var pixels: AskToolPixelBudget.Lease?
    private let budget: AskToolPixelBudget
    private let loader: AskRemoteImageLoader
    init(loader: AskRemoteImageLoader = .init(), budget: AskToolPixelBudget = .shared) {
        self.loader = loader; self.budget = budget
    }
    func displayed(_ asset: AskGeneratedImage, access: AskRemoteImageAccess) -> NSImage? {
        guard source == asset, scope === access.scope, originalAccess?.epoch == access.epoch,
              originalAccess?.allows() == true, access.allows() else { return nil }
        return image
    }
    func cancel() {
        generation = UUID(); operation?.cancel(); operation = nil
        if let registration { scope?.remove(registration) }
        registration = nil; scope = nil; originalAccess = nil; source = nil; image = nil; pixels = nil; unavailable = false; failureDetail = nil
    }
    func load(_ asset: AskGeneratedImage, access: AskRemoteImageAccess, forceDownload: Bool = false) async {
        guard !Task.isCancelled else { return }
        let allowed = access.allows()
        guard !Task.isCancelled else { return }
        guard allowed else {
            // A stale denied invocation cannot revoke a different, still-authorized projection.
            if originalAccess?.allows() != true { cancel() }
            return
        }
        let retainingImage = displayed(asset, access: access) != nil
        if retainingImage && !forceDownload { return }
        if retainingImage {
            generation = UUID(); operation?.cancel(); operation = nil
            failureDetail = nil; unavailable = false
        } else { cancel() }
        let current = generation
        source = asset; originalAccess = access
        do {
            try Task.checkCancellation()
            guard let scope = access.scope, let epoch = access.epoch else { throw MediaFailure.unavailable }
            if !retainingImage {
                self.scope = scope; registration = try scope.register(self, epoch: epoch)
            }
            let authorization = loader.authorization()
            let reservation = try budget.acquire(bytes: 1600 * 1600 * 4)
            let task = Task { [loader] in
                defer { withExtendedLifetime(reservation) {} }
                return try await loader.load(asset, authorization: authorization, owner: access.cacheOwner, forceDownload: forceDownload)
            }
            operation = task
            let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            try Task.checkCancellation()
            guard current == generation else { return }
            guard access.allows() else { cancel(); return }
            if let authorization, !loader.worker.permits(authorization) { throw MediaFailure.unavailable }
            pixels = reservation
            image = NSImage(cgImage: result.images[0], size: .zero)
            operation = nil
        } catch {
            guard current == generation else { return }
            if !Task.isCancelled && access.allows() {
                // Keep ownership of the failed presentation until an explicit replacement or revocation.
                operation = nil
                if !retainingImage { pixels = nil; image = nil; unavailable = true }
                failureDetail = Self.failureDescription(error)
                AskFailureDiagnostics.shared.record(.imageLoad, error: error)
            } else if retainingImage && access.allows() { operation = nil }
            else { cancel() }
        }
    }
    static func failureDescription(_ error: Error) -> String {
        if let network = error as? URLError {
            if network.code == .timedOut { return L("ask.image.load.timeout") }
            if [.secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
                .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid].contains(network.code) {
                return L("ask.image.load.secureConnection")
            }
            return L("ask.image.load.network")
        }
        if case let AskImageError.http(status) = error { return L("ask.image.load.http", status) }
        if let media = error as? MediaFailure, media == .unavailable { return L("ask.image.load.previewUnavailable") }
        return L("ask.image.load.decode")
    }

}

struct AskRemoteImageView: View {
    let asset: AskGeneratedImage
    var enabled = true
    @Environment(\.askRemoteImageAccess) private var access
    @Environment(\.askEditGeneratedImage) private var editImage
    @StateObject private var model: AskRemoteImageModel
    @State private var reload = 0
    @State private var forceDownload = false
    @State private var preview = false
    @State private var saveError: String?
    init(asset: AskGeneratedImage, enabled: Bool = true, loader: AskRemoteImageLoader = .init(), model: AskRemoteImageModel? = nil) {
        self.asset = asset; self.enabled = enabled; _model = StateObject(wrappedValue: model ?? AskRemoteImageModel(loader: loader))
    }
    private struct Identity: Hashable { let asset: String; let url: String; let epoch: UUID?; let enabled: Bool; let reload: Int }
    private var taskIdentity: Identity { .init(asset: asset.assetId, url: asset.url, epoch: access.epoch, enabled: enabled, reload: reload) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if access.allows(), let url = AskRemoteImageLoader.eligible(asset) {
                if let image = model.displayed(asset, access: access) {
                    Button { preview = true } label: {
                        Image(nsImage: image).resizable().scaledToFit()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .aspectRatio(1, contentMode: .fit)
                            .background(StudioTheme.textPrimary.opacity(0.035))
                            .clipShape(RoundedRectangle(cornerRadius: 18))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L("ask.preview"))
                    .accessibilityIdentifier("ask.generatedImage.preview")
                    HStack(spacing: 16) {
                        Button {
                            guard let current = model.displayed(asset, access: access) else { return }
                            do { try AskArtifactActions.save(current) } catch { saveError = error.localizedDescription }
                        } label: { Label(L("ask.image.save"), systemImage: "arrow.down.to.line") }
                        Button(L("ask.image.redownload")) { forceDownload = true; reload += 1 }
                        if let editImage {
                            Button { if access.allows() { editImage(asset) } }
                                label: { Label(L("ask.image.edit"), systemImage: "pencil") }
                        }
                    }
                    .buttonStyle(.plain).font(.system(size: 12.5)).foregroundStyle(StudioTheme.textSecondary)
                } else if model.unavailable || !enabled {
                    AskImagePlaceholder(title: L("ask.image.generatedLoadFailed"), detail: model.failureDetail,
                                        hint: L("ask.image.reloadHint"), spinning: false)
                    HStack(spacing: 16) {
                        if enabled { Button(L("ask.image.reload")) { forceDownload = false; reload += 1 } }
                        if enabled { Button(L("ask.image.redownload")) { forceDownload = true; reload += 1 } }
                        Link(L("ask.preview"), destination: url)
                    }.font(.system(size: 12.5))
                } else {
                    AskImagePlaceholder(title: L("ask.image.generatedLoading"), detail: nil,
                                        hint: L("ask.image.loadingHint"), spinning: true)
                }
                if model.displayed(asset, access: access) != nil, let detail = model.failureDetail {
                    Text(detail).font(.system(size: 12)).foregroundStyle(StudioTheme.textSecondary)
                }
                if let saveError { Text(saveError).font(.system(size: 12)).foregroundStyle(.red) }
            }
        }
        .frame(maxWidth: 400, alignment: .leading)
        // Keep presentation attached to the stable container, not the conditional image branch.
        .popover(isPresented: $preview) {
            if let displayed = model.displayed(asset, access: access) {
                VStack(alignment: .trailing, spacing: 8) {
                    Button { preview = false } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("ask.generatedImage.preview.close")
                    Image(nsImage: displayed).resizable().scaledToFit()
                        .frame(width: 720, height: 540)
                        .accessibilityIdentifier("ask.generatedImage.preview.pixels")
                }.padding(12)
            }
        }
        .task(id: taskIdentity) {
            if enabled {
                let force = forceDownload
                forceDownload = false
                await model.load(asset, access: access, forceDownload: force)
            } else { model.cancel() }
        }
        .onDisappear { model.cancel(); preview = false }
    }
}
