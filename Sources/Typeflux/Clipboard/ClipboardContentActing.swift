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
    /// Binds read-only preparation at the explicit action, before its task is queued.
    @MainActor func textRecognition(in imageURL: URL) -> ClipboardTextRecognition
}


extension ClipboardContentActing {
    var pasteboardRevision: Int? { nil }
    @MainActor func textRecognition(in imageURL: URL) -> ClipboardTextRecognition {
        .init(recognize: { try await self.recognizeText(in: imageURL) })
    }
    func prepareImage(_ entry: ClipboardEntry) async throws -> AskWorkflowImage.Clipboard? {
        guard entry.filePaths.isEmpty, let path = entry.imagePath else { return nil }
        return try await AskWorkflowImage.clipboard(URL(fileURLWithPath: path), preserveOriginalPNG: true)
    }
}

/// Native availability is retained separately from the caller's permission to copy.
/// Independent custom actions/recognizers keep their own lifecycle contract.
@MainActor struct ClipboardTextRecognition {
    let recognize: () async throws -> String?
    var isCurrent: () -> Bool = { true }

    static func make(in url: URL, worker: MediaWorker,
                     textRecognizer: (any ImageTextRecognizing)? = nil) -> Self {
        if let textRecognizer {
            return .init(recognize: { try await textRecognizer.recognizeText(in: .url(url)).string })
        }
        let authorization = worker.authorization()
        let recognizer = ClipboardTextRecognizer(worker: worker)
        return .init(recognize: { try await recognizer.recognize(url, authorization: authorization) },
                     isCurrent: { worker.permits(authorization) })
    }
}
