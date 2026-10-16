import SwiftUI
import TypefluxMediaProtocol

/// View-owned decoded pixels, with no cache of private content shared across sessions.
@MainActor final class AskToolImageModel: ObservableObject {
    @Published private(set) var source: String?
    @Published private(set) var image: NSImage?
    @Published private(set) var unavailable = false
    private var generation = UUID()
    typealias Decoder = AskArtifactImageModel.Decoder
    typealias InputReader = @MainActor (String) throws -> (Data, MediaImageType)
    private let budget: AskToolPixelBudget
    private var pixelsLease: AskToolPixelBudget.Lease?
    private let decode: Decoder?
    private let worker: MediaWorker
    private let readInput: InputReader
    init(budget: AskToolPixelBudget = .shared, worker: MediaWorker = .previews,
         readInput: @escaping InputReader = { try AskToolImageModel.input($0) }, decode: Decoder? = nil) {
        self.budget = budget
        self.decode = decode; self.worker = worker; self.readInput = readInput
    }
    static func input(_ url: String) throws -> (Data, MediaImageType) {
        guard url.utf8.count <= 16 * 1024 * 1024, let comma = url.firstIndex(of: ","),
              url.hasPrefix("data:"), url[..<comma].hasSuffix(";base64"),
              let type = MediaImageType(rawValue: String(url[url.index(url.startIndex, offsetBy: 5)..<comma].dropLast(7))),
              let data = Data(base64Encoded: String(url[url.index(after: comma)...]))
        else { throw MediaFailure.unreadable }
        return (data, type)
    }
    func cancel() { generation = UUID(); source = nil; image = nil; pixelsLease = nil; unavailable = false }
    func load(_ url: String) async {
        guard !Task.isCancelled else { return }
        let authorization = decode == nil ? worker.authorization() : nil
        cancel()
        source = url
        let current = generation
        do {
            try Task.checkCancellation()
            if let authorization, !worker.permits(authorization) { throw MediaFailure.unavailable }
            let reservation = try budget.acquire(bytes: 1600 * 1600 * 4)
            let (data, type) = try readInput(url)
            try Task.checkCancellation()
            if let authorization, !worker.permits(authorization) { throw MediaFailure.unavailable }
            let result: AskFilePreviewPDF.Result
            if let decode { result = try await decode(data, type.rawValue) }
            else { result = try await AskArtifactPresentation.image(data, mediaType: type.rawValue, worker: worker, authorization: authorization) }
            try Task.checkCancellation()
            guard generation == current else { return }
            if let authorization, !worker.permits(authorization) { throw MediaFailure.unavailable }
            guard let pixels = result.images.first, pixels.width <= 1600, pixels.height <= 1600 else { throw MediaFailure.unreadable }
            pixelsLease = reservation
            image = NSImage(cgImage: pixels, size: .zero)
        } catch {
            guard generation == current, !Task.isCancelled else { return }
            unavailable = true
        }
    }
}

struct AskToolImageView: View {
    let url: String
    @StateObject private var model: AskToolImageModel
    init(url: String, model: AskToolImageModel? = nil) {
        self.url = url; _model = StateObject(wrappedValue: model ?? AskToolImageModel())
    }
    var body: some View {
        ZStack {
            if model.source == url, let image = model.image {
                Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else if model.unavailable {
                Label(AskArtifactError.unavailable.localizedDescription, systemImage: "photo")
            } else {
                ProgressView().controlSize(.small).frame(width: 32, height: 24)
            }
        }
        .task(id: url) { await model.load(url) }
        .onDisappear { model.cancel() }
    }
}

/// Bound completed tool thumbnails too, not only concurrently running decoders.
final class AskToolPixelBudget: @unchecked Sendable {
    static let shared = AskToolPixelBudget(limit: 64 * 1024 * 1024)
    private let lock = NSLock()
    private let limit: Int
    private var retained = 0
    init(limit: Int) { self.limit = max(0, limit) }
    func acquire(bytes: Int) throws -> Lease {
        try lock.withLock {
            guard bytes > 0, bytes <= limit - retained else { throw MediaFailure.unavailable }
            retained += bytes
        }
        return Lease { [self] in lock.withLock { retained -= bytes } }
    }
    final class Lease: @unchecked Sendable {
        private let release: @Sendable () -> Void
        init(release: @escaping @Sendable () -> Void) { self.release = release }
        deinit { release() }
    }
}
