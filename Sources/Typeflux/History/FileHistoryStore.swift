import Foundation

final class FileHistoryStore: HistoryStore {
    private let queue = DispatchQueue(label: "history.store")

    private let baseDir: URL
    private let indexURL: URL

    init(baseDir: URL) {
        self.baseDir = baseDir
        self.indexURL = baseDir.appendingPathComponent("history.json")
        try? FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
    }

    convenience init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let newBaseDir = appSupport.appendingPathComponent("Typeflux", isDirectory: true)
        let legacyBaseDir = appSupport.appendingPathComponent("Typeflux", isDirectory: true)
        if !FileManager.default.fileExists(atPath: newBaseDir.path),
           FileManager.default.fileExists(atPath: legacyBaseDir.path) {
            try? FileManager.default.moveItem(at: legacyBaseDir, to: newBaseDir)
        }
        self.init(baseDir: newBaseDir)
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

    func list(limit: Int, offset: Int, searchQuery: String?) -> [HistoryRecord] {
        queue.sync {
            let records = filteredIndex(searchQuery: searchQuery)
            guard offset < records.count else { return [] }
            let endIndex = min(offset + limit, records.count)
            return Array(records[offset..<endIndex])
        }
    }

    func record(id: UUID) -> HistoryRecord? {
        queue.sync {
            readIndex().first(where: { $0.id == id })
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

        var md = "# Typeflux History\n\n"
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
            if let pipelineTiming = r.pipelineTiming, pipelineTiming.hasData {
                let pipelineStats = r.pipelineStats ?? pipelineTiming.generatedStats()
                md += "\n### Pipeline Stats\n\n"
                md += "- Recording stopped: \(pipelineStats.recordingStoppedAt?.ISO8601Format() ?? "<none>")\n"
                md += "- Audio file ready: \(pipelineStats.audioFileReadyAt?.ISO8601Format() ?? "<none>")\n"
                md += "- STT started: \(pipelineStats.transcriptionStartedAt?.ISO8601Format() ?? "<none>")\n"
                md += "- STT completed: \(pipelineStats.transcriptionCompletedAt?.ISO8601Format() ?? "<none>")\n"
                md += "- LLM started: \(pipelineStats.llmProcessingStartedAt?.ISO8601Format() ?? "<none>")\n"
                md += "- LLM completed: \(pipelineStats.llmProcessingCompletedAt?.ISO8601Format() ?? "<none>")\n"
                md += "- Apply started: \(pipelineStats.applyStartedAt?.ISO8601Format() ?? "<none>")\n"
                md += "- Apply completed: \(pipelineStats.applyCompletedAt?.ISO8601Format() ?? "<none>")\n"
                if let value = pipelineStats.stopToAudioReadyMilliseconds {
                    md += "- Stop -> audio ready: \(value) ms\n"
                }
                if let value = pipelineStats.transcriptionDurationMilliseconds {
                    md += "- STT duration: \(value) ms\n"
                }
                if let value = pipelineStats.stopToTranscriptionCompletedMilliseconds {
                    md += "- Stop -> STT completed: \(value) ms\n"
                }
                if let value = pipelineStats.transcriptToLLMStartMilliseconds {
                    md += "- Transcript -> LLM start: \(value) ms\n"
                }
                if let value = pipelineStats.llmDurationMilliseconds {
                    md += "- LLM duration: \(value) ms\n"
                }
                if let value = pipelineStats.applyDurationMilliseconds {
                    md += "- Apply duration: \(value) ms\n"
                }
                if let value = pipelineStats.endToEndMilliseconds {
                    md += "- End-to-end: \(value) ms\n"
                }
            } else if let pipelineStats = r.pipelineStats, pipelineStats.hasData {
                md += "\n### Pipeline Stats\n\n"
                md += "- Recording stopped: \(pipelineStats.recordingStoppedAt?.ISO8601Format() ?? "<none>")\n"
                md += "- Audio file ready: \(pipelineStats.audioFileReadyAt?.ISO8601Format() ?? "<none>")\n"
                md += "- STT started: \(pipelineStats.transcriptionStartedAt?.ISO8601Format() ?? "<none>")\n"
                md += "- STT completed: \(pipelineStats.transcriptionCompletedAt?.ISO8601Format() ?? "<none>")\n"
                md += "- LLM started: \(pipelineStats.llmProcessingStartedAt?.ISO8601Format() ?? "<none>")\n"
                md += "- LLM completed: \(pipelineStats.llmProcessingCompletedAt?.ISO8601Format() ?? "<none>")\n"
                md += "- Apply started: \(pipelineStats.applyStartedAt?.ISO8601Format() ?? "<none>")\n"
                md += "- Apply completed: \(pipelineStats.applyCompletedAt?.ISO8601Format() ?? "<none>")\n"
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

    private func filteredIndex(searchQuery: String?) -> [HistoryRecord] {
        let records = readIndex().sorted { $0.date > $1.date }
        let trimmedQuery = searchQuery?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmedQuery.isEmpty else { return records }

        return records.filter {
            $0.mode.rawValue.localizedCaseInsensitiveContains(trimmedQuery) ||
            $0.text.localizedCaseInsensitiveContains(trimmedQuery) ||
            ($0.transcriptText?.localizedCaseInsensitiveContains(trimmedQuery) ?? false) ||
            ($0.personaResultText?.localizedCaseInsensitiveContains(trimmedQuery) ?? false) ||
            ($0.selectionEditedText?.localizedCaseInsensitiveContains(trimmedQuery) ?? false) ||
            ($0.errorMessage?.localizedCaseInsensitiveContains(trimmedQuery) ?? false) ||
            ($0.audioFilePath?.localizedCaseInsensitiveContains(trimmedQuery) ?? false)
        }
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
