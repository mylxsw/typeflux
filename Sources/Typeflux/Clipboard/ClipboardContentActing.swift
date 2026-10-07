import Foundation

/// System side effects of clipboard panel actions on non-text entries.
protocol ClipboardContentActing: AnyObject {
    /// Puts the entry's files or image on the general pasteboard; `asPlainText` writes file paths.
    @discardableResult
    func writeToPasteboard(_ entry: ClipboardEntry, asPlainText: Bool) -> Bool
    /// Sends ⌘V to the frontmost app.
    func sendPasteShortcut()
    func revealInFinder(_ urls: [URL])
    /// Copies a stored image into ~/Downloads and returns the new file.
    func saveToDownloads(_ url: URL) -> URL?
    func recognizeText(in imageURL: URL) async -> String?
}
