import SwiftUI

/// Formats the secondary line of a clipboard row and file-type colors.
enum ClipboardEntryFormatter {
    /// Subtitle parts, e.g. `["PDF", "2.3 MB", "Finder", "12 min. ago"]`.
    static func details(for entry: ClipboardEntry, now: Date = Date()) -> [String] {
        var parts = kindDetails(for: entry)
        if !entry.kind.isTextual, entry.byteSize > 0 {
            parts.append(ByteCountFormatter.string(fromByteCount: entry.byteSize, countStyle: .file))
        }
        if let app = entry.sourceAppName, !app.isEmpty {
            parts.append(app)
        }
        parts.append(relativeTime(from: entry.date, to: now))
        return parts
    }

    private static func kindDetails(for entry: ClipboardEntry) -> [String] {
        switch entry.kind {
        case .voice:
            return [L("clipboard.kind.voice")]
        case .text:
            return [L("clipboard.kind.text"), L("clipboard.entry.characters", entry.text?.count ?? 0)]
        case .link:
            return [L("clipboard.kind.link")] + [entry.text.flatMap(URL.init(string:))?.host].compactMap { $0 }
        case .code:
            return [L("clipboard.kind.code")]
        case .image:
            let format = entry.filePaths.first.map(ClipboardContentClassifier.badge(forFilePath:)) ?? "PNG"
            let size = entry.imagePixelSize.map { "\(Int($0.width))×\(Int($0.height))" }
            return [format] + [size].compactMap { $0 }
        case .images:
            return [L("clipboard.kind.image")]
        case .pdf:
            return ["PDF"]
        case .document:
            return [ClipboardContentClassifier.badge(forFilePath: entry.filePaths.first ?? "")]
        case .video:
            return [L("clipboard.kind.video")]
        case .audio:
            return [L("clipboard.kind.audio")]
        case .files:
            return [L("clipboard.kind.file")]
        }
    }

    static func relativeTime(from date: Date, to now: Date) -> String {
        if now.timeIntervalSince(date) < 60 {
            return L("clipboard.time.justNow")
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        formatter.locale = AppLocalization.shared.locale
        return formatter.localizedString(for: date, relativeTo: now)
    }

    static func badgeColor(forFilePath path: String) -> Color {
        switch (path as NSString).pathExtension.lowercased() {
        case "pdf": Color(red: 0.9, green: 0.28, blue: 0.3)
        case "doc", "docx", "pages", "rtf", "txt", "md": Color(red: 0.23, green: 0.51, blue: 0.96)
        case "xls", "xlsx", "numbers", "csv": Color(red: 0.13, green: 0.63, blue: 0.42)
        case "ppt", "pptx", "key": Color(red: 0.96, green: 0.62, blue: 0.04)
        default: Color(red: 0.55, green: 0.55, blue: 0.6)
        }
    }
}
