import AppKit
import CryptoKit
import ImageIO
import Vision

// Read exported PNG bytes directly, without hosting views or using a viewer cache.
var records: [[String: Any]] = []
for path in CommandLine.arguments.dropFirst() {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
          let crop = image.cropping(to: CGRect(x: 606 * CGFloat(image.width) / 982,
                                               y: 194 * CGFloat(image.height) / 548,
                                               width: 344 * CGFloat(image.width) / 982,
                                               height: 172 * CGFloat(image.height) / 548)) else {
        fatalError("Cannot decode the fixed-size preview fixture")
    }
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = false
    request.recognitionLanguages = ["en-US"]
    try VNImageRequestHandler(cgImage: crop).perform([request])
    let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    let bitmap = NSBitmapImageRep(cgImage: crop)
    var yellow = 0, ink = 0
    for row in 0 ..< bitmap.pixelsHigh {
        for column in 0 ..< bitmap.pixelsWide {
            guard let color = bitmap.colorAt(x: column, y: row)?.usingColorSpace(.sRGB) else {
                fatalError("Cannot read preview pixels")
            }
            let red = color.redComponent, green = color.greenComponent, blue = color.blueComponent
            if color.alphaComponent > 0.9, max(red, green, blue) < 0.7 { ink += 1 }
            if color.alphaComponent > 0.9, red > 0.85, green > 0.7, blue < 0.85,
               red - blue > 0.15, green - blue > 0.1 { yellow += 1 }
        }
    }
    records.append([
        "filename": URL(fileURLWithPath: path).lastPathComponent,
        "sha256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
        "preview_region_points": [606, 194, 344, 172],
        "recognized_preview_lines": lines,
        "error_code_visible": lines.contains { $0.contains("ERR-739204") },
        "yellow_pixels": yellow,
        "ink_pixels": ink
    ])
}
let json = try JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys])
print(String(decoding: json, as: UTF8.self))
