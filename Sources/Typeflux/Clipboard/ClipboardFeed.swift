import Foundation

/// Builds, filters and groups the clipboard panel's rows. Pure, so it is fully unit tested.
enum ClipboardFeed {
    enum Section: Equatable {
        case snippets
        case pinned
        case today
        case yesterday
        case earlier

        var title: String {
            switch self {
            case .snippets: L("clipboard.snippet.permanent")
            case .pinned: L("clipboard.section.pinned")
            case .today: L("clipboard.section.today")
            case .yesterday: L("clipboard.section.yesterday")
            case .earlier: L("clipboard.section.earlier")
            }
        }
    }

    /// Keeps copied items and individual voice results available in their own tabs.
    static func entries(
        clipboardItems: [ClipboardItem],
        voiceRecords: [HistoryRecord],
        pinnedVoiceRecordIDs: Set<UUID>
    ) -> [ClipboardEntry] {
        var entries = clipboardItems.map(entry(for:))
        for record in voiceRecords {
            guard let text = voiceText(of: record) else { continue }
            entries.append(ClipboardEntry(
                origin: .voice(record.id), kind: .voice, date: record.date, text: text,
                filePaths: [], imagePath: nil, imagePixelSize: nil, byteSize: Int64(text.utf8.count),
                sourceBundleID: nil, sourceAppName: nil, isPinned: pinnedVoiceRecordIDs.contains(record.id)
            ))
        }
        return entries.sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
            return lhs.date > rhs.date
        }
    }

    static func entry(for item: ClipboardItem) -> ClipboardEntry {
        let kind: ClipboardEntryKind
        var pixelSize: CGSize?
        switch item.payload {
        case .text:
            kind = ClipboardContentClassifier.kind(forText: item.text ?? "")
        case .image:
            kind = .image
            if let width = item.imagePixelWidth, let height = item.imagePixelHeight {
                pixelSize = CGSize(width: width, height: height)
            }
        case .files:
            kind = ClipboardContentClassifier.kind(forFilePaths: item.filePaths)
        }
        return ClipboardEntry(
            origin: .clipboard(item.id), kind: kind, date: item.date, text: item.payload == .text ? item.text : nil,
            filePaths: item.filePaths, imagePath: item.imagePath, imagePixelSize: pixelSize,
            byteSize: item.byteSize, sourceBundleID: item.sourceBundleID,
            sourceAppName: item.sourceAppName, isPinned: item.isPinned, snippet: item.snippet
        )
    }

    static func initialCategory(for entries: [ClipboardEntry]) -> ClipboardCategory {
        if entries.contains(where: { entry in
            if case .clipboard = entry.origin { return entry.snippet == nil }
            return false
        }) { return .all }
        if entries.contains(where: { entry in
            if case .voice = entry.origin { return true }
            return false
        }) { return .voice }
        return entries.isEmpty ? .all : .snippet
    }

    /// `searchText` lets callers pass text built once per entry instead of joining it on every keystroke.
    static func filter(
        _ entries: [ClipboardEntry],
        category: ClipboardCategory,
        query: String,
        sourceBundleID: String? = nil,
        searchText: (ClipboardEntry) -> String = searchableText(of:)
    ) -> [ClipboardEntry] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return entries.filter { entry in
            switch category {
            case .all:
                guard case .clipboard = entry.origin, entry.snippet == nil else { return false }
            case .voice:
                guard case .voice = entry.origin else { return false }
            case .snippet:
                guard entry.snippet != nil else { return false }
            }
            guard sourceBundleID == nil || entry.sourceBundleID == sourceBundleID else { return false }
            guard !needle.isEmpty else { return true }
            return searchText(entry).localizedCaseInsensitiveContains(needle)
        }
    }

    static func section(for entry: ClipboardEntry, now: Date, calendar: Calendar = .current) -> Section {
        if entry.snippet != nil { return .snippets }
        if entry.isPinned { return .pinned }
        if calendar.isDate(entry.date, inSameDayAs: now) { return .today }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(entry.date, inSameDayAs: yesterday) {
            return .yesterday
        }
        return .earlier
    }

    static func voiceText(of record: HistoryRecord) -> String? {
        guard let text = record.finalText?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }
        return text
    }

    static func searchableText(of entry: ClipboardEntry) -> String {
        let fileNames = entry.filePaths.map { ($0 as NSString).lastPathComponent }
        return ([entry.text ?? entry.title, entry.snippet?.name ?? "", entry.snippet?.alias ?? "", entry.sourceAppName ?? ""] + fileNames).joined(separator: "\n")
    }
}
