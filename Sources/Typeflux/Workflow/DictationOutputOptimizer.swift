import Foundation

enum DictationOutputOptimizer {
    private static let maximumShortSentenceLength = 80
    private static let trailingSentencePunctuation: Set<Character> = [".", "!", "?", "。", "！", "？", "…"]
    private static let sentenceBoundaryCharacters: Set<Character> = [".", "!", "?", "。", "！", "？"]

    static func optimize(_ text: String) -> String {
        let startTrimmedIndex = text.firstIndex(where: { !$0.isWhitespace && !$0.isNewline }) ?? text.endIndex
        let endTrimmedIndex = text.lastIndex(where: { !$0.isWhitespace && !$0.isNewline }) ?? text.startIndex

        guard startTrimmedIndex <= endTrimmedIndex else { return text }

        let trimmed = String(text[startTrimmedIndex...endTrimmedIndex])
        guard shouldRemoveTrailingPunctuation(from: trimmed) else { return text }

        let body = removingTrailingSentencePunctuation(from: trimmed)
        let trailingSpaces = String(text[text.index(after: endTrimmedIndex)...])

        return String(text[..<startTrimmedIndex]) + body + trailingSpaces
    }

    private static func shouldRemoveTrailingPunctuation(from text: String) -> Bool {
        guard !text.isEmpty, text.count <= maximumShortSentenceLength else { return false }
        guard !text.contains(where: \.isNewline) else { return false }
        guard let lastCharacter = text.last, trailingSentencePunctuation.contains(lastCharacter) else { return false }

        let body = removingTrailingSentencePunctuation(from: text)
        guard !body.isEmpty else { return false }

        return !body.contains(where: { sentenceBoundaryCharacters.contains($0) })
    }

    private static func removingTrailingSentencePunctuation(from text: String) -> String {
        var result = text
        while let lastCharacter = result.last, trailingSentencePunctuation.contains(lastCharacter) {
            result.removeLast()
        }
        return result
    }
}
