import AppKit
import Foundation
let input = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2])
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let prefixes = ["welcome-", "route-", "cloud-", "speech-", "llm-", "permissions-", "shortcuts-", "try-", "resume-", "native-window-"]
var count = 0
for url in try FileManager.default.contentsOfDirectory(at: input, includingPropertiesForKeys: nil) where url.pathExtension == "png" {
    let name = url.lastPathComponent
    guard prefixes.contains(where: { name.hasPrefix($0) }),
          name.range(of: "-(en|zh-Hans)-(dark|light)\\.png$", options: .regularExpression) != nil else { continue }
    try autoreleasepool {
        guard let source = NSBitmapImageRep(data: try Data(contentsOf: url)), let pixels = source.cgImage else {
            throw NSError(domain: "PNG input", code: 1)
        }
        let divisor = pixels.width >= 1800 ? 2 : 1
        let width = pixels.width / divisor, height = pixels.height / divisor
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw NSError(domain: "PNG surface", code: 1) }
        context.interpolationQuality = .high
        context.draw(pixels, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let rendered = context.makeImage(),
            let data = NSBitmapImageRep(cgImage: rendered).representation(using: .png, properties: [:]) else {
            throw NSError(domain: "PNG export", code: 1)
        }
        try data.write(to: output.appendingPathComponent(name), options: .atomic)
        count += 1
    }
}
print("Exported \(count) native captures at point resolution as 8-bit sRGB PNG")
