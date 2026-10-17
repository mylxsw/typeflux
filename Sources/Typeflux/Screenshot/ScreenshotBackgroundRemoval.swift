import CoreImage
import Vision

/// Uses the system's foreground segmentation locally; no image leaves the Mac.
enum ScreenshotBackgroundRemoval {
    enum Failure: Error { case unsupported, noSubject, rendering }

    static var isSupported: Bool {
        if #available(macOS 14.0, *) { return true }
        return false
    }

    static func remove(from image: CGImage) throws -> CGImage {
        guard #available(macOS 14.0, *) else { throw Failure.unsupported }
        let handler = VNImageRequestHandler(cgImage: image)
        let request = VNGenerateForegroundInstanceMaskRequest()
        try handler.perform([request])
        try Task.checkCancellation()
        guard let observation = request.results?.first, !observation.allInstances.isEmpty else {
            throw Failure.noSubject
        }
        let buffer = try observation.generateMaskedImage(ofInstances: observation.allInstances,
                                                         from: handler, croppedToInstancesExtent: false)
        let result = CIImage(cvPixelBuffer: buffer)
        guard let output = CIContext().createCGImage(result, from: result.extent) else { throw Failure.rendering }
        return output
    }
}

/// Owns one region's asynchronous result. Changes of region and closing invalidate pending work.
@MainActor
final class ScreenshotBackgroundRemovalState {
    typealias Processor = (CGImage) async throws -> CGImage
    private let process: Processor
    private var task: Task<Void, Never>?
    private var generation = 0
    private(set) var region: CGRect?
    private(set) var image: CGImage?
    private(set) var isProcessing = false
    private(set) var noticeKey: String?
    var onChange: (() -> Void)?

    init(process: @escaping Processor = { image in
        let worker = Task.detached(priority: .userInitiated) { try ScreenshotBackgroundRemoval.remove(from: image) }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }) {
        self.process = process
    }

    func updateRegion(_ region: CGRect?) {
        guard region != self.region else { return }
        reset()
        self.region = region
    }

    func reset() {
        generation += 1
        task?.cancel()
        task = nil
        image = nil
        isProcessing = false
        noticeKey = nil
    }

    func toggle(source: CGImage) {
        if isProcessing || image != nil {
            reset()
            onChange?()
            return
        }
        guard region != nil else { return }
        generation += 1
        let token = generation
        isProcessing = true
        noticeKey = nil
        let process = process
        task = Task { [weak self] in
            do {
                let result = try await process(source)
                guard let self, self.generation == token, !Task.isCancelled else { return }
                self.image = result
                self.isProcessing = false
                self.task = nil
                self.onChange?()
            } catch {
                guard let self, self.generation == token, !Task.isCancelled else { return }
                self.isProcessing = false
                self.task = nil
                if case ScreenshotBackgroundRemoval.Failure.noSubject = error {
                    self.noticeKey = "screenshot.background.noSubject"
                } else {
                    self.noticeKey = "screenshot.background.failed"
                }
                self.onChange?()
            }
        }
        onChange?()
    }
}
