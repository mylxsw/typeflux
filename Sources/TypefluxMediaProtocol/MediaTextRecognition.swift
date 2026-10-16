import Foundation
import CoreGraphics

public struct MediaTextInput: Codable, Sendable {
    public static let rawBytes = 64 * 1024 * 1024
    public var width: Int
    public var height: Int
    public init(width: Int, height: Int) { self.width = width; self.height = height }
    public var byteCount: Int { width * height * 4 }
    public func validate() throws {
        guard width > 0, height > 0, width <= 16384, height <= 16384, width <= 16_000_000 / height
        else { throw MediaFailure.tooLarge }
    }
}

/// Exact Vision boxes only for ranges actually consumed by sensitive-text detection.
/// All other substring queries are explicitly unavailable, never estimated by this protocol.
public struct MediaTextRecognition: Codable, Sendable {
    public struct Region: Codable, Sendable {
        public var kind: MediaSensitiveText.Kind
        public var location: Int
        public var length: Int
        public var box: CGRect
        public init(kind: MediaSensitiveText.Kind, range: NSRange, box: CGRect) {
            self.kind = kind; location = range.location; length = range.length; self.box = box
        }
        public var range: NSRange { NSRange(location: location, length: length) }
    }
    public struct Line: Codable, Sendable {
        public var text: String
        public var confidence: Float
        public var box: CGRect
        public var regions: [Region]
        public init(text: String, confidence: Float, box: CGRect, regions: [Region]) {
            self.text = text; self.confidence = confidence; self.box = box; self.regions = regions
        }
    }
    public var lines: [Line]
    public init(lines: [Line]) { self.lines = lines }
    public func validate() throws {
        guard lines.count <= MediaOCRResult.maximumLines else { throw MediaFailure.tooLarge }
        try MediaOCRResult(lines: lines.map(\.text)).validate()
        var total = 0
        for line in lines {
            guard line.confidence.isFinite, (0...1).contains(line.confidence), Self.valid(line.box),
                  line.regions.count <= 128 else { throw MediaFailure.invalidProtocol }
            total += line.regions.count
            guard total <= 4096 else { throw MediaFailure.tooLarge }
            let units = Array(line.text.utf16)
            func boundary(_ offset: Int) -> Bool {
                offset == 0 || offset == units.count ||
                    !((0xDC00...0xDFFF).contains(units[offset]) && (0xD800...0xDBFF).contains(units[offset - 1]))
            }
            var end = 0
            for region in line.regions {
                guard region.location >= end, region.length > 0, region.location <= units.count,
                      region.length <= units.count - region.location,
                      boundary(region.location), boundary(region.location + region.length),
                      Range(region.range, in: line.text) != nil, Self.valid(region.box)
                else { throw MediaFailure.invalidProtocol }
                end = region.location + region.length
            }
        }
    }
    public static func valid(_ rect: CGRect) -> Bool {
        [rect.origin.x, rect.origin.y, rect.width, rect.height].allSatisfy(\.isFinite) &&
            rect.minX >= 0 && rect.minY >= 0 && rect.width > 0 && rect.height > 0 && rect.maxX <= 1 && rect.maxY <= 1
    }
}
