import Foundation

/// A clipboard payload persisted by `ClipboardHistoryStore`.
struct ClipboardItem: Identifiable, Equatable {
    enum Payload: String {
        case text
        case image
        case files
    }

    let id: UUID
    var payload: Payload
    /// The last time this content was copied. Copying it again moves it to the top.
    var date: Date
    var text: String?
    var filePaths: [String]
    /// Absolute path of the stored PNG for image payloads.
    var imagePath: String?
    var imagePixelWidth: Int?
    var imagePixelHeight: Int?
    var byteSize: Int64
    var contentHash: String
    var sourceBundleID: String?
    var sourceAppName: String?
    var isPinned: Bool
}
