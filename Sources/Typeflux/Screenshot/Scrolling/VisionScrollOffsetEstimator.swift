import CoreGraphics
import Foundation
import TypefluxMediaProtocol

protocol ScrollFrameRegistering: Sendable {
    var canSkipWhenLocallyAligned: Bool { get }
    func verticalShifts(from previous: CGImage, to current: CGImage) async throws -> [Int]
}

extension ScrollFrameRegistering {
    var canSkipWhenLocallyAligned: Bool { false }
}

/// Read-only candidates from the disposable child; the stitcher still checks every overlap.
struct VisionScrollOffsetEstimator: ScrollFrameRegistering {
    var canSkipWhenLocallyAligned: Bool { true }
    private static let admission = AskToolPixelBudget(limit: 2)
    var worker: MediaWorker = .frameRegistration

    func verticalShifts(from previous: CGImage, to current: CGImage) async throws -> [Int] {
        try Task.checkCancellation()
        let shape = MediaRegistrationInput(width: previous.width, height: previous.height)
        try shape.validate()
        guard current.width == shape.width, current.height == shape.height else { throw MediaFailure.invalidProtocol }
        let slot = try Self.admission.acquire(bytes: 1)
        defer { withExtendedLifetime(slot) {} }
        let cancelled = AskSearchCancellation(), worker = worker
        return try await withTaskCancellationHandler {
            let value = try await Task.detached(priority: .userInitiated) {
                var bytes = Data()
                bytes.reserveCapacity(shape.frameBytes * 2)
                for image in [previous, current] {
                    if cancelled.isCancelled { throw CancellationError() }
                    guard let context = CGContext(data: nil, width: shape.width, height: shape.height,
                        bitsPerComponent: 8, bytesPerRow: shape.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), let data = context.data
                    else { throw MediaFailure.unavailable }
                    context.draw(image, in: CGRect(x: 0, y: 0, width: shape.width, height: shape.height))
                    bytes.append(data.assumingMemoryBound(to: UInt8.self), count: shape.frameBytes)
                }
                return try worker.perform(.registerFrames, input: .data(bytes), registration: shape,
                    isCancelled: { cancelled.isCancelled }) { response, _ in
                        guard let result = response.registration else { throw MediaFailure.invalidProtocol }
                        return result.translationY.map { Self.shifts(translationY: $0) } ?? []
                    }
            }.value
            try Task.checkCancellation()
            return value
        } onCancel: { cancelled.cancel() }
    }

    static func shifts(translationY: CGFloat) -> [Int] {
        guard translationY.isFinite, abs(translationY) <= 16384 else { return [] }
        let shift = Int(translationY.rounded())
        return shift == 0 ? [0] : [shift, -shift]
    }
}
