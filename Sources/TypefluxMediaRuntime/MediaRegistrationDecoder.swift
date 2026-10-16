import Foundation
import CoreGraphics
import Vision
import TypefluxMediaProtocol

public enum MediaRegistrationDecoder {
    public static func decode(_ request: MediaRequest, directory: URL,
        register: (CGImage, CGImage) throws -> Double? = register) throws -> MediaResponse {
        try request.validate()
        guard request.operation == .registerFrames, let shape = request.registration else { throw MediaFailure.invalidProtocol }
        let handle = try FileHandle(forReadingFrom: directory.appendingPathComponent("input"))
        defer { try? handle.close() }
        let bytes = try handle.read(upToCount: shape.frameBytes * 2 + 1) ?? Data()
        guard bytes.count == shape.frameBytes * 2 else { throw MediaFailure.invalidProtocol }
        func image(_ data: Data) throws -> CGImage {
            guard let provider = CGDataProvider(data: data as CFData),
                  let image = CGImage(width: shape.width, height: shape.height, bitsPerComponent: 8,
                    bitsPerPixel: 32, bytesPerRow: shape.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                    provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
            else { throw MediaFailure.unavailable }
            return image
        }
        var response = MediaResponse(id: request.id)
        response.registration = try MediaRegistration(translationY: register(
            image(bytes.prefix(shape.frameBytes)), image(bytes.suffix(shape.frameBytes))))
        try response.validate(for: request)
        return response
    }

    public static func register(_ before: CGImage, _ after: CGImage) throws -> Double? {
        let request = VNTranslationalImageRegistrationRequest(targetedCGImage: after)
        try VNImageRequestHandler(cgImage: before).perform([request])
        return (request.results?.first as? VNImageTranslationAlignmentObservation).map { Double($0.alignmentTransform.ty) }
    }
}
