import Foundation

final class UsageStatsStore {
    static let shared = UsageStatsStore()
    static let calculationVersion = 2
    static let maxExactEditDiffCells = 1_000_000

    struct SessionContribution {
        var sessions: Int = 0
        var successfulSessions: Int = 0
        var failedSessions: Int = 0
        var perceivedSeconds: Double = 0
        var estimatedTypingSeconds: Double = 0
        var outputCharacters: Int = 0
        var outputWords: Int = 0
        var dictationCount: Int = 0
        var personaRewriteCount: Int = 0
        var editSelectionCount: Int = 0
        var askAnswerCount: Int = 0

        mutating func add(_ other: SessionContribution) {
            sessions += other.sessions
            successfulSessions += other.successfulSessions
            failedSessions += other.failedSessions
            perceivedSeconds += other.perceivedSeconds
            estimatedTypingSeconds += other.estimatedTypingSeconds
            outputCharacters += other.outputCharacters
            outputWords += other.outputWords
            dictationCount += other.dictationCount
            personaRewriteCount += other.personaRewriteCount
            editSelectionCount += other.editSelectionCount
            askAnswerCount += other.askAnswerCount
        }
    }

    let defaults: UserDefaults
    private let queue = DispatchQueue(label: "usage.stats")

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private enum Key: String {
        case totalSessions = "stats.totalSessions"
        case successfulSessions = "stats.successfulSessions"
        case failedSessions = "stats.failedSessions"
        case totalRecordingSeconds = "stats.totalRecordingSeconds"
        case estimatedTypingSeconds = "stats.estimatedTypingSeconds"
        case totalCharacters = "stats.totalCharacters"
        case totalWords = "stats.totalWords"
        case dictationCount = "stats.dictationCount"
        case personaRewriteCount = "stats.personaRewriteCount"
        case editSelectionCount = "stats.editSelectionCount"
        case askAnswerCount = "stats.askAnswerCount"
        case didBackfill = "stats.didBackfill"
        case calculationVersion = "stats.calculationVersion"
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

    var estimatedTypingSeconds: Double {
        defaults.double(forKey: Key.estimatedTypingSeconds.rawValue)
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
    /// Uses the final user-visible output as the baseline, then subtracts the total user-perceived
    /// completion time (speaking + post-record waiting) of successful voice sessions.
    var savedMinutes: Int {
        guard estimatedTypingSeconds > 0, totalRecordingSeconds > 0 else { return 0 }
        let typingMinutes = estimatedTypingSeconds / 60.0
        let dictationMinutes = totalRecordingSeconds / 60.0
        return max(0, Int(round(typingMinutes - dictationMinutes)))
    }

    /// Effective output throughput perceived by the user, based on final visible text and total
    /// successful voice completion time.
    var averagePaceWPM: Int {
        let minutes = totalRecordingSeconds / 60.0
        guard minutes >= 0.5 else { return 0 }
        return Int(round(Double(totalWordCount) / minutes))
    }

    // MARK: - Recording

    func recordSession(record: HistoryRecord) {
        queue.async { [self] in
            apply(contribution: contribution(for: record))
        }
    }

    // MARK: - Backfill

    func backfillIfNeeded(from historyStore: HistoryStore) {
        let didBackfill = defaults.bool(forKey: Key.didBackfill.rawValue)
        let storedVersion = defaults.integer(forKey: Key.calculationVersion.rawValue)
        guard !didBackfill || storedVersion < Self.calculationVersion else { return }

        queue.async { [self] in
            let records = historyStore.list()
            var aggregate = SessionContribution()

            for record in records {
                aggregate.add(contribution(for: record))
            }

            defaults.set(aggregate.sessions, forKey: Key.totalSessions.rawValue)
            defaults.set(aggregate.successfulSessions, forKey: Key.successfulSessions.rawValue)
            defaults.set(aggregate.failedSessions, forKey: Key.failedSessions.rawValue)
            defaults.set(aggregate.perceivedSeconds, forKey: Key.totalRecordingSeconds.rawValue)
            defaults.set(aggregate.estimatedTypingSeconds, forKey: Key.estimatedTypingSeconds.rawValue)
            defaults.set(aggregate.outputCharacters, forKey: Key.totalCharacters.rawValue)
            defaults.set(aggregate.outputWords, forKey: Key.totalWords.rawValue)
            defaults.set(aggregate.dictationCount, forKey: Key.dictationCount.rawValue)
            defaults.set(aggregate.personaRewriteCount, forKey: Key.personaRewriteCount.rawValue)
            defaults.set(aggregate.editSelectionCount, forKey: Key.editSelectionCount.rawValue)
            defaults.set(aggregate.askAnswerCount, forKey: Key.askAnswerCount.rawValue)
            defaults.set(true, forKey: Key.didBackfill.rawValue)
            defaults.set(Self.calculationVersion, forKey: Key.calculationVersion.rawValue)
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

    private func apply(contribution: SessionContribution) {
        increment(.totalSessions, by: contribution.sessions)
        increment(.successfulSessions, by: contribution.successfulSessions)
        increment(.failedSessions, by: contribution.failedSessions)
        incrementDouble(.totalRecordingSeconds, by: contribution.perceivedSeconds)
        incrementDouble(.estimatedTypingSeconds, by: contribution.estimatedTypingSeconds)
        increment(.totalCharacters, by: contribution.outputCharacters)
        increment(.totalWords, by: contribution.outputWords)
        increment(.dictationCount, by: contribution.dictationCount)
        increment(.personaRewriteCount, by: contribution.personaRewriteCount)
        increment(.editSelectionCount, by: contribution.editSelectionCount)
        increment(.askAnswerCount, by: contribution.askAnswerCount)
        defaults.set(Self.calculationVersion, forKey: Key.calculationVersion.rawValue)
    }

    func contribution(for record: HistoryRecord) -> SessionContribution {
        var contribution = SessionContribution(sessions: 1)

        if isSuccessful(record) {
            contribution.successfulSessions = 1
        }
        if record.hasFailure {
            contribution.failedSessions = 1
        }

        switch record.mode {
        case .dictation:
            contribution.dictationCount = 1
        case .personaRewrite:
            contribution.personaRewriteCount = 1
        case .editSelection:
            contribution.editSelectionCount = 1
        case .askAnswer:
            contribution.askAnswerCount = 1
        }

        guard isSuccessful(record), let spokenDuration = record.recordingDurationSeconds, spokenDuration > 0 else {
            return contribution
        }

        let outputText = normalizedMeasuredOutputText(for: record)
        guard !outputText.isEmpty else { return contribution }

        contribution.outputCharacters = outputText.count
        contribution.outputWords = wordCount(outputText)
        contribution.perceivedSeconds = spokenDuration + postRecordingWaitSeconds(for: record)
        contribution.estimatedTypingSeconds = estimatedTypingSeconds(for: outputText)
        return contribution
    }

    func isSuccessful(_ record: HistoryRecord) -> Bool {
        record.applyStatus == .succeeded ||
            (record.applyStatus == .skipped && record.transcriptionStatus == .succeeded)
    }

    private func postRecordingWaitSeconds(for record: HistoryRecord) -> Double {
        guard let milliseconds = (record.pipelineStats ?? record.pipelineTiming?.generatedStats())?.endToEndMilliseconds,
              milliseconds > 0
        else {
            return 0
        }
        return Double(milliseconds) / 1000.0
    }

    private func normalizedMeasuredOutputText(for record: HistoryRecord) -> String {
        let finalText = (record.finalText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !finalText.isEmpty else { return "" }

        switch record.mode {
        case .dictation, .personaRewrite:
            return finalText
        case .editSelection:
            return editedTextContribution(
                originalText: record.selectionOriginalText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                editedText: finalText
            )
        case .askAnswer:
            return ""
        }
    }

    func editedTextContribution(originalText: String, editedText: String) -> String {
        guard !editedText.isEmpty else { return "" }
        guard !originalText.isEmpty else { return editedText }
        guard originalText != editedText else { return "" }

        let original = Array(originalText)
        let edited = Array(editedText)
        let diffCells = original.count * edited.count
        guard diffCells <= Self.maxExactEditDiffCells else {
            return heuristicEditedTextContribution(original: original, edited: edited)
        }

        var lengths = Array(
            repeating: Array(repeating: 0, count: edited.count + 1),
            count: original.count + 1
        )

        if !original.isEmpty && !edited.isEmpty {
            for i in 1...original.count {
                for j in 1...edited.count {
                    if original[i - 1] == edited[j - 1] {
                        lengths[i][j] = lengths[i - 1][j - 1] + 1
                    } else {
                        lengths[i][j] = max(lengths[i - 1][j], lengths[i][j - 1])
                    }
                }
            }
        }

        var changedCharacters: [Character] = []
        var i = original.count
        var j = edited.count

        while i > 0, j > 0 {
            if original[i - 1] == edited[j - 1] {
                i -= 1
                j -= 1
            } else if lengths[i][j - 1] >= lengths[i - 1][j] {
                changedCharacters.append(edited[j - 1])
                j -= 1
            } else {
                i -= 1
            }
        }

        while j > 0 {
            changedCharacters.append(edited[j - 1])
            j -= 1
        }

        return String(changedCharacters.reversed()).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func heuristicEditedTextContribution(original: [Character], edited: [Character]) -> String {
        var prefixCount = 0
        let prefixLimit = min(original.count, edited.count)
        while prefixCount < prefixLimit, original[prefixCount] == edited[prefixCount] {
            prefixCount += 1
        }

        var suffixCount = 0
        while suffixCount < original.count - prefixCount,
              suffixCount < edited.count - prefixCount,
              original[original.count - 1 - suffixCount] == edited[edited.count - 1 - suffixCount]
        {
            suffixCount += 1
        }

        let deltaStart = prefixCount
        let deltaEnd = edited.count - suffixCount
        guard deltaStart < deltaEnd else { return "" }
        return String(edited[deltaStart..<deltaEnd]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func estimatedTypingSeconds(for text: String) -> Double {
        var cjkCharacters = 0
        var nonCJKCharacters = 0

        for scalar in text.unicodeScalars where !CharacterSet.whitespacesAndNewlines.contains(scalar) {
            if scalar.isCJKIdeograph || scalar.isKana || scalar.isHangul {
                cjkCharacters += 1
            } else {
                nonCJKCharacters += 1
            }
        }

        let cjkSeconds = Double(cjkCharacters) * 60.0 / 45.0
        let latinSeconds = Double(nonCJKCharacters) * 60.0 / 240.0
        return cjkSeconds + latinSeconds
    }

    func wordCount(_ text: String) -> Int {
        var count = 0
        text.enumerateSubstrings(in: text.startIndex..., options: [.byWords, .localized]) { _, _, _, _ in
            count += 1
        }
        return count
    }
}

extension Unicode.Scalar {
    var isCJKIdeograph: Bool {
        (0x3400...0x4DBF).contains(value) ||
            (0x4E00...0x9FFF).contains(value) ||
            (0xF900...0xFAFF).contains(value) ||
            (0x20000...0x2A6DF).contains(value) ||
            (0x2A700...0x2B73F).contains(value) ||
            (0x2B740...0x2B81F).contains(value) ||
            (0x2B820...0x2CEAF).contains(value) ||
            (0x2CEB0...0x2EBEF).contains(value) ||
            (0x30000...0x3134F).contains(value)
    }

    var isKana: Bool {
        (0x3040...0x309F).contains(value) || (0x30A0...0x30FF).contains(value)
    }

    var isHangul: Bool {
        (0xAC00...0xD7AF).contains(value) || (0x1100...0x11FF).contains(value)
    }
}
