import Foundation

/// Checks the normalized JPEG envelope without loading a native image decoder.
/// Entropy decoding remains the helper's responsibility; this bounds UI pixels.
public enum MediaJPEG {
    /// ImageIO adds its own EXIF/IPTC defaults even for a fresh RGB image.
    /// Remove these optional header segments before validating the output.
    public static func removingMetadata(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        guard bytes.starts(with: [0xff, 0xd8]) else { return nil }
        var output = Data(bytes.prefix(2)), offset = 2
        while offset < bytes.count - 2 {
            let start = offset
            guard bytes[offset] == 0xff else { return nil }
            while offset < bytes.count, bytes[offset] == 0xff { offset += 1 }
            guard offset + 2 < bytes.count else { return nil }
            let marker = bytes[offset]; offset += 1
            let length = Int(bytes[offset]) * 256 + Int(bytes[offset + 1])
            guard length >= 2, length <= bytes.count - offset - 2 else { return nil }
            if marker == 0xda {
                output.append(contentsOf: bytes[start...])
                return isNormalized(output) ? output : nil
            }
            if ![0xe1, 0xed, 0xfe].contains(marker) { output.append(contentsOf: bytes[start ..< offset + length]) }
            offset += length
        }
        return nil
    }

    public static func isNormalized(_ data: Data) -> Bool {
        let bytes = [UInt8](data)
        guard bytes.count >= 4, bytes.starts(with: [0xff, 0xd8]), bytes.suffix(2) == [0xff, 0xd9] else { return false }
        var offset = 2, framed = false
        while offset < bytes.count - 2 {
            guard bytes[offset] == 0xff else { return false }
            while offset < bytes.count, bytes[offset] == 0xff { offset += 1 }
            guard offset + 2 < bytes.count else { return false }
            let marker = bytes[offset]
            offset += 1
            let length = Int(bytes[offset]) * 256 + Int(bytes[offset + 1])
            guard length >= 2, length <= bytes.count - offset - 2 else { return false }
            switch marker {
            case 0xc0, 0xc1, 0xc2:
                guard !framed, length >= 8, bytes[offset + 2] == 8 else { return false }
                let height = Int(bytes[offset + 3]) * 256 + Int(bytes[offset + 4])
                let width = Int(bytes[offset + 5]) * 256 + Int(bytes[offset + 6])
                let components = Int(bytes[offset + 7])
                guard width > 0, height > 0, width <= MediaLimits.imageLongEdge, height <= MediaLimits.imageLongEdge,
                      [1, 3].contains(components), length == 8 + 3 * components else { return false }
                framed = true
            case 0xda:
                return framed && length >= 6
            case 0xc4, 0xdb, 0xdd, 0xe0, 0xe2:
                break // Huffman/quantization/restart tables, JFIF and the encoder's ICC profile.
            default:
                return false // Includes EXIF, IPTC and comments; no original metadata crosses IPC.
            }
            offset += length
        }
        return false
    }
}
