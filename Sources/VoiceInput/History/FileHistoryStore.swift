import Foundation

final class FileHistoryStore: HistoryStore {
    private let queue = DispatchQueue(label: "history.store")

    private let baseDir: URL
    private let indexURL: URL

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        baseDir = appSupport.appendingPathComponent("VoiceInput", isDirectory: true)
        indexURL = baseDir.appendingPathComponent("history.json")

        try? FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
    }

    func save(record: HistoryRecord) {
        queue.async {
            var list = self.readIndex()
            if let existingIndex = list.firstIndex(where: { $0.id == record.id }) {
                list[existingIndex] = record
            } else {
                list.insert(record, at: 0)
            }
            self.writeIndex(list)
        }
    }

    func list() -> [HistoryRecord] {
        queue.sync {
            readIndex()
        }
    }

    func delete(id: UUID) {
        queue.async {
            var list = self.readIndex()
            guard let index = list.firstIndex(where: { $0.id == id }) else { return }
            let record = list.remove(at: index)
            self.removeAudioFileIfNeeded(for: record)
            self.writeIndex(list)
        }
    }

    func purge(olderThanDays days: Int) {
        queue.async {
            let cutoff = Date().addingTimeInterval(-TimeInterval(days) * 24 * 3600)
            var list = self.readIndex()

            let (keep, drop) = list.partitioned { $0.date >= cutoff }
            list = keep
            self.writeIndex(list)

            for r in drop {
                self.removeAudioFileIfNeeded(for: r)
            }
        }
    }

    func clear() {
        queue.async {
            let list = self.readIndex()
            for r in list {
                self.removeAudioFileIfNeeded(for: r)
            }
            self.writeIndex([])
        }
    }

    func exportMarkdown() throws -> URL {
        let records = list()
        let dateFmt = ISO8601DateFormatter()

        var md = "# VoiceInput History\n\n"
        for r in records {
            md += "## \(dateFmt.string(from: r.date))\n\n"
            md += "- Mode: \(r.mode.rawValue)\n"
            md += "- Recording: \(r.recordingStatus.rawValue)\n"
            md += "- Transcription: \(r.transcriptionStatus.rawValue)\n"
            md += "- Processing: \(r.processingStatus.rawValue)\n"
            md += "- Apply: \(r.applyStatus.rawValue)\n"
            if let audioFilePath = r.audioFilePath {
                md += "- Audio: \(audioFilePath)\n"
            }
            if let transcriptText = r.transcriptText, !transcriptText.isEmpty {
                md += "\n### Transcript\n\n\(transcriptText)\n"
            }
            if let personaResultText = r.personaResultText, !personaResultText.isEmpty {
                md += "\n### Persona Result\n\n\(personaResultText)\n"
            }
            if let selectionOriginalText = r.selectionOriginalText, !selectionOriginalText.isEmpty {
                md += "\n### Selected Text\n\n\(selectionOriginalText)\n"
            }
            if let selectionEditedText = r.selectionEditedText, !selectionEditedText.isEmpty {
                md += "\n### Selection Result\n\n\(selectionEditedText)\n"
            }
            if let errorMessage = r.errorMessage, !errorMessage.isEmpty {
                md += "\n### Error\n\n\(errorMessage)\n"
            }
            md += "\n\n"
        }

        let url = baseDir.appendingPathComponent("history-\(Int(Date().timeIntervalSince1970)).md")
        try md.data(using: .utf8)?.write(to: url)
        return url
    }

    private func readIndex() -> [HistoryRecord] {
        guard let data = try? Data(contentsOf: indexURL) else { return [] }
        return (try? JSONDecoder().decode([HistoryRecord].self, from: data)) ?? []
    }

    private func writeIndex(_ list: [HistoryRecord]) {
        do {
            let data = try JSONEncoder().encode(list)
            try data.write(to: indexURL, options: [.atomic])
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .historyStoreDidChange, object: nil)
            }
        } catch {
            // ignore
        }
    }

    private func removeAudioFileIfNeeded(for record: HistoryRecord) {
        guard let audioFilePath = record.audioFilePath, !audioFilePath.isEmpty else { return }
        try? FileManager.default.removeItem(atPath: audioFilePath)
    }
}

private extension Array {
    func partitioned(_ isIncluded: (Element) -> Bool) -> ([Element], [Element]) {
        var a: [Element] = []
        var b: [Element] = []
        a.reserveCapacity(count)
        b.reserveCapacity(count)
        for e in self {
            if isIncluded(e) { a.append(e) } else { b.append(e) }
        }
        return (a, b)
    }
}
