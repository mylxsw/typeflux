import AppKit

@MainActor
struct AskFilePreviewContent {
    var kind: AskFilePreviewKind
    var images: [NSImage] = []
    var text: String = ""
    var truncated = false
    var pageCount = 0
    var pageNumbers: [Int] = []
    var duration: TimeInterval = 0
    var startTime: TimeInterval = 0
    var waveform: [Float] = []
    var fileSize: Int64 = 0
    var imageSize: CGSize?
    var imageTextLocated: Bool?

    var cost: Int {
        images.reduce(text.utf8.count + waveform.count * 4) { total, image in
            total + image.representations.reduce(0) { $0 + max(1, $1.pixelsWide) * max(1, $1.pixelsHigh) * 4 }
        }
    }

    var detail: String {
        var parts = [
            L("ask.preview.kind.\(kind.rawValue)"),
            Self.size(fileSize)
        ]
        if kind == .pdf {
            parts.append(String(format: L("ask.preview.pages"), pageCount))
        }
        if kind.readsText {
            parts.append(String(
                format: L("ask.preview.lines"),
                text.components(separatedBy: "\n").count
            ))
        }
        if kind == .audio || kind == .video {
            parts.append(Self.time(duration))
            if startTime > 0 { parts.append(L("semantic.atTime", Self.time(startTime))) }
        }
        if kind == .image, let imageSize {
            parts.append("\(Int(imageSize.width)) × \(Int(imageSize.height))")
        }
        return parts.joined(separator: " · ")
    }

    static func size(_ bytes: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(max(0, bytes)), unit = 0
        while value >= 1000, unit < units.count - 1 {
            value /= 1000; unit += 1
        }
        return String(format: unit == 0 ? "%.0f %@" : "%.1f %@",
                      locale: AppLocalization.shared.locale, arguments: [value, units[unit]])
    }

    static func time(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0, seconds < Double(Int.max) else { return "0:00" }
        return String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60)
    }
}

@MainActor
protocol AskFilePreviewLoading: AnyObject {
    func load(_ hit: AskFileHit, pixels: CGSize, completion: @escaping (AskFilePreviewContent?) -> Void)
    func cancel()
    func clearCache()
    func prefetch(_ hits: [AskFileHit], pixels: CGSize)
    func setVisible(_ visible: Bool)
}
