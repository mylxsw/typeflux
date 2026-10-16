import Foundation

/// Coverage calibrates lexical evidence against normalized cosine. Rejection uses an absolute fallback
/// and distinct-file margins, with no chunk-count mean or single-vector z-score.
struct SemanticSearchRanking {
    struct Evidence {
        var coverage: Double
        var phrase: Bool
        var identifier: Bool
    }

    let originalText: String
    let text: String
    let terms: [String]
    let identifiers: [String]
    let quoted: [String]
    let prefersCJK: Bool
    let preferredModality: SemanticMediaPriority?
    var semanticFloor: Double = 0.45

    init(_ text: String) {
        prefersCJK = SemanticScoreCalibration.script(text) == 1
        originalText = text
        self.text = Self.normalize(text)
        terms = Array(SemanticFilePolicy.searchTerms(text).prefix(64))
        let normalized = Self.normalize(text)
        let hints: [(SemanticMediaPriority, [String])] = [
            (.image, ["image", "photo", "screenshot", "图片", "照片", "截图"]),
            (.audio, ["audio", "recording", "音频", "录音"]),
            (.video, ["video", "movie", "视频", "影片"]),
            (.document, ["pdf", "document", "文档"])
        ]
        preferredModality = hints.first { _, words in
            words.contains { word in
                word.unicodeScalars.contains(where: \.properties.isIdeographic) ? normalized.contains(word)
                    : normalized.split(whereSeparator: { !$0.isLetter }).contains(Substring(word))
            }
        }?.0
        identifiers = normalized.split {
            !$0.isASCII || (!$0.isLetter && !$0.isNumber && $0 != "-" && $0 != "_")
        }.map(String.init).filter {
            $0.unicodeScalars.contains(where: CharacterSet.decimalDigits.contains)
                && ($0.contains("-") || $0.contains("_") || $0.range(
                    of: "^[a-z]{1,8}[0-9]{3,}[a-z0-9]*$",
                    options: .regularExpression
                ) != nil || ($0.count >= 4 && $0.unicodeScalars.allSatisfy(CharacterSet.decimalDigits.contains)))
        }
        let pieces = Self.normalize(text).split(separator: "\"", omittingEmptySubsequences: false)
        quoted = pieces.enumerated().filter { $0.offset % 2 == 1 }.map { String($0.element) }.filter { !$0.isEmpty }
    }

    static func normalize(_ text: String) -> String {
        let value = text.precomposedStringWithCompatibilityMapping.folding(options: .caseInsensitive,
                                                                           locale: Locale(identifier: "en_US_POSIX"))
        let latin = { (scalar: Unicode.Scalar) in scalar.value < 0x0250 || (0x1E00 ... 0x1EFF).contains(scalar.value) }
        guard value.unicodeScalars.contains(where: { $0.value >= 0x00C0 && latin($0) }) else { return value }
        var result = "", run = ""
        func flush() {
            result += run.folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US_POSIX"))
            run = ""
        }
        for scalar in value.unicodeScalars {
            if latin(scalar) {
                run.unicodeScalars.append(scalar)
            } else {
                flush(); result.unicodeScalars.append(scalar)
            }
        }
        flush()
        return result
    }

    func evidence(_ passage: String) -> Evidence {
        let normalized = Self.normalize(passage)
        let tokens = Set(SemanticFilePolicy.terms(passage).split(separator: " ").map(String.init))
        let coverage = terms.isEmpty ? 0 : Double(terms.filter { tokens.contains($0) }.count) / Double(terms.count)
        func containsIdentifier(_ needle: String) -> Bool {
            // Latin/number boundaries reject TS-90010 and XTS-9001, while allowing adjacent CJK prose.
            let pattern = "(?<![\\p{Latin}\\p{N}_-])" + NSRegularExpression.escapedPattern(for: needle)
                + "(?![\\p{Latin}\\p{N}_-])"
            return normalized.range(of: pattern, options: .regularExpression) != nil
        }
        return Evidence(coverage: coverage,
                        phrase: quoted.isEmpty ? normalized.contains(text) : quoted.allSatisfy(normalized.contains),
                        identifier: !identifiers.isEmpty && identifiers.allSatisfy(containsIdentifier))
    }

    func confident(peak: Double, runnerUp: Double?, completeLexical: Bool) -> Bool {
        completeLexical || peak >= 0.70 || (runnerUp.map { peak >= semanticFloor && peak - $0 >= 0.04 } ?? false)
    }

    func lexicalAccepted(_ evidence: Evidence) -> Bool {
        if !identifiers.isEmpty {
            return evidence.identifier
        }
        if !quoted.isEmpty {
            return evidence.phrase
        }
        return evidence.coverage >= 0.5
    }

    func score(
        cosine: Double?,
        evidence: Evidence,
        modality: SemanticMediaPriority,
        embedding: SemanticMediaInput.Kind? = nil
    ) -> Double? {
        // Number/quoted queries are exact searches. A semantic near miss cannot replace missing evidence.
        if !identifiers.isEmpty && !evidence.identifier {
            return nil
        }
        if !quoted.isEmpty && !evidence.phrase {
            return nil
        }
        let cosine = cosine.flatMap { $0.isFinite ? max(0, min(1, $0)) : nil }
        // Fixed model-space gates avoid a chunk-count-dependent mean or a single-vector z-score.
        // The generated-speech calibration changes ordering only, never answerability.
        guard lexicalAccepted(evidence) || (cosine ?? 0) >= semanticFloor else { return nil }
        if evidence.identifier {
            return 3.0 + (cosine ?? 0) * 0.01
        }
        if evidence.coverage == 1 && evidence.phrase {
            // Preserve the exact body phrase contract independently of soft semantic tuning.
            return 1.0 + (cosine ?? 0) * 0.01
        }
        // Partial lexical evidence never subtracts score at equal cosine. Explicit media intent
        // retains its context preference; ordinary queries use a small script tie-break only.
        let lexical = (evidence.phrase ? 0.12 : 0) + (evidence.coverage == 1 ? 0.10 : 0)
        let matchingMedia = preferredModality == modality || (preferredModality == .audio && embedding == .audio)
            || (preferredModality == .image && embedding == .image)
        return 0.55 * (cosine ?? 0) + lexical + (matchingMedia ? 0.10 : 0)
    }

    func scriptAdjustment(_ bucket: SemanticScoreCalibration.Bucket) -> Double {
        guard preferredModality == nil, bucket == .text || bucket == .cjkText else { return 0 }
        return prefersCJK == (bucket == .cjkText) ? 0.025 : 0
    }

    static func allowed(_ path: String, query: AskSearchQuery, type: AskFileType, scope: AskFileScope) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        guard scope.includes(path, isDirectory: false), SemanticFilePolicy.allows(path),
              type.matches(kind: .file, extension: ext), query.fileExtension == nil || query.fileExtension == ext
        else { return false }
        return query.folder.map {
            AskFileIndexState.contains(AskSearchText.normalize((path as NSString).deletingLastPathComponent), $0)
        } ?? true
    }
}
