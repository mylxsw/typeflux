import AppKit
import Foundation

final class SystemPasteboardReader: PasteboardReading {
    private let pasteboard: NSPasteboard

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    var changeCount: Int {
        pasteboard.changeCount
    }

    func readContents() -> PasteboardContents {
        var contents = PasteboardContents()
        for item in pasteboard.pasteboardItems ?? [] {
            contents.types.formUnion(item.types.map(\.rawValue))
        }
        // Skip reading payloads that will be discarded anyway (passwords, transient writes).
        guard !ClipboardCaptureRules.shouldIgnore(types: contents.types) else { return contents }

        contents.string = pasteboard.string(forType: .string)
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        contents.fileURLs = urls ?? []
        if contents.fileURLs.isEmpty {
            contents.imageData = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff)
        }
        return contents
    }
}
