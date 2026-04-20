import Foundation

struct AutomaticVocabularyChange: Equatable {
    let oldFragment: String
    let newFragment: String
    let candidateTerms: [String]
}

struct AutomaticVocabularyObservationState: Equatable {
    let sessionStartedAt: Date
    let baselineText: String
    var latestObservedText: String
    var lastChangedAt: Date?
}

enum AutomaticVocabularySessionExit: Equatable {
    case settled
    case deadlineReached
}

enum AutomaticVocabularyMonitor {
    private static let latinOrNumberRegex = try! NSRegularExpression(
        pattern: #"[A-Za-z0-9]+(?:[._+\-'][A-Za-z0-9]+)*"#,
    )
    private static let hanRegex = try! NSRegularExpression(pattern: #"\p{Han}{2,12}"#)
    private static let acceptedTermRegex = try! NSRegularExpression(
        pattern: #"^[\p{Han}A-Za-z0-9](?:[\p{Han}A-Za-z0-9 ._+\-/']{0,38}[\p{Han}A-Za-z0-9])?$"#,
    )
    private static let rejectedAcceptedTerms: Set<String> = ["```"]

    static let decisionSchema = LLMJSONSchema(
        name: "automatic_vocabulary_terms",
        schema: [
            "type": .string("object"),
            "additionalProperties": .bool(false),
            "required": .array([.string("terms")]),
            "properties": .object([
                "terms": .object([
                    "type": .string("array"),
                    "items": .object([
                        "type": .string("string"),
                        "minLength": .int(2),
                        "maxLength": .int(40),
                    ]),
                    "maxItems": .int(8),
                ]),
            ]),
        ],
    )

    static func detectChange(from oldText: String, to newText: String) -> AutomaticVocabularyChange? {
        guard oldText != newText else { return nil }

        let oldCharacters = Array(oldText)
        let newCharacters = Array(newText)
        let sharedPrefixCount = commonPrefixCount(oldCharacters, newCharacters)
        let sharedSuffixCount = commonSuffixCount(
            oldCharacters,
            newCharacters,
            excludingSharedPrefix: sharedPrefixCount,
        )

        let oldEnd = max(sharedPrefixCount, oldCharacters.count - sharedSuffixCount)
        let newEnd = max(sharedPrefixCount, newCharacters.count - sharedSuffixCount)
        let oldRange = expandChangedRange(
            in: oldCharacters,
            start: sharedPrefixCount,
            end: oldEnd,
        )
        let newRange = expandChangedRange(
            in: newCharacters,
            start: sharedPrefixCount,
            end: newEnd,
        )
        let oldFragment = String(oldCharacters[oldRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        let newFragment = String(newCharacters[newRange]).trimmingCharacters(in: .whitespacesAndNewlines)

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
            candidateTerms: Array(candidateTerms),
        )
    }

    static func parseAcceptedTerms(from response: String) -> [String] {
        guard !response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }

        if let jsonPayload = extractJSONObjectOrArray(from: response),
           let data = jsonPayload.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let terms = object["terms"] as? [String]
        {
            return sanitizeAcceptedTerms(terms)
        }

        if let jsonPayload = extractJSONObjectOrArray(from: response),
           let data = jsonPayload.data(using: .utf8),
           let terms = try? JSONSerialization.jsonObject(with: data) as? [String]
        {
            return sanitizeAcceptedTerms(terms)
        }

        return []
    }

    static func makeObservationState(
        baselineText: String,
        startedAt: Date = Date(),
    ) -> AutomaticVocabularyObservationState {
        AutomaticVocabularyObservationState(
            sessionStartedAt: startedAt,
            baselineText: baselineText,
            latestObservedText: baselineText,
            lastChangedAt: nil,
        )
    }

    static func observe(
        text: String,
        at observedAt: Date,
        state: inout AutomaticVocabularyObservationState,
    ) -> Bool {
        guard text != state.latestObservedText else { return false }
        state.latestObservedText = text
        state.lastChangedAt = observedAt
        return true
    }

    static func shouldTriggerAnalysis(
        state: AutomaticVocabularyObservationState,
        now: Date,
        idleSettleDelay: TimeInterval,
    ) -> Bool {
        guard let lastChangedAt = state.lastChangedAt else { return false }
        guard state.latestObservedText != state.baselineText else { return false }
        return now.timeIntervalSince(lastChangedAt) >= idleSettleDelay
    }

    /// Levenshtein-based ratio that measures how much the observed text has
    /// diverged from the baseline relative to the length of the originally inserted
    /// text. A value of 0 means the baseline and final text are identical; a value
    /// of 1 means the total edit distance is as large as the whole insertion.
    ///
    /// Returns the sentinel value `1` (enough to trip any sane cutoff) when either
    /// side exceeds `maxLengthForExactComputation` — this is the O(n²) safety
    /// bailout from the spec: we refuse to diff very long texts and abandon the
    /// session, since users editing multi-thousand-character prose are almost
    /// certainly not doing targeted vocabulary corrections.
    static func editRatio(
        inserted: String,
        baseline: String,
        final: String,
        maxLengthForExactComputation: Int = 2000,
    ) -> Double {
        let insertedNorm = normalize(inserted)
        guard !insertedNorm.isEmpty else { return 0 }
        let baselineNorm = normalize(baseline)
        let finalNorm = normalize(final)
        if baselineNorm == finalNorm { return 0 }
        if max(baselineNorm.count, finalNorm.count) > maxLengthForExactComputation {
            return 1
        }
        let distance = levenshteinDistance(Array(baselineNorm), Array(finalNorm))
        return Double(distance) / Double(insertedNorm.count)
    }

    /// True when the cumulative edit between baseline and final observed text
    /// exceeds the configured fraction of the inserted text. A ratio above the
    /// limit means the user rewrote a volume of content comparable to (or larger
    /// than) the dictation itself, in which case vocabulary analysis is noise.
    static func isEditTooLarge(
        inserted: String,
        baseline: String,
        final: String,
        ratioLimit: Double,
        maxLengthForExactComputation: Int = 2000,
    ) -> Bool {
        editRatio(
            inserted: inserted,
            baseline: baseline,
            final: final,
            maxLengthForExactComputation: maxLengthForExactComputation,
        ) > ratioLimit
    }

    /// True when the detected change is effectively just the originally inserted
    /// text (e.g. baseline was captured before AX reflected the insertion). These
    /// must be filtered out so we do not waste an LLM call on our own dictation
    /// output. Uses two conservative signals:
    ///   1. Normalized equality between the new fragment and the inserted text.
    ///   2. Every candidate term is drawn from the inserted text's tokens.
    /// A substring/contains check is deliberately NOT used — legitimate follow-up
    /// edits like appending "SeedASR" to an inserted "Doubao" produce a new
    /// fragment that contains the insertion but introduces brand-new tokens.
    static func changeIsJustInitialInsertion(
        change: AutomaticVocabularyChange,
        insertedText: String,
    ) -> Bool {
        let normalizedInserted = normalize(insertedText)
        guard !normalizedInserted.isEmpty else { return false }
        let normalizedNew = normalize(change.newFragment)
        if normalizedNew == normalizedInserted { return true }
        let insertedTokens = Set(tokenize(insertedText).map(normalize))
        guard !insertedTokens.isEmpty else { return false }
        return change.candidateTerms.allSatisfy { insertedTokens.contains(normalize($0)) }
    }

    private static func tokenize(_ text: String) -> [String] {
        let nsRange = NSRange(text.startIndex ..< text.endIndex, in: text)
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
        // Dropped from 4 to 3: common tech acronyms (GPT, API, LLM, ASR, gRPC) get
        // manually corrected all the time. LLM-side validation keeps the noise out.
        guard trimmed.count >= 3, trimmed.count <= 32 else { return false }
        return trimmed.rangeOfCharacter(from: .letters) != nil
    }

    private static func isValidHanToken(_ token: String) -> Bool {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count >= 2 && trimmed.count <= 12
    }

    private static func levenshteinDistance(_ lhs: [Character], _ rhs: [Character]) -> Int {
        if lhs.isEmpty { return rhs.count }
        if rhs.isEmpty { return lhs.count }

        var previous = Array(0 ... rhs.count)
        var current = Array(repeating: 0, count: rhs.count + 1)

        for i in 1 ... lhs.count {
            current[0] = i
            for j in 1 ... rhs.count {
                let cost = lhs[i - 1] == rhs[j - 1] ? 0 : 1
                current[j] = Swift.min(
                    previous[j] + 1,
                    current[j - 1] + 1,
                    previous[j - 1] + cost,
                )
            }
            swap(&previous, &current)
        }

        return previous[rhs.count]
    }

    private static func normalize(_ term: String) -> String {
        term.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func sanitizeAcceptedTerms(_ terms: [String]) -> [String] {
        terms
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter(isValidAcceptedTerm)
            .uniquedPreservingOrder(by: normalize)
    }

    private static func isValidAcceptedTerm(_ term: String) -> Bool {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= 40 else { return false }
        guard !trimmed.contains(where: \.isNewline) else { return false }

        let normalized = trimmed.lowercased()
        guard !rejectedAcceptedTerms.contains(normalized) else {
            return false
        }

        let nsRange = NSRange(trimmed.startIndex ..< trimmed.endIndex, in: trimmed)
        guard acceptedTermRegex.firstMatch(in: trimmed, range: nsRange) != nil else {
            return false
        }

        let hasHan = trimmed.unicodeScalars.contains { (0x4E00 ... 0x9FFF).contains($0.value) }
        if hasHan {
            return trimmed.count >= 2
        }

        guard trimmed.rangeOfCharacter(from: .letters) != nil else { return false }
        // Aligns with the candidate tokenizer: allow 3-char acronyms like "API",
        // "GPT" that users frequently correct by hand.
        return trimmed.count >= 3
    }

    private static func extractJSONObjectOrArray(from response: String) -> String? {
        let stripped = stripMarkdownCodeFence(from: response).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stripped.isEmpty else { return nil }

        if stripped.first == "{" || stripped.first == "[" {
            return balancedJSONSubstring(in: stripped)
        }

        guard let start = stripped.firstIndex(where: { $0 == "{" || $0 == "[" }) else {
            return nil
        }

        return balancedJSONSubstring(in: String(stripped[start...]))
    }

    private static func stripMarkdownCodeFence(from response: String) -> String {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("```"), let closingRange = trimmed.range(of: "```", options: .backwards), closingRange.lowerBound > trimmed.startIndex else {
            return trimmed
        }

        let innerStart = trimmed.index(after: trimmed.index(after: trimmed.startIndex))
        let contentStart = trimmed[innerStart...].firstIndex(of: "\n") ?? innerStart
        let bodyStart = contentStart < trimmed.endIndex ? trimmed.index(after: contentStart) : contentStart
        return String(trimmed[bodyStart ..< closingRange.lowerBound])
    }

    private static func balancedJSONSubstring(in text: String) -> String? {
        guard let first = text.first, first == "{" || first == "[" else { return nil }
        let opening = first
        let closing: Character = first == "{" ? "}" : "]"
        var depth = 0
        var isInsideString = false
        var isEscaped = false

        for (index, character) in text.enumerated() {
            if isEscaped {
                isEscaped = false
                continue
            }

            if character == "\\" {
                isEscaped = true
                continue
            }

            if character == "\"" {
                isInsideString.toggle()
                continue
            }

            guard !isInsideString else { continue }

            if character == opening {
                depth += 1
            } else if character == closing {
                depth -= 1
                if depth == 0 {
                    let endIndex = text.index(text.startIndex, offsetBy: index)
                    return String(text[text.startIndex ... endIndex])
                }
            }
        }

        return nil
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
        excludingSharedPrefix sharedPrefixCount: Int,
    ) -> Int {
        let lhsRemaining = lhs.count - sharedPrefixCount
        let rhsRemaining = rhs.count - sharedPrefixCount
        let limit = min(lhsRemaining, rhsRemaining)
        guard limit > 0 else { return 0 }

        var count = 0
        while count < limit,
              lhs[lhs.count - 1 - count] == rhs[rhs.count - 1 - count]
        {
            count += 1
        }
        return count
    }

    private static func expandChangedRange(
        in characters: [Character],
        start: Int,
        end: Int,
    ) -> Range<Int> {
        guard !characters.isEmpty else { return start ..< end }

        var lowerBound = max(0, min(start, characters.count))
        var upperBound = max(lowerBound, min(end, characters.count))

        let anchorIndex: Int?
        if lowerBound < upperBound {
            anchorIndex = lowerBound
        } else if lowerBound < characters.count, tokenKind(for: characters[lowerBound]) != .none {
            anchorIndex = lowerBound
            upperBound = lowerBound + 1
        } else if lowerBound > 0, tokenKind(for: characters[lowerBound - 1]) != .none {
            anchorIndex = lowerBound - 1
            lowerBound = lowerBound - 1
            upperBound = max(upperBound, lowerBound + 1)
        } else {
            anchorIndex = nil
        }

        guard let anchorIndex else { return lowerBound ..< upperBound }
        let kind = tokenKind(for: characters[anchorIndex])
        guard kind != .none else { return lowerBound ..< upperBound }

        while lowerBound > 0, tokenKind(for: characters[lowerBound - 1]) == kind {
            lowerBound -= 1
        }

        while upperBound < characters.count, tokenKind(for: characters[upperBound]) == kind {
            upperBound += 1
        }

        return lowerBound ..< upperBound
    }

    private static func tokenKind(for character: Character) -> TokenKind {
        if isLatinOrNumberTokenCharacter(character) {
            return .latinOrNumber
        }
        if isHanCharacter(character) {
            return .han
        }
        return .none
    }

    private static func isLatinOrNumberTokenCharacter(_ character: Character) -> Bool {
        guard character.unicodeScalars.count == 1, let scalar = character.unicodeScalars.first else {
            return false
        }

        if CharacterSet.alphanumerics.contains(scalar) {
            return true
        }

        return "._+-'".unicodeScalars.contains(scalar)
    }

    private static func isHanCharacter(_ character: Character) -> Bool {
        character.unicodeScalars.contains { (0x4E00 ... 0x9FFF).contains($0.value) }
    }
}

private enum TokenKind: Equatable {
    case none
    case latinOrNumber
    case han
}

private extension [String] {
    func uniquedPreservingOrder(by transform: (String) -> String) -> [String] {
        var seen = Set<String>()
        return filter { value in
            let key = transform(value)
            guard !key.isEmpty, seen.insert(key).inserted else { return false }
            return true
        }
    }
}
