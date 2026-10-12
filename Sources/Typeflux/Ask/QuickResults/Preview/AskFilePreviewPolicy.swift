import Darwin
import Foundation

enum AskFilePreviewKind: String, CaseIterable, Sendable {
    case image, pdf, text, markdown, table, document, video, audio

    var readsText: Bool {
        [.text, .markdown, .table].contains(self)
    }

    var canPrefetch: Bool {
        self == .image || self == .pdf
    }
}

/// Classification never touches the filesystem. Mount and residency checks run in the reader child.
enum AskFilePreviewPolicy {
    static func isResidentRegularFile(mode: mode_t, flags: UInt32) -> Bool {
        flags & UInt32(SF_DATALESS) == 0 && mode & S_IFMT == S_IFREG
    }

    static func kind(for hit: AskFileHit) -> AskFilePreviewKind? {
        guard hit.kind != .folder else { return nil }
        return kind(path: hit.path)
    }

    static func kind(path: String) -> AskFilePreviewKind? {
        let name = (path as NSString).lastPathComponent.lowercased()
        let ext = (name as NSString).pathExtension
        guard !name.hasPrefix(".env"), !name.hasPrefix("id_rsa"), !name.hasPrefix("credentials"),
              !["pem", "key", "p12"].contains(ext) else { return nil }
        if AskFileType.extensions[.image]?.contains(ext) == true {
            return .image
        }
        if ext == "pdf" {
            return .pdf
        }
        if ["md", "markdown"].contains(ext) {
            return .markdown
        }
        if ["csv", "tsv"].contains(ext) {
            return .table
        }
        if AskFileType.extensions[.code]?.contains(ext) == true || ["txt", "log", "tex"].contains(ext) {
            return .text
        }
        if [
            "doc",
            "docx",
            "pages",
            "ppt",
            "pptx",
            "keynote",
            "xls",
            "xlsx",
            "numbers",
            "rtf",
            "rtfd",
            "odt",
            "ods",
            "odp",
            "epub",
            "wps"
        ].contains(ext) {
            return .document
        }
        if ["mp4", "mov", "m4v", "avi", "mkv", "webm"].contains(ext) {
            return .video
        }
        if ["mp3", "m4a", "aac", "wav", "aiff", "aif", "flac", "ogg", "caf"].contains(ext) {
            return .audio
        }
        return nil
    }
}
