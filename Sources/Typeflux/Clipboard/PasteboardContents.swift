import Foundation

/// The parts of a pasteboard the clipboard history cares about.
struct PasteboardContents: Equatable {
    var types: Set<String> = []
    var string: String?
    var fileURLs: [URL] = []
    /// Raw PNG or TIFF data, read only when no file URLs are present.
    var imageData: Data?
}
