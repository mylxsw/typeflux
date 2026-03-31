import Foundation

struct AutomaticVocabularyChange: Equatable {
    let oldFragment: String
    let newFragment: String
    let candidateTerms: [String]
}

struct AutomaticVocabularyObservationState: Equatable {
    let sessionStartedAt: Date
    var settledText: String
    var latestObservedText: String
    var lastChangedAt: Date?
    var lastAnalyzedText: String?
    var analysisCount: Int
}

struct AutomaticVocabularyPendingAnalysis: Equatable {
    let previousStableText: String
    let updatedText: String
}

enum AutomaticVocabularyMonitor {
    private static let latinOrNumberRegex = try! NSRegularExpression(
        pattern: #"[A-Za-z0-9]+(?:[._+\-'][A-Za-z0-9]+)*"#
    )
    private static let hanRegex = try! NSRegularExpression(pattern: #"\p{Han}{2,12}"#)

    static func detectChange(from oldText: String, to newText: String) -> AutomaticVocabularyChange? {
        guard oldText != newText else { return nil }

        let oldCharacters = Array(oldText)
        let newCharacters = Array(newText)
        let sharedPrefixCount = commonPrefixCount(oldCharacters, newCharacters)
        let sharedSuffixCount = commonSuffixCount(
            oldCharacters,
            newCharacters,
            excludingSharedPrefix: sharedPrefixCount
        )

        let oldEnd = max(sharedPrefixCount, oldCharacters.count - sharedSuffixCount)
        let newEnd = max(sharedPrefixCount, newCharacters.count - sharedSuffixCount)
        let oldFragment = String(oldCharacters[sharedPrefixCount..<oldEnd]).trimmingCharacters(in: .whitespacesAndNewlines)
        let newFragment = String(newCharacters[sharedPrefixCount..<newEnd]).trimmingCharacters(in: .whitespacesAndNewlines)

        guard !newFragment.isEmpty else { return nil }

        let previousTerms = Set(tokenize(oldFragment).map(normalize))
        let candidateTerms = tokenize(newFragment)
            .filter { !previousTerms.contains(normalize($0)) }
            .uniquedPreservingOrder(by: normalize)
            .prefix(8)

        guard !candidateTerms.isEmpty else { return nil }
        return AutomaticVocabularyChange(
            oldFragment: oldFragment,
            newFragment: newFragment,
            candidateTerms: Array(candidateTerms)
        )
    }

    static func parseAcceptedTerms(from response: String) -> [String] {
        guard !response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }

        if let data = response.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let terms = object["terms"] as? [String] {
            return terms.uniquedPreservingOrder(by: normalize)
        }

        if let data = response.data(using: .utf8),
           let terms = try? JSONSerialization.jsonObject(with: data) as? [String] {
            return terms.uniquedPreservingOrder(by: normalize)
        }

        let lines = response
            .split(whereSeparator: \.isNewline)
            .map {
                $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"',- ").union(.whitespacesAndNewlines))
            }
            .filter { !$0.isEmpty }

        return lines.uniquedPreservingOrder(by: normalize)
    }

    static func makeObservationState(
        baselineText: String,
        startedAt: Date = Date()
    ) -> AutomaticVocabularyObservationState {
        AutomaticVocabularyObservationState(
            sessionStartedAt: startedAt,
            settledText: baselineText,
            latestObservedText: baselineText,
            lastChangedAt: nil,
            lastAnalyzedText: nil,
            analysisCount: 0
        )
    }

    static func observe(
        text: String,
        at observedAt: Date,
        state: inout AutomaticVocabularyObservationState
    ) -> Bool {
        guard text != state.latestObservedText else { return false }
        state.latestObservedText = text
        state.lastChangedAt = observedAt
        return true
    }

    static func pendingAnalysis(
        state: AutomaticVocabularyObservationState,
        now: Date,
        settleDelay: TimeInterval,
        maxAnalyses: Int
    ) -> AutomaticVocabularyPendingAnalysis? {
        guard state.analysisCount < maxAnalyses else { return nil }
        guard let lastChangedAt = state.lastChangedAt else { return nil }
        guard now.timeIntervalSince(lastChangedAt) >= settleDelay else { return nil }
        guard state.latestObservedText != state.settledText else { return nil }
        guard state.latestObservedText != state.lastAnalyzedText else { return nil }

        return AutomaticVocabularyPendingAnalysis(
            previousStableText: state.settledText,
            updatedText: state.latestObservedText
        )
    }

    static func markAnalysisCompleted(
        for stableText: String,
        state: inout AutomaticVocabularyObservationState
    ) {
        state.settledText = stableText
        state.latestObservedText = stableText
        state.lastChangedAt = nil
        state.lastAnalyzedText = stableText
        state.analysisCount += 1
    }

    private static func tokenize(_ text: String) -> [String] {
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        let latinMatches: [String] = latinOrNumberRegex.matches(in: text, range: nsRange).compactMap { match -> String? in
            guard let range = Range(match.range, in: text) else { return nil }
            let token = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            return isValidLatinOrNumberToken(token) ? token : nil
        }
        let hanMatches: [String] = hanRegex.matches(in: text, range: nsRange).compactMap { match -> String? in
            guard let range = Range(match.range, in: text) else { return nil }
            let token = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            return isValidHanToken(token) ? token : nil
        }

        let combinedMatches: [String] = latinMatches + hanMatches
        return combinedMatches.uniquedPreservingOrder(by: normalize)
    }

    private static func isValidLatinOrNumberToken(_ token: String) -> Bool {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2, trimmed.count <= 32 else { return false }
        return trimmed.rangeOfCharacter(from: .letters) != nil || trimmed.rangeOfCharacter(from: .decimalDigits) != nil
    }

    private static func isValidHanToken(_ token: String) -> Bool {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count >= 2 && trimmed.count <= 12
    }

    private static func normalize(_ term: String) -> String {
        term.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func commonPrefixCount(_ lhs: [Character], _ rhs: [Character]) -> Int {
        let limit = min(lhs.count, rhs.count)
        var count = 0
        while count < limit, lhs[count] == rhs[count] {
            count += 1
        }
        return count
    }

    private static func commonSuffixCount(
        _ lhs: [Character],
        _ rhs: [Character],
        excludingSharedPrefix sharedPrefixCount: Int
    ) -> Int {
        let lhsRemaining = lhs.count - sharedPrefixCount
        let rhsRemaining = rhs.count - sharedPrefixCount
        let limit = min(lhsRemaining, rhsRemaining)
        guard limit > 0 else { return 0 }

        var count = 0
        while count < limit,
              lhs[lhs.count - 1 - count] == rhs[rhs.count - 1 - count] {
            count += 1
        }
        return count
    }
}

private extension Array where Element == String {
    func uniquedPreservingOrder(by transform: (String) -> String) -> [String] {
        var seen = Set<String>()
        return filter { value in
            let key = transform(value)
            guard !key.isEmpty, seen.insert(key).inserted else { return false }
            return true
        }
    }
}
