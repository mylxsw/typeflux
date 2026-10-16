import AppKit
import ImageIO
import Testing
import TypefluxMediaRuntime

extension SemanticOCRPreviewTests {
    // This fixed-size production-view fixture places the image inside this region.
    // Exclude result-list text, header labels and the fallback badge from recognition.
    private var previewRegion: CGRect { CGRect(x: 606, y: 194, width: 344, height: 172) }

    struct SnapshotMetrics: Codable {
        var matchedRegions: Int
        var inkInMatch: Int
        var yellowInMatch: Int
        var yellowTotal: Int

        func readable(highlighted: Bool) -> Bool {
            matchedRegions == 1 && inkInMatch > 30 && (highlighted ? yellowInMatch > 50 : yellowTotal == 0)
        }
    }

    private func snapshotMetrics(_ png: Data) throws -> SnapshotMetrics {
        let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        // Convert the point-space fixture region to the captured backing density.
        let scaleX = CGFloat(image.width) / 982, scaleY = CGFloat(image.height) / 548
        let region = CGRect(x: previewRegion.minX * scaleX, y: previewRegion.minY * scaleY,
                            width: previewRegion.width * scaleX, height: previewRegion.height * scaleY)
        let crop = try #require(image.cropping(to: region))
        let boxes = try MediaPreviewOCR.locate(crop, passage: "ERR-739204").boxes
        let bitmap = NSBitmapImageRep(cgImage: crop)
        var metrics = SnapshotMetrics(matchedRegions: boxes.count, inkInMatch: 0, yellowInMatch: 0, yellowTotal: 0)
        for row in 0 ..< bitmap.pixelsHigh {
            for column in 0 ..< bitmap.pixelsWide {
                let color = try #require(bitmap.colorAt(x: column, y: row)?.usingColorSpace(.sRGB))
                let red = color.redComponent, green = color.greenComponent, blue = color.blueComponent
                let yellow = color.alphaComponent > 0.9 && red > 0.85 && green > 0.7 && blue < 0.85 &&
                    red - blue > 0.15 && green - blue > 0.1
                if yellow { metrics.yellowTotal += 1 }
                let point = CGPoint(x: (CGFloat(column) + 0.5) / CGFloat(bitmap.pixelsWide),
                                    y: 1 - (CGFloat(row) + 0.5) / CGFloat(bitmap.pixelsHigh))
                if boxes.contains(where: { $0.insetBy(dx: -0.01, dy: -0.01).contains(point) }) {
                    if yellow { metrics.yellowInMatch += 1 }
                    if color.alphaComponent > 0.9, max(red, green, blue) < 0.7 { metrics.inkInMatch += 1 }
                }
            }
        }
        return metrics
    }

    func verifyPreviewSnapshot(_ png: Data, highlighted: Bool, label: String) throws {
        let metrics = try snapshotMetrics(png)
        try saveSnapshotMetrics(metrics, label: label)
        #expect(metrics.readable(highlighted: highlighted),
                "\(label): visible error-code glyphs and the expected highlight must survive PNG export: \(metrics)")
    }

    func verifyBlankPreviewIsRejected(_ bitmap: NSBitmapImageRep) throws {
        let image = try #require(bitmap.cgImage)
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height,
                                             bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let scaleX = CGFloat(image.width) / 982, scaleY = CGFloat(image.height) / 548
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: previewRegion.minX * scaleX,
                            y: CGFloat(image.height) - previewRegion.maxY * scaleY,
                            width: previewRegion.width * scaleX, height: previewRegion.height * scaleY))
        let blank = NSBitmapImageRep(cgImage: try #require(context.makeImage()))
        let png = try #require(blank.representation(using: .png, properties: [:]))
        let metrics = try snapshotMetrics(png)
        #expect(png.count > 1000, "The previous size-only assertion accepts this blank preview")
        #expect(!metrics.readable(highlighted: true) && !metrics.readable(highlighted: false))
        try saveSnapshotMetrics(metrics, label: "blank-preview-control")
        if let folder = ProcessInfo.processInfo.environment["TYPEFLUX_OCR_PREVIEW_EVIDENCE"] {
            try png.write(to: URL(fileURLWithPath: folder).appendingPathComponent("blank-preview-control.png"))
        }
    }

    func verifyHistoricalSnapshots() throws {
        guard let folder = ProcessInfo.processInfo.environment["TYPEFLUX_OCR_PREVIEW_BASELINE"] else { return }
        for entry in ["mixed", "files"] {
            for appearance in ["light", "dark"] {
                let label = "ocr-\(entry)-\(appearance)"
                let png = try Data(contentsOf: URL(fileURLWithPath: folder).appendingPathComponent(label + ".png"))
                try verifyPreviewSnapshot(png, highlighted: true, label: "historical-" + label)
            }
        }
    }

    private func saveSnapshotMetrics(_ metrics: SnapshotMetrics, label: String) throws {
        if let folder = ProcessInfo.processInfo.environment["TYPEFLUX_OCR_PREVIEW_EVIDENCE"] {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(metrics).write(to: URL(fileURLWithPath: folder).appendingPathComponent(label + ".json"))
        }
    }
}
