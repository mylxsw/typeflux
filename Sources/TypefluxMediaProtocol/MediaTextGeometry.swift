import Foundation
import CoreGraphics

/// Detector rectangles only; normalized bottom-left coordinates, with no recognized text.
public struct MediaTextGeometry: Codable, Sendable {
    public var boxes: [CGRect]
    public init(boxes: [CGRect]) { self.boxes = boxes }
    public func validate() throws {
        guard boxes.count <= 1024 else { throw MediaFailure.tooLarge }
        guard boxes.allSatisfy(MediaTextRecognition.valid) else { throw MediaFailure.invalidProtocol }
    }
}
