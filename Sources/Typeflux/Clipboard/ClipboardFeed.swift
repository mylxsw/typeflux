import Foundation

/// Builds, filters and groups the clipboard panel's rows. Pure, so it is fully unit tested.
enum ClipboardFeed {
    enum Section: Equatable {
        case pinned
        case today
        case yesterday
        case earlier

        var title: String {
            switch self {
            case .pinned: L("clipboard.section.pinned")
            case .today: L("clipboard.section.today")
            case .yesterday: L("clipboard.section.yesterday")
            case .earlier: L("clipboard.section.earlier")
            }
        }
    }

    /// Merges voice results with clipboard items, newest first and pinned entries on top.
    ///
    /// Copying a voice result puts the same text on the clipboard; that copy folds into the
    /// voice entry (keeping the later date) so the text shows once.
    static func entries(
        clipboardItems: [ClipboardItem],
        voiceRecords: [HistoryRecord],
        pinnedVoiceRecordIDs: Set<UUID>
    ) -> [ClipboardEntry] {
        var voiceDates: [String: (record: HistoryRecord, date: Date)] = [:]
        for record in voiceRecords {
            guard let text = voiceText(of: record), voiceDates[text] == nil else { continue }
            voiceDates[text] = (record, record.date)
        }

        var entries: [ClipboardEntry] = []
        for item in clipboardItems {
            if item.payload == .text, let text = item.text?.trimmingCharacters(in: .whitespacesAndNewlines),
               let voice = voiceDates[text] {
                voiceDates[text] = (voice.record, max(voice.date, item.date))
                continue
            }
            entries.append(entry(for: item))
        }
        for (text, voice) in voiceDates {
            entries.append(ClipboardEntry(
                origin: .voice(voice.record.id), kind: .voice, date: voice.date, text: text,
                filePaths: [], imagePath: nil, imagePixelSize: nil, byteSize: Int64(text.utf8.count),
                sourceBundleID: nil, sourceAppName: nil, isPinned: pinnedVoiceRecordIDs.contains(voice.record.id)
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
            sourceAppName: item.sourceAppName, isPinned: item.isPinned
        )
    }

    /// `searchText` lets callers pass text built once per entry instead of joining it on every keystroke.
    static func filter(
        _ entries: [ClipboardEntry],
        category: ClipboardCategory,
        query: String,
        searchText: (ClipboardEntry) -> String = searchableText(of:)
    ) -> [ClipboardEntry] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return entries.filter { entry in
            guard category == .all || entry.kind.category == category else { return false }
            guard !needle.isEmpty else { return true }
            return searchText(entry).localizedCaseInsensitiveContains(needle)
        }
    }

    static func section(for entry: ClipboardEntry, now: Date, calendar: Calendar = .current) -> Section {
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
        return ([entry.text ?? entry.title, entry.sourceAppName ?? ""] + fileNames).joined(separator: "\n")
    }
}
