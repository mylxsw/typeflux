import AppKit

/// Read captured alpha without allocating an NSColor for every sampled pixel.
/// The retained representation owns the buffer. Unusual layouts use AppKit's reader.
struct BitmapTestPixels {
    private let bitmap: NSBitmapImageRep
    private let data: UnsafeMutablePointer<UInt8>?
    private let alphaOffset: Int
    private let rowBytes: Int

    init(_ bitmap: NSBitmapImageRep) {
        self.bitmap = bitmap
        let byteOrder: NSBitmapImageRep.Format = [
            .sixteenBitLittleEndian, .thirtyTwoBitLittleEndian, .sixteenBitBigEndian, .thirtyTwoBitBigEndian
        ]
        let packed = bitmap.bitsPerSample == 8 && bitmap.bitsPerPixel == 32
            && bitmap.samplesPerPixel == 4 && bitmap.hasAlpha && !bitmap.isPlanar
            && bitmap.bitmapFormat.isDisjoint(with: byteOrder)
        data = packed ? bitmap.bitmapData : nil
        alphaOffset = bitmap.bitmapFormat.contains(.alphaFirst) ? 0 : 3
        rowBytes = bitmap.bytesPerRow
    }

    func alpha(x column: Int, y row: Int) -> CGFloat {
        guard let data else { return bitmap.colorAt(x: column, y: row)?.alphaComponent ?? 0 }
        return CGFloat(data[row * rowBytes + column * 4 + alphaOffset]) / 255
    }
}
