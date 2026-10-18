import AppKit

/// What a clipboard row or shelf card carries when dragged into another app: the copied files,
/// the stored image as PNG data, or the text (links also as a URL).
enum ClipboardEntryDrag {
    /// Moving this far after mouse-down starts a drag rather than a click.
    static let threshold: CGFloat = 4

    static func beginsDrag(from start: NSPoint, to point: NSPoint) -> Bool {
        hypot(point.x - start.x, point.y - start.y) >= threshold
    }

    /// Nothing for entries whose files are gone; the drag then never starts.
    static func items(for entry: ClipboardEntry, isMissing: Bool) -> [NSPasteboardWriting] {
        guard !isMissing else { return [] }
        if !entry.filePaths.isEmpty {
            guard entry.filePaths.count <= ClipboardCaptureRules.maximumFileCount,
                  entry.filePaths.allSatisfy({ !$0.contains("\0") }) else { return [] }
            return entry.fileURLs as [NSURL]
        }
        if let imagePath = entry.imagePath {
            let item = NSPasteboardItem()
            let provider = ClipboardImageDragProvider(path: imagePath)
            guard item.setDataProvider(provider, forTypes: [.png]) else { return [] }
            return [item]
        }
        guard let text = entry.text, !text.isEmpty, text.utf8.count <= ClipboardCaptureRules.maximumTextBytes else {
            return []
        }
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        if entry.kind == .link, let url = URL(string: text), url.scheme != nil {
            item.setString(url.absoluteString, forType: .URL)
        }
        return [item]
    }
}

/// Reads the stored image only when the drop target asks for it, and only if it is still the
/// regular file within the size limit that the clipboard recorded. The stored file's path is
/// never handed out, so the target cannot write into Typeflux's storage.
final class ClipboardImageDragProvider: NSObject, NSPasteboardItemDataProvider {
    let path: String

    init(path: String) {
        self.path = path
    }

    func pngData() -> Data? {
        let url = URL(fileURLWithPath: path)
        guard let revision = try? ClipboardImageRevision(url),
              let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              revision.matches(url), data.count <= ClipboardCaptureRules.maximumImageBytes else { return nil }
        return data
    }

    func pasteboard(_: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        guard type == .png, let data = pngData() else { return }
        item.setData(data, forType: .png)
    }
}
