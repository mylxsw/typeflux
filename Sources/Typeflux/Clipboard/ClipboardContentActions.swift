import AppKit
import Foundation
import Vision

/// Performs clipboard panel actions with the pasteboard, Finder and Vision.
final class SystemClipboardContentActions: ClipboardContentActing {
    private let pasteboard: NSPasteboard
    private let fileManager: FileManager
    private let downloadsDirectory: URL?

    init(
        pasteboard: NSPasteboard = .general,
        fileManager: FileManager = .default,
        downloadsDirectory: URL? = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
    ) {
        self.pasteboard = pasteboard
        self.fileManager = fileManager
        self.downloadsDirectory = downloadsDirectory
    }

    @discardableResult
    func writeToPasteboard(_ entry: ClipboardEntry, asPlainText: Bool) -> Bool {
        if !entry.filePaths.isEmpty {
            pasteboard.clearContents()
            if asPlainText {
                return pasteboard.setString(entry.filePaths.joined(separator: "\n"), forType: .string)
            }
            return pasteboard.writeObjects(entry.fileURLs as [NSURL])
        }
        guard let imagePath = entry.imagePath, let png = fileManager.contents(atPath: imagePath) else { return false }
        let item = NSPasteboardItem()
        item.setData(png, forType: .png)
        if let tiff = NSImage(data: png)?.tiffRepresentation {
            item.setData(tiff, forType: .tiff)
        }
        pasteboard.clearContents()
        return pasteboard.writeObjects([item])
    }

    func sendPasteShortcut() {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        else { return }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }

    func revealInFinder(_ urls: [URL]) {
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    func saveToDownloads(_ url: URL) -> URL? {
        guard let downloads = downloadsDirectory else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let baseName = "Typeflux \(formatter.string(from: Date()))"
        var destination = downloads.appendingPathComponent(baseName).appendingPathExtension(url.pathExtension)
        var suffix = 2
        while fileManager.fileExists(atPath: destination.path) {
            destination = downloads.appendingPathComponent("\(baseName) \(suffix)").appendingPathExtension(url.pathExtension)
            suffix += 1
        }
        do {
            try fileManager.copyItem(at: url, to: destination)
            return destination
        } catch {
            ErrorLogStore.shared.log("Clipboard save to Downloads failed: \(error.localizedDescription)")
            return nil
        }
    }

    func recognizeText(in imageURL: URL) async -> String? {
        await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true
            let handler = VNImageRequestHandler(url: imageURL)
            do {
                try handler.perform([request])
            } catch {
                ErrorLogStore.shared.log("Clipboard text recognition failed: \(error.localizedDescription)")
                return nil
            }
            let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }.value
    }
}
