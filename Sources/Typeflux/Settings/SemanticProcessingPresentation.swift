import Foundation

enum SemanticProcessingPresentation {
    // Only allowlisted codes reach localization; raw worker errors never become UI text.
    // swiftlint:disable:next cyclomatic_complexity
    static func reasonKey(_ reason: String) -> String {
        switch reason {
        case "password-required": "semantic.details.reason.password"
        case "unsupported-document": "semantic.details.reason.unsupported"
        case "permission-denied": "semantic.details.reason.permission"
        case "missing-or-unavailable", "metadata-unavailable", "file-missing-or-changed", "media-missing-or-changed":
            "semantic.details.reason.unavailable"
        case "empty-or-no-text": "semantic.details.reason.emptyText"
        case "empty-or-no-media": "semantic.details.reason.emptyMedia"
        case "audio-silent": "semantic.details.reason.silent"
        case "image-no-text": "semantic.details.reason.imageNoText"
        case "encoding-failed", "media-encoding-failed": "semantic.details.reason.encoding"
        case "pdf-ocr-failed", "image-ocr-failed": "semantic.details.reason.ocr"
        case "unreadable-content", "reader-failed", "extraction-failed", "media-extraction-failed",
             "inconsistent-media-segments": "semantic.details.reason.read"
        default: "semantic.details.reason.unknown"
        }
    }

    static func progress(_ item: SemanticFileStore.ProcessingItem) -> String {
        var parts: [String] = []
        if item.savedChunks > 0 {
            parts.append(L(
                "semantic.details.savedChunks",
                item.savedChunks.formatted(),
                item.encodedChunks.formatted()
            ))
        }
        if item.priority == .document, item.offset > 0 {
            parts.append(L("semantic.details.savedOffset", item.offset.formatted()))
        }
        if item.savedMediaSegments > 0 {
            parts.append(L("semantic.details.savedSegments", item.savedMediaSegments.formatted()))
        }
        if let seconds = item.audioCovered {
            parts.append(L("semantic.details.audioCovered", seconds.formatted(.number.precision(.fractionLength(1)))))
        }
        if let seconds = item.videoChecked {
            parts.append(L("semantic.details.videoChecked", seconds.formatted(.number.precision(.fractionLength(1)))))
        }
        return parts.isEmpty ? L("semantic.details.noSavedProgress") : parts.joined(separator: " · ")
    }
}
