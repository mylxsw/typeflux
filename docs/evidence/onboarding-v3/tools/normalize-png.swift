import AppKit
import Foundation
let directory = URL(fileURLWithPath: CommandLine.arguments[1])
var count = 0
for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) where url.pathExtension == "png" {
    try autoreleasepool {
        guard let source = NSBitmapImageRep(data: try Data(contentsOf: url)), source.bitsPerSample > 8,
              let pixels = source.cgImage,
              let context = CGContext(data: nil, width: pixels.width, height: pixels.height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        context.draw(pixels, in: CGRect(x: 0, y: 0, width: pixels.width, height: pixels.height))
        let output = NSBitmapImageRep(cgImage: context.makeImage()!)
        guard let data = output.representation(using: .png, properties: [:]) else { throw NSError(domain: "PNG export", code: 1) }
        try data.write(to: url, options: .atomic)
        count += 1
    }
}
print("Exported \(count) PNGs as 8-bit sRGB at original pixel dimensions")
