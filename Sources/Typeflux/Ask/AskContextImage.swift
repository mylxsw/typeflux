import SwiftUI
import TypefluxMediaProtocol

/// Bounded local presentation only. Original encoded content stays with its draft/message.
enum AskContextImageDecoder {
    typealias InputReader = @Sendable (String) throws -> (Data, MediaImageType)
    static let maximumEncodedBytes = 16 * 1024 * 1024
    private static let admission = AskToolPixelBudget(limit: 2)
    static func input(_ value: String) throws -> (Data, MediaImageType) {
        guard value.utf8.count <= maximumEncodedBytes, value.hasPrefix("data:"),
              let comma = value.firstIndex(of: ","), value[..<comma].hasSuffix(";base64"),
              let type = MediaImageType(rawValue: String(value[value.index(value.startIndex, offsetBy: 5)..<comma].dropLast(7))),
              let data = Data(base64Encoded: String(value[value.index(after: comma)...])), !data.isEmpty else {
            throw MediaFailure.unreadable
        }
        return (data, type)
    }
    static func decode(_ value: String, worker: MediaWorker = .previews,
                       authorization original: MediaWorker.Authorization? = nil,
                       readInput: @escaping InputReader = { try input($0) }) async throws -> AskFilePreviewPDF.Result {
        try Task.checkCancellation()
        let authorization = original ?? worker.authorization()
        guard worker.permits(authorization) else { throw MediaFailure.unavailable }
        let slot = try admission.acquire(bytes: 1)
        defer { withExtendedLifetime(slot) {} }
        let cancellation = AskSearchCancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let result = try await Task.detached(priority: .utility) {
                guard !cancellation.isCancelled, worker.permits(authorization) else { throw CancellationError() }
                let (data, type) = try readInput(value)
                guard !cancellation.isCancelled, worker.permits(authorization) else { throw CancellationError() }
                return try MediaPreviewDisplay.renderImage(data, type: type, cancellation: cancellation, worker: worker,
                                                           authorization: authorization)
            }.value
            try Task.checkCancellation()
            guard worker.permits(authorization) else { throw MediaFailure.unavailable }
            return result
        } onCancel: { cancellation.cancel() }
    }
}

private struct AskContextImageAccessKey: EnvironmentKey { static let defaultValue = AskImagePresentationAccess() }
extension EnvironmentValues {
    var askContextImageAccess: AskImagePresentationAccess {
        get { self[AskContextImageAccessKey.self] }
        set { self[AskContextImageAccessKey.self] = newValue }
    }
}

extension AskConversationModel {
    /// Local drafts are available without cloud login, but cannot cross account/selection boundaries.
    func contextImageAccess(launcher: Bool) -> AskImagePresentationAccess {
        let current = session(), selection = selectedId
        let generation = launcher ? launcherPresentationID : selectionGeneration
        let scope = launcher ? launcherImageScope : conversationImageScope
        return .init(scope: scope, epoch: scope.epoch, authorize: { [weak self] in
            guard let self else { return false }
            let live = self.session()
            return self.owner == (current?.owner ?? "") && current?.owner == live?.owner && current?.token == live?.token &&
                generation == (launcher ? self.launcherPresentationID : self.selectionGeneration) &&
                (launcher || (self.selectedId == selection && !(selection.map(self.isDeletedConversation) ?? false)))
        })
    }
    func setLauncherImagesVisible(_ visible: Bool) {
        if !visible { workflowImageCopyTask?.cancel(); clipboardAction.cancelPreparation() }
        if !visible {
            launcherIconWarmupEnabled = false
            launcherIconCache.suspendApplicationWarmup()
            launcherIconCache.cancelPrefetch()
            launcherIconCache.clearFiles()
        } else if !launcherIconWarmupEnabled {
            launcherIconWarmupEnabled = true
            prepareLauncherAppIcons()
        }
        launcherImageScope.setVisible(visible); objectWillChange.send()
    }
}

@MainActor final class AskContextImageModel: ObservableObject, AskImageScopeObserver {
    typealias Decoder = @Sendable (String) async throws -> AskFilePreviewPDF.Result
    struct Identity: Hashable { let source: String?; let epoch: UUID? }
    @Published private(set) var image: NSImage?
    @Published private(set) var unavailable = false
    private var source: String?
    private var epoch: UUID?
    private var originalAccess: AskImagePresentationAccess?
    private var generation = UUID()
    private weak var scope: AskImagePresentationScope?
    private var registration: UUID?
    private var operation: Task<AskFilePreviewPDF.Result, Error>?
    private var pixels: AskToolPixelBudget.Lease?
    private let budget: AskToolPixelBudget
    private let decode: Decoder?
    private let worker: MediaWorker
    private let readInput: AskContextImageDecoder.InputReader
    private let smallFileIcon: AskSmallFileIconPreparation?
    private let nativeIcon: AskNativeIconPreparation?
    private let browserIcon: AskBrowserIconPreparation?
    private let maximumEdge: Int
    private var registrationKind: AskImagePresentationScope.RegistrationKind {
        nativeIcon != nil && maximumEdge <= 112 ? .smallIcon : .standard
    }
    init(budget: AskToolPixelBudget = .shared, maximumEdge: Int = 1600, worker: MediaWorker = .previews,
         readInput: @escaping AskContextImageDecoder.InputReader = { try AskContextImageDecoder.input($0) },
         smallFileIcon: AskSmallFileIconPreparation? = nil,
         nativeIcon: AskNativeIconPreparation? = nil,
         browserIcon: AskBrowserIconPreparation? = nil,
         decode: Decoder? = nil) {
        self.budget = budget; self.decode = decode; self.maximumEdge = min(1600, max(1, maximumEdge))
        self.worker = worker; self.readInput = readInput; self.smallFileIcon = smallFileIcon
        self.nativeIcon = nativeIcon; self.browserIcon = browserIcon
    }
    func displayed(_ value: String?, access: AskImagePresentationAccess) -> NSImage? {
        let current = generation
        guard scope === access.scope, epoch == access.epoch, source == value else { return nil }
        guard access.allows(), generation == current else { return nil }
        guard originalAccess?.allows() == true, generation == current else { return nil }
        return image
    }
    func cancel() {
        generation = UUID(); operation?.cancel(); operation = nil
        if let registration { scope?.remove(registration) }
        registration = nil; scope = nil; source = nil; epoch = nil; originalAccess = nil; image = nil; pixels = nil; unavailable = false
    }
    func load(_ value: String?, access: AskImagePresentationAccess) async {
        guard !Task.isCancelled else { return }
        // Access callbacks may cancel or invalidate this owner synchronously.
        let entry = generation
        let allowed = access.allows() && access.scope?.visible == true && access.scope?.epoch == access.epoch
        guard !Task.isCancelled, generation == entry else { return }
        guard allowed else {
            let originalAllowed = originalAccess?.allows() == true
            guard !Task.isCancelled, generation == entry else { return }
            if !originalAllowed { cancel() }
            return
        }
        guard let value else { cancel(); return }
        if source == value, scope === access.scope, epoch == access.epoch {
            let originalAllowed = originalAccess?.allows() == true
            guard !Task.isCancelled, generation == entry else { return }
            if originalAllowed { return }
        }
        cancel(); source = value; epoch = access.epoch; originalAccess = access
        let current = generation
        do {
            guard value.utf8.count <= AskContextImageDecoder.maximumEncodedBytes,
                  let scope = access.scope, let epoch = access.epoch else { throw MediaFailure.unavailable }
            self.scope = scope; registration = try scope.register(self, epoch: epoch, kind: registrationKind)
            let authorization = decode == nil && smallFileIcon == nil && nativeIcon == nil && browserIcon == nil ? worker.authorization() : nil
            let iconBatch = decode == nil ? smallFileIcon?.bind(value) : nil
            let nativeBatch = decode == nil && smallFileIcon == nil ? try nativeIcon?.bind(value) : nil
            let browserBatch = decode == nil && smallFileIcon == nil && nativeIcon == nil
                ? try browserIcon?.bind(value, access: access) : nil
            // Browser source binding includes synchronous access callbacks.
            guard generation == current else { return }
            try Task.checkCancellation()
            if let browserBatch, !browserBatch.isCurrent() { throw MediaFailure.unavailable }
            if let iconBatch, !iconBatch.isCurrent() { throw MediaFailure.unavailable }
            if let nativeBatch, !nativeBatch.isCurrent() { throw MediaFailure.unavailable }
            let reservation = try budget.acquire(bytes: maximumEdge * maximumEdge * 4)
            let task = Task { [decode, worker, readInput, iconBatch, nativeBatch, browserBatch] in
                defer { withExtendedLifetime(reservation) {} }
                if let iconBatch { return try await iconBatch.decode() }
                if let nativeBatch { return try await nativeBatch.decode() }
                if let browserBatch { return try await browserBatch.decode() }
                if let decode { return try await decode(value) }
                return try await AskContextImageDecoder.decode(value, worker: worker, authorization: authorization, readInput: readInput)
            }
            operation = task
            let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            try Task.checkCancellation()
            guard generation == current else { return }
            let allowed = access.allows()
            guard generation == current else { return }
            try Task.checkCancellation()
            guard allowed else { cancel(); return }
            if let iconBatch, !iconBatch.isCurrent() { throw MediaFailure.unavailable }
            if let nativeBatch, !nativeBatch.isCurrent() { throw MediaFailure.unavailable }
            if let browserBatch, !browserBatch.isCurrent() { throw MediaFailure.unavailable }
            if let authorization, !worker.permits(authorization) { throw MediaFailure.unavailable }
            guard result.images.count == 1, let raster = result.images.first,
                  raster.width > 0, raster.height > 0, raster.width <= maximumEdge, raster.height <= maximumEdge else {
                throw MediaFailure.invalidProtocol
            }
            pixels = reservation; image = NSImage(cgImage: raster, size: .zero); operation = nil
        } catch {
            guard generation == current else { return }
            let allowed = !Task.isCancelled && access.allows()
            guard generation == current else { return }
            let retainFailure = !Task.isCancelled && allowed
            cancel()
            if retainFailure {
                source = value; epoch = access.epoch; originalAccess = access; unavailable = true
                if let scope = access.scope, let epoch = access.epoch {
                    self.scope = scope; registration = try? scope.register(self, epoch: epoch, kind: registrationKind)
                }
            }
        }
    }
}

/// A stable loading container owns its projection, including chips and popover contents.
struct AskContextImage<Content: View>: View {
    let source: String?
    @Environment(\.askContextImageAccess) private var access
    @StateObject private var model: AskContextImageModel
    let content: (NSImage?) -> Content
    init(source: String?, model: AskContextImageModel? = nil, @ViewBuilder content: @escaping (NSImage?) -> Content) {
        self.source = source; self.content = content; _model = StateObject(wrappedValue: model ?? AskContextImageModel())
    }
    var body: some View {
        ZStack { content(model.displayed(source, access: access)) }
            .task(id: AskContextImageModel.Identity(source: source, epoch: access.epoch)) { await model.load(source, access: access) }
            .onDisappear { model.cancel() }
    }
}

struct AskContextImagePreview: View {
    let source: String?
    var body: some View {
        AskContextImage(source: source) { image in
            if let image { Image(nsImage: image).resizable().scaledToFit() }
            else { Text(L("ask.image.previewUnavailable")).font(.system(size: 12)) }
        }
    }
}
