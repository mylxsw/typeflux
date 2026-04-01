import Foundation

final class UsageStatsStore {
    static let shared = UsageStatsStore()

    private let defaults = UserDefaults.standard
    private let queue = DispatchQueue(label: "usage.stats")

    private enum Key: String {
        case totalSessions = "stats.totalSessions"
        case successfulSessions = "stats.successfulSessions"
        case failedSessions = "stats.failedSessions"
        case totalRecordingSeconds = "stats.totalRecordingSeconds"
        case totalCharacters = "stats.totalCharacters"
        case totalWords = "stats.totalWords"
        case dictationCount = "stats.dictationCount"
        case personaRewriteCount = "stats.personaRewriteCount"
        case editSelectionCount = "stats.editSelectionCount"
        case askAnswerCount = "stats.askAnswerCount"
        case didBackfill = "stats.didBackfill"
    }

    // MARK: - Raw counters

    var totalSessions: Int {
        defaults.integer(forKey: Key.totalSessions.rawValue)
    }

    var successfulSessions: Int {
        defaults.integer(forKey: Key.successfulSessions.rawValue)
    }

    var failedSessions: Int {
        defaults.integer(forKey: Key.failedSessions.rawValue)
    }

    var totalRecordingSeconds: Double {
        defaults.double(forKey: Key.totalRecordingSeconds.rawValue)
    }

    var totalCharacterCount: Int {
        defaults.integer(forKey: Key.totalCharacters.rawValue)
    }

    var totalWordCount: Int {
        defaults.integer(forKey: Key.totalWords.rawValue)
    }

    var dictationCount: Int {
        defaults.integer(forKey: Key.dictationCount.rawValue)
    }

    var personaRewriteCount: Int {
        defaults.integer(forKey: Key.personaRewriteCount.rawValue)
    }

    var editSelectionCount: Int {
        defaults.integer(forKey: Key.editSelectionCount.rawValue)
    }

    var askAnswerCount: Int {
        defaults.integer(forKey: Key.askAnswerCount.rawValue)
    }

    // MARK: - Computed metrics for Overview

    var completionRate: Int {
        let total = totalSessions
        guard total > 0 else { return 0 }
        return min(100, Int(round(Double(successfulSessions) / Double(total) * 100)))
    }

    var totalDictationMinutes: Int {
        max(0, Int(round(totalRecordingSeconds / 60.0)))
    }

    var totalDictationMinutesText: String {
        NumberFormatter.localizedString(from: NSNumber(value: totalDictationMinutes), number: .decimal)
    }

    /// Estimated time saved vs typing manually.
    /// Assumes average typing speed of ~40 Chinese characters per minute or ~200 English characters per minute.
    /// We use a blended estimate of 100 characters per minute for a conservative calculation.
    var savedMinutes: Int {
        guard totalCharacterCount > 0 else { return 0 }
        let typingMinutes = Double(totalCharacterCount) / 100.0
        let dictationMinutes = totalRecordingSeconds / 60.0
        return max(0, Int(round(typingMinutes - dictationMinutes)))
    }

    /// Average words per minute of dictation output.
    var averagePaceWPM: Int {
        let minutes = totalRecordingSeconds / 60.0
        guard minutes >= 0.5 else { return 0 }
        return Int(round(Double(totalWordCount) / minutes))
    }

    // MARK: - Recording

    func recordSession(record: HistoryRecord) {
        queue.async { [self] in
            increment(.totalSessions, by: 1)

            let isSuccess = record.applyStatus == .succeeded || record.applyStatus == .skipped && record.transcriptionStatus == .succeeded
            let isFailure = record.hasFailure

            if isSuccess {
                increment(.successfulSessions, by: 1)
            }
            if isFailure {
                increment(.failedSessions, by: 1)
            }

            if let duration = record.recordingDurationSeconds, duration > 0 {
                incrementDouble(.totalRecordingSeconds, by: duration)
            }

            let finalText = record.finalText ?? ""
            if !finalText.isEmpty {
                increment(.totalCharacters, by: finalText.count)
                increment(.totalWords, by: wordCount(finalText))
            }

            switch record.mode {
            case .dictation:
                increment(.dictationCount, by: 1)
            case .personaRewrite:
                increment(.personaRewriteCount, by: 1)
            case .editSelection:
                increment(.editSelectionCount, by: 1)
            case .askAnswer:
                increment(.askAnswerCount, by: 1)
            }
        }
    }

    // MARK: - Backfill

    func backfillIfNeeded(from historyStore: HistoryStore) {
        guard !defaults.bool(forKey: Key.didBackfill.rawValue) else { return }

        queue.async { [self] in
            let records = historyStore.list()
            guard !records.isEmpty else {
                defaults.set(true, forKey: Key.didBackfill.rawValue)
                return
            }

            // Only backfill if we have no data yet
            guard totalSessions == 0 else {
                defaults.set(true, forKey: Key.didBackfill.rawValue)
                return
            }

            var sessions = 0
            var successful = 0
            var failed = 0
            var recordingSecs = 0.0
            var chars = 0
            var words = 0
            var dictation = 0
            var persona = 0
            var editSel = 0
            var askAnswer = 0

            for record in records {
                sessions += 1

                let isSuccess = record.applyStatus == .succeeded || (record.applyStatus == .skipped && record.transcriptionStatus == .succeeded)
                if isSuccess { successful += 1 }
                if record.hasFailure { failed += 1 }

                if let duration = record.recordingDurationSeconds, duration > 0 {
                    recordingSecs += duration
                }

                let text = record.finalText ?? ""
                if !text.isEmpty {
                    chars += text.count
                    words += wordCount(text)
                }

                switch record.mode {
                case .dictation: dictation += 1
                case .personaRewrite: persona += 1
                case .editSelection: editSel += 1
                case .askAnswer: askAnswer += 1
                }
            }

            defaults.set(sessions, forKey: Key.totalSessions.rawValue)
            defaults.set(successful, forKey: Key.successfulSessions.rawValue)
            defaults.set(failed, forKey: Key.failedSessions.rawValue)
            defaults.set(recordingSecs, forKey: Key.totalRecordingSeconds.rawValue)
            defaults.set(chars, forKey: Key.totalCharacters.rawValue)
            defaults.set(words, forKey: Key.totalWords.rawValue)
            defaults.set(dictation, forKey: Key.dictationCount.rawValue)
            defaults.set(persona, forKey: Key.personaRewriteCount.rawValue)
            defaults.set(editSel, forKey: Key.editSelectionCount.rawValue)
            defaults.set(askAnswer, forKey: Key.askAnswerCount.rawValue)
            defaults.set(true, forKey: Key.didBackfill.rawValue)
        }
    }

    // MARK: - Private

    private func increment(_ key: Key, by amount: Int) {
        let current = defaults.integer(forKey: key.rawValue)
        defaults.set(current + amount, forKey: key.rawValue)
    }

    private func incrementDouble(_ key: Key, by amount: Double) {
        let current = defaults.double(forKey: key.rawValue)
        defaults.set(current + amount, forKey: key.rawValue)
    }

    private func wordCount(_ text: String) -> Int {
        var count = 0
        text.enumerateSubstrings(in: text.startIndex..., options: [.byWords, .localized]) { _, _, _, _ in
            count += 1
        }
        return count
    }
}
