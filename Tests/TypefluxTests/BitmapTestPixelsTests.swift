import AppKit
import Testing

@Suite(.serialized, .exclusiveUIState)
struct BitmapTestPixelsTests {
    @Test(arguments: [NSBitmapImageRep.Format(), .alphaFirst, .alphaNonpremultiplied,
                      [.alphaFirst, .alphaNonpremultiplied]]) @MainActor
    func packedPixelsMatchAppKitIncludingPaddingAndOrientation(format: NSBitmapImageRep.Format) throws {
        let bitmap = try makeBitmap(bits: 8, samples: 4, alpha: true, format: format, rowBytes: 24)
        try compareReaders(bitmap)
    }

    @Test @MainActor
    func nonPackedFormatsKeepTheAppKitFallback() throws {
        try compareReaders(makeBitmap(bits: 8, samples: 3, alpha: false))
        try compareReaders(makeBitmap(bits: 16, samples: 4, alpha: true, format: .sixteenBitBigEndian))
    }

    @Test @MainActor
    func readerRetainsItsBufferAndPreservesAlphaAcrossColorSpaces() throws {
        let bitmap = try makeBitmap(bits: 8, samples: 4, alpha: true)
        let retained = try BitmapTestPixels(makeBitmap(bits: 8, samples: 4, alpha: true))
        #expect(abs(retained.alpha(x: 1, y: 2) - 0.8) < 0.01)
        try compareReaders(#require(bitmap.retagging(with: .displayP3)))
    }

    @MainActor
    private func makeBitmap(bits: Int, samples: Int, alpha: Bool,
                            format: NSBitmapImageRep.Format = [], rowBytes: Int = 0) throws -> NSBitmapImageRep {
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 3, pixelsHigh: 4, bitsPerSample: bits,
            samplesPerPixel: samples, hasAlpha: alpha, isPlanar: false,
            colorSpaceName: .deviceRGB, bitmapFormat: format, bytesPerRow: rowBytes, bitsPerPixel: 0
        )?.retagging(with: .sRGB))
        let data = try #require(bitmap.bitmapData)
        // Construct actual channel samples. AppKit's setColor path can reject
        // extended NSColor models on some macOS versions and leave a blank fixture.
        for row in 0 ..< 4 {
            for column in 0 ..< 3 {
                let opacity = alpha ? (row == 0 ? 0.0 : 0.8) : 1.0
                let factor = format.contains(.alphaNonpremultiplied) ? 1.0 : opacity
                var channels = [Double(row + 1) / 4 * factor, Double(column + 1) / 3 * factor, 0.25 * factor]
                if alpha {
                    if format.contains(.alphaFirst) { channels.insert(opacity, at: 0) } else { channels.append(opacity) }
                }
                for (channel, value) in channels.enumerated() {
                    let index = row * bitmap.bytesPerRow + (column * samples + channel) * (bits / 8)
                    if bits == 8 {
                        data[index] = UInt8((value * 255).rounded())
                    } else {
                        let sample = UInt16((value * 65535).rounded())
                        data[index] = UInt8(sample >> 8)
                        data[index + 1] = UInt8(sample & 255)
                    }
                }
            }
        }
        let sample = try #require(bitmap.colorAt(x: 1, y: 2))
        try #require(sample.alphaComponent > 0.75)
        return bitmap
    }

    @MainActor
    private func compareReaders(_ bitmap: NSBitmapImageRep) throws {
        let alphaReader = BitmapTestPixels(bitmap)
        for row in 0 ..< bitmap.pixelsHigh {
            for column in 0 ..< bitmap.pixelsWide {
                let reference = try #require(bitmap.colorAt(x: column, y: row))
                #expect(abs(alphaReader.alpha(x: column, y: row) - reference.alphaComponent) < 0.0001)
            }
        }
    }
}
