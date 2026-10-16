import Foundation

/// System side effects of clipboard panel actions on non-text entries.
protocol ClipboardContentActing: AnyObject {
    var pasteboardRevision: Int? { get }
    /// Puts the entry's files or image on the general pasteboard; `asPlainText` writes file paths.
    @discardableResult
    func writeToPasteboard(_ entry: ClipboardEntry, asPlainText: Bool, image: AskWorkflowImage.Clipboard?) -> Bool
    func prepareImage(_ entry: ClipboardEntry) async throws -> AskWorkflowImage.Clipboard?
    /// Sends ⌘V to the frontmost app.
    func sendPasteShortcut()
    func revealInFinder(_ urls: [URL])
    /// Copies a stored image into ~/Downloads and returns the new file.
    func saveToDownloads(_ url: URL) -> URL?
    func recognizeText(in imageURL: URL) async throws -> String?
}


extension ClipboardContentActing {
    var pasteboardRevision: Int? { nil }
    func prepareImage(_ entry: ClipboardEntry) async throws -> AskWorkflowImage.Clipboard? {
        guard entry.filePaths.isEmpty, let path = entry.imagePath else { return nil }
        return try await AskWorkflowImage.clipboard(URL(fileURLWithPath: path), preserveOriginalPNG: true)
    }
}
