import AppKit
import AVFoundation
import PDFKit
@testable import Typeflux

/// Shared fixtures for clipboard history tests.
enum ClipboardTestSupport {
    /// The clipboard panel a controller is showing. Panels dismissed by earlier tests keep the
    /// same identifier and can stay in `NSApp.windows` until AppKit releases them, so a lookup
    /// by identifier alone can return a stale panel. Only a single visible panel counts.
    static func presentedPanel() -> NSWindow? {
        let panels = NSApplication.shared.windows.filter {
            $0.isVisible && $0.identifier?.rawValue == "ai.gulu.app.typeflux.window.clipboard"
        }
        return panels.count == 1 ? panels[0] : nil
    }

    struct MissingPanel: Error {}

    /// Presents `model`, hands `body` the visible panel and always dismisses afterwards, also
    /// when the lookup or `body` throws, so a failing test cannot leave its panel to the next.
    static func withPresentedPanel<T>(
        _ controller: ClipboardPanelController, _ model: ClipboardPanelModel, _ body: (NSWindow) throws -> T
    ) throws -> T {
        controller.present(model)
        defer { controller.dismiss() }
        guard let panel = presentedPanel() else { throw MissingPanel() }
        return try body(panel)
    }

    static func temporaryDirectory(_ name: String = "ClipboardTests") -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A solid-color bitmap, optionally with text drawn on it.
    static func imageData(
        width: Int = 4,
        height: Int = 3,
        type: NSBitmapImageRep.FileType = .png,
        text: String? = nil
    ) -> Data {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        )!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        if let text {
            (text as NSString).draw(at: NSPoint(x: 20, y: CGFloat(height) / 3), withAttributes: [
                .font: NSFont.systemFont(ofSize: CGFloat(height) / 3, weight: .bold),
                .foregroundColor: NSColor.black
            ])
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: type, properties: [:])!
    }

    static func makeFile(named name: String, in directory: URL, bytes: Int = 16) -> URL {
        let url = directory.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: Data(repeating: 7, count: bytes))
        return url
    }

    /// A mono 16-bit WAV of a 440 Hz tone whose loudness ramps from `startLevel` to `endLevel`.
    static func makeAudioFile(
        named name: String,
        in directory: URL,
        seconds: Double = 1,
        startLevel: Float = 0.1,
        endLevel: Float = 0.9
    ) throws -> URL {
        let url = directory.appendingPathComponent(name)
        let sampleRate = 8000.0
        let format = try unwrap(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1))
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false
        ])
        let frames = AVAudioFrameCount(seconds * sampleRate)
        let buffer = try unwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let samples = buffer.floatChannelData![0]
        for frame in 0 ..< Int(frames) {
            let position = Float(frame) / Float(frames)
            let level = startLevel + (endLevel - startLevel) * position
            samples[frame] = level * sin(2 * .pi * 440 * Float(frame) / Float(sampleRate))
        }
        try file.write(from: buffer)
        return url
    }

    /// A PDF with `pages` blank pages.
    static func makePDF(named name: String, in directory: URL, pages: Int) -> URL {
        let url = directory.appendingPathComponent(name)
        let document = PDFDocument()
        let image = NSImage(data: imageData(width: 60, height: 80))!
        for index in 0 ..< pages {
            document.insert(PDFPage(image: image)!, at: index)
        }
        document.write(to: url)
        return url
    }

    /// One entry of every kind, with real image, PDF and audio files where the kind needs one.
    static func allKindsEntries(in directory: URL) -> [ClipboardEntry] {
        let png = directory.appendingPathComponent("shot.png")
        let pngData = imageData(width: 400, height: 150, text: "Typeflux")
        FileManager.default.createFile(atPath: png.path, contents: pngData)
        let pdf = makePDF(named: "report.pdf", in: directory, pages: 2)
        let movie = makeFile(named: "demo.mov", in: directory)
        let audio = (try? makeAudioFile(named: "talk.wav", in: directory))
            ?? makeFile(named: "talk.wav", in: directory)
        let doc = makeFile(named: "plan.docx", in: directory)
        return [
            entry(.voice, text: "spoken words", isPinned: true),
            entry(.text, text: "plain text", sourceBundleID: "com.apple.finder", sourceAppName: "Finder"),
            entry(.link, text: "https://example.com", sourceBundleID: "com.apple.Safari"),
            entry(.code, text: "func a() {\n}\n", sourceBundleID: "com.example.uninstalled"),
            entry(.image, imagePath: png.path, imagePixelSize: CGSize(width: 400, height: 150),
                  sourceBundleID: "com.apple.Preview", sourceAppName: "Preview"),
            entry(.images, filePaths: [png.path, png.path, png.path, png.path, png.path]),
            entry(.pdf, filePaths: [pdf.path], byteSize: 16),
            entry(.video, filePaths: [movie.path], sourceBundleID: "com.apple.finder"),
            entry(.audio, filePaths: [audio.path], sourceBundleID: "com.apple.finder"),
            entry(.document, filePaths: [doc.path]),
            entry(.files, filePaths: [pdf.path, doc.path, "/missing/archive.zip"])
        ]
    }

    struct MissingValue: Error {}

    private static func unwrap<T>(_ value: T?) throws -> T {
        guard let value else { throw MissingValue() }
        return value
    }

    static func entry(
        _ kind: ClipboardEntryKind,
        id: UUID = UUID(),
        date: Date = Date(),
        text: String? = nil,
        filePaths: [String] = [],
        imagePath: String? = nil,
        imagePixelSize: CGSize? = nil,
        byteSize: Int64 = 0,
        sourceBundleID: String? = nil,
        sourceAppName: String? = nil,
        isPinned: Bool = false
    ) -> ClipboardEntry {
        ClipboardEntry(
            origin: kind == .voice ? .voice(id) : .clipboard(id),
            kind: kind,
            date: date,
            text: text ?? (kind.isTextual ? "text" : nil),
            filePaths: filePaths,
            imagePath: imagePath,
            imagePixelSize: imagePixelSize,
            byteSize: byteSize,
            sourceBundleID: sourceBundleID,
            sourceAppName: sourceAppName,
            isPinned: isPinned
        )
    }
}

/// An in-memory `ClipboardHistoryStore` that records calls.
final class InMemoryClipboardHistoryStore: ClipboardHistoryStore {
    var storedItems: [ClipboardItem] = []
    var pinnedVoiceIDs: Set<UUID> = []
    var purgeCutoffs: [Date] = []
    var trimCounts: [Int] = []
    var trimImageBytes: [Int64] = []
    private let lock = NSLock()

    @discardableResult
    func record(_ capture: ClipboardCapture, source: ClipboardSource?, at date: Date) -> ClipboardItem? {
        lock.lock()
        defer { lock.unlock() }
        if let index = storedItems.firstIndex(where: { $0.contentHash == capture.contentHash }) {
            storedItems[index].date = date
            return storedItems[index]
        }
        var item = ClipboardItem(
            id: UUID(), payload: .text, date: date, text: nil, filePaths: [], imagePath: nil,
            imagePixelWidth: nil, imagePixelHeight: nil, byteSize: 0, contentHash: capture.contentHash,
            sourceBundleID: source?.bundleID, sourceAppName: source?.appName, isPinned: false
        )
        switch capture {
        case let .text(text):
            item.text = text
        case let .image(_, width, height):
            item.payload = .image
            item.imagePixelWidth = width
            item.imagePixelHeight = height
        case let .files(urls):
            item.payload = .files
            item.filePaths = urls.map(\.path)
        }
        storedItems.append(item)
        return item
    }

    func items(limit: Int) -> [ClipboardItem] {
        lock.lock()
        defer { lock.unlock() }
        return Array(storedItems.sorted { $0.date > $1.date }.prefix(limit))
    }

    func setPinned(_ pinned: Bool, id: UUID) {
        guard let index = storedItems.firstIndex(where: { $0.id == id }) else { return }
        storedItems[index].isPinned = pinned
    }

    func delete(id: UUID) {
        storedItems.removeAll { $0.id == id }
    }

    func purge(olderThan cutoff: Date) {
        purgeCutoffs.append(cutoff)
        storedItems.removeAll { !$0.isPinned && $0.date < cutoff }
    }

    func trim(toMaxCount maxCount: Int) {
        lock.lock()
        defer { lock.unlock() }
        trimCounts.append(maxCount)
    }

    func trim(toMaxImageBytes maxBytes: Int64) {
        lock.lock()
        defer { lock.unlock() }
        trimImageBytes.append(maxBytes)
    }

    func pinnedVoiceRecordIDs() -> Set<UUID> {
        pinnedVoiceIDs
    }

    func setVoiceRecordPinned(_ pinned: Bool, recordID: UUID) {
        if pinned { pinnedVoiceIDs.insert(recordID) } else { pinnedVoiceIDs.remove(recordID) }
    }
}
