import Foundation

enum DictationOutputOptimizer {
    private static let maximumCJKShortTextLength = 15
    private static let maximumNonCJKShortTextLength = 30
    private static let maximumNonCJKShortTextWordCount = 5
    private static let removablePeriods: Set<Character> = [".", "。"]
    private static let sentenceBoundaryCharacters: Set<Character> = [".", "!", "?", "。", "！", "？", "…"]

    static func optimize(_ text: String) -> String {
        guard let contentRange = nonWhitespaceContentRange(in: text) else { return text }

        let content = String(text[contentRange])
        guard shouldRemoveTrailingPeriod(from: content) else { return text }

        return replacingContent(in: text, range: contentRange, with: String(content.dropLast()))
    }

    static func deduplicatingTrailingPunctuation(
        in text: String,
        against inputSnapshot: CurrentInputTextSnapshot
    ) -> String {
        guard inputSnapshot.isEditable, inputSnapshot.isFocusedTarget else { return text }
        guard let targetText = inputSnapshot.text,
              let selectedRange = inputSnapshot.selectedRange,
              selectedRange.location >= 0,
              selectedRange.length == 0,
              selectedRange.location <= targetText.utf16.count,
              let contentRange = nonWhitespaceContentRange(in: text)
        else {
            return text
        }

        let content = text[contentRange]
        guard !content.contains(where: \.isNewline),
              let trailingPunctuation = content.last,
              let category = punctuationCategory(for: trailingPunctuation)
        else {
            return text
        }
        let body = content.dropLast()
        guard body.last.map({ punctuationCategory(for: $0) == nil }) ?? false else { return text }

        let insertionUTF16Index = targetText.utf16.index(
            targetText.utf16.startIndex,
            offsetBy: selectedRange.location
        )
        guard let insertionIndex = insertionUTF16Index.samePosition(in: targetText) else { return text }
        let suffix = targetText[insertionIndex...]
        guard let existingPunctuation = firstBoundaryCharacter(in: suffix),
              punctuationCategory(for: existingPunctuation) == category
        else {
            return text
        }

        return replacingContent(in: text, range: contentRange, with: String(body))
    }

    private static func firstBoundaryCharacter(in text: Substring) -> Character? {
        for character in text {
            if character.isNewline { return nil }
            if !character.isWhitespace { return character }
        }
        return nil
    }

    private static func shouldRemoveTrailingPeriod(from text: String) -> Bool {
        guard !text.contains(where: \.isNewline) else { return false }
        guard let trailingPeriod = text.last, removablePeriods.contains(trailingPeriod) else { return false }

        let body = text.dropLast()
        guard let lastBodyCharacter = body.last,
              !lastBodyCharacter.isWhitespace,
              !lastBodyCharacter.isNewline,
              !sentenceBoundaryCharacters.contains(lastBodyCharacter),
              !body.contains(where: { sentenceBoundaryCharacters.contains($0) })
        else {
            return false
        }

        return isShortConversationalText(String(body))
    }

    private static func isShortConversationalText(_ text: String) -> Bool {
        guard !text.isEmpty, text.count <= maximumNonCJKShortTextLength else { return false }
        if containsCJKCharacter(text) {
            return text.count <= maximumCJKShortTextLength
        }

        let wordCount = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
        return wordCount > 0 && wordCount <= maximumNonCJKShortTextWordCount
    }

    private static func containsCJKCharacter(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3400 ... 0x4DBF,
                 0x4E00 ... 0x9FFF,
                 0x20000 ... 0x2FA1F,
                 0x3040 ... 0x30FF,
                 0x31F0 ... 0x31FF,
                 0x1100 ... 0x11FF,
                 0x3130 ... 0x318F,
                 0xAC00 ... 0xD7AF:
                true
            default:
                false
            }
        }
    }

    private static func nonWhitespaceContentRange(in text: String) -> ClosedRange<String.Index>? {
        guard let startIndex = text.firstIndex(where: { !$0.isWhitespace && !$0.isNewline }),
              let endIndex = text.lastIndex(where: { !$0.isWhitespace && !$0.isNewline })
        else {
            return nil
        }
        return startIndex ... endIndex
    }

    private static func replacingContent(
        in text: String,
        range: ClosedRange<String.Index>,
        with replacement: String
    ) -> String {
        let suffixStart = text.index(after: range.upperBound)
        return String(text[..<range.lowerBound]) + replacement + String(text[suffixStart...])
    }

    private static func punctuationCategory(for character: Character) -> Int? {
        switch character {
        case ".", "。": 0
        case "!", "！": 1
        case "?", "？": 2
        default: nil
        }
    }
}
