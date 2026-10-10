import CoreGraphics
import Foundation

/// The pixel work behind mosaics. Everything runs on the CPU on plain RGBA buffers, so the
/// overlay and the exported image get exactly the same pixels from the same input.
enum ScreenshotMosaicEffects {
    /// An 8-bit premultiplied RGBA copy of an image, top row first.
    struct Pixels {
        let width: Int
        let height: Int
        var bytes: [UInt8]

        init(width: Int, height: Int, bytes: [UInt8]) {
            self.width = width
            self.height = height
            self.bytes = bytes
        }

        init?(_ image: CGImage, space: CGColorSpace) {
            let width = image.width, height = image.height
            guard width > 0, height > 0 else { return nil }
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
                guard let context = Self.context(buffer.baseAddress, width: width, height: height, space: space)
                else { return false }
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                return true
            }
            guard drawn else { return nil }
            self.init(width: width, height: height, bytes: bytes)
        }

        func makeImage(space: CGColorSpace) -> CGImage? {
            var bytes = bytes
            return bytes.withUnsafeMutableBytes { buffer in
                Self.context(buffer.baseAddress, width: width, height: height, space: space)?.makeImage()
            }
        }

        private static func context(_ data: UnsafeMutableRawPointer?, width: Int, height: Int,
                                    space: CGColorSpace) -> CGContext? {
            CGContext(data: data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        }
    }

    /// An RGB color space for 8-bit buffers: the image's own when it is RGB, otherwise sRGB.
    static func colorSpace(of image: CGImage) -> CGColorSpace {
        image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
            ?? CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    }

    static func apply(_ effect: ScreenshotMosaic.Effect, to image: CGImage, block: Int, radius: Int,
                      color: CGColor) -> CGImage? {
        switch effect {
        case .pixelate: pixelated(image, block: block)
        case .blur: blurred(image, radius: radius)
        case .solid: solid(width: image.width, height: image.height, color: color, space: colorSpace(of: image))
        }
    }

    /// Each `block` × `block` square, counted from the top-left corner, becomes its average color.
    static func pixelated(_ image: CGImage, block: Int) -> CGImage? {
        let space = colorSpace(of: image)
        guard var pixels = Pixels(image, space: space) else { return nil }
        pixelate(&pixels, block: block)
        return pixels.makeImage(space: space)
    }

    static func pixelate(_ pixels: inout Pixels, block: Int) {
        let block = max(1, block)
        let width = pixels.width, height = pixels.height
        pixels.bytes.withUnsafeMutableBufferPointer { bytes in
            for top in stride(from: 0, to: height, by: block) {
                let bottom = min(top + block, height)
                for left in stride(from: 0, to: width, by: block) {
                    let right = min(left + block, width)
                    var sums = [0, 0, 0, 0]
                    for row in top ..< bottom {
                        for column in left ..< right {
                            let offset = (row * width + column) * 4
                            for channel in 0 ..< 4 { sums[channel] += Int(bytes[offset + channel]) }
                        }
                    }
                    let count = (bottom - top) * (right - left)
                    let average = sums.map { UInt8(($0 + count / 2) / count) }
                    for row in top ..< bottom {
                        for column in left ..< right {
                            let offset = (row * width + column) * 4
                            for channel in 0 ..< 4 { bytes[offset + channel] = average[channel] }
                        }
                    }
                }
            }
        }
    }

    /// A blur close to a Gaussian one: three box blurs. Large radii work on a smaller copy
    /// that is scaled back up, which keeps the cost flat for big regions.
    static func blurred(_ image: CGImage, radius: Int) -> CGImage? {
        let radius = max(1, radius)
        let space = colorSpace(of: image)
        let factor = max(1, radius / 6)
        let smallSize = ScreenPixelSize(width: max(1, image.width / factor), height: max(1, image.height / factor))
        guard let small = factor == 1 ? image : ScreenCaptureGeometry.resized(image, to: smallSize),
              var pixels = Pixels(small, space: space) else { return nil }
        let smallRadius = max(1, radius / factor)
        for _ in 0 ..< 3 { boxBlur(&pixels, radius: smallRadius) }
        guard let blurred = pixels.makeImage(space: space) else { return nil }
        return ScreenCaptureGeometry.resized(blurred, to: ScreenPixelSize(width: image.width, height: image.height))
    }

    /// One horizontal and one vertical box blur; pixels past the edges repeat the edge.
    static func boxBlur(_ pixels: inout Pixels, radius: Int) {
        let width = pixels.width, height = pixels.height
        var scratch = pixels.bytes
        pixels.bytes.withUnsafeMutableBufferPointer { bytes in
            scratch.withUnsafeMutableBufferPointer { scratch in
                blurLines(from: bytes, into: scratch, lines: height, length: width, radius: radius) { line, index in
                    (line * width + index) * 4
                }
                blurLines(from: scratch, into: bytes, lines: width, length: height, radius: radius) { line, index in
                    (index * width + line) * 4
                }
            }
        }
    }

    private static func blurLines(from source: UnsafeMutableBufferPointer<UInt8>,
                                  into target: UnsafeMutableBufferPointer<UInt8>,
                                  lines: Int, length: Int, radius: Int,
                                  offset: (_ line: Int, _ index: Int) -> Int) {
        let window = radius * 2 + 1
        for line in 0 ..< lines {
            for channel in 0 ..< 4 {
                func value(_ index: Int) -> Int {
                    Int(source[offset(line, min(max(index, 0), length - 1)) + channel])
                }
                var sum = 0
                for index in -radius ... radius { sum += value(index) }
                for index in 0 ..< length {
                    target[offset(line, index) + channel] = UInt8((sum + window / 2) / window)
                    sum += value(index + radius + 1) - value(index - radius)
                }
            }
        }
    }

    static func solid(width: Int, height: Int, color: CGColor, space: CGColorSpace) -> CGImage? {
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.setFillColor(color)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
