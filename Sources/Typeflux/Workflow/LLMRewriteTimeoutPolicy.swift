import Foundation

enum LLMRewriteTimeoutKind: String, Codable, Equatable, Sendable {
    case firstOutput
    case stalledOutput
    case total
}

struct LLMRewriteTimeoutBudget: Equatable, Sendable {
    let estimatedInputUnits: Int
    let baseSeconds: TimeInterval
    let firstOutputSeconds: TimeInterval
    let stallSeconds: TimeInterval
    let totalSeconds: TimeInterval
    let watchdogSeconds: TimeInterval

    var baseMilliseconds: Int {
        Self.milliseconds(baseSeconds)
    }

    var firstOutputMilliseconds: Int {
        Self.milliseconds(firstOutputSeconds)
    }

    var stallMilliseconds: Int {
        Self.milliseconds(stallSeconds)
    }

    var totalMilliseconds: Int {
        Self.milliseconds(totalSeconds)
    }

    private static func milliseconds(_ seconds: TimeInterval) -> Int {
        Int(max(0, seconds) * 1_000)
    }

    static func fixed(_ seconds: TimeInterval) -> LLMRewriteTimeoutBudget {
        let timeout = max(0, seconds)
        return LLMRewriteTimeoutBudget(
            estimatedInputUnits: 0,
            baseSeconds: timeout,
            firstOutputSeconds: timeout,
            stallSeconds: timeout,
            totalSeconds: timeout,
            watchdogSeconds: timeout + LLMRewriteTimeoutPolicy.watchdogGraceSeconds
        )
    }
}

enum LLMRewriteTimeoutPolicy {
    static let baseInputUnits = 100
    static let unitsPerTotalStep = 50
    static let secondsPerTotalStep: TimeInterval = 2
    static let unitsPerFirstOutputStep = 200
    static let secondsPerFirstOutputStep: TimeInterval = 1.5
    static let maximumFirstOutputSeconds: TimeInterval = 20
    static let minimumStallSeconds: TimeInterval = 15
    static let maximumTotalSeconds: TimeInterval = 120
    static let watchdogGraceSeconds: TimeInterval = 10

    static func budget(sourceText: String, baseSeconds: TimeInterval) -> LLMRewriteTimeoutBudget {
        let normalizedBase = max(0, baseSeconds)
        let inputUnits = estimatedInputUnits(for: sourceText)
        let extraUnits = max(0, inputUnits - baseInputUnits)
        let totalSteps = roundedUpDivision(extraUnits, by: unitsPerTotalStep)
        let firstOutputSteps = roundedUpDivision(extraUnits, by: unitsPerFirstOutputStep)
        let totalSeconds = min(
            maximumTotalSeconds,
            normalizedBase + TimeInterval(totalSteps) * secondsPerTotalStep
        )
        let firstOutputCap = max(normalizedBase, maximumFirstOutputSeconds)
        let firstOutputSeconds = min(
            totalSeconds,
            min(firstOutputCap, normalizedBase + TimeInterval(firstOutputSteps) * secondsPerFirstOutputStep)
        )
        let stallSeconds = min(totalSeconds, max(minimumStallSeconds, normalizedBase))

        return LLMRewriteTimeoutBudget(
            estimatedInputUnits: inputUnits,
            baseSeconds: normalizedBase,
            firstOutputSeconds: firstOutputSeconds,
            stallSeconds: stallSeconds,
            totalSeconds: totalSeconds,
            watchdogSeconds: totalSeconds + watchdogGraceSeconds
        )
    }

    /// Approximates model token load without adding a provider-specific tokenizer.
    /// Non-ASCII graphemes count as one unit; compact ASCII content counts as one
    /// unit per four characters. Whitespace does not consume output-sized budget.
    static func estimatedInputUnits(for text: String) -> Int {
        var nonASCIIUnits = 0
        var compactASCIICharacters = 0

        for character in text {
            if character.isWhitespace {
                continue
            }
            if character.unicodeScalars.allSatisfy(\.isASCII) {
                compactASCIICharacters += 1
            } else {
                nonASCIIUnits += 1
            }
        }

        return nonASCIIUnits + roundedUpDivision(compactASCIICharacters, by: 4)
    }

    private static func roundedUpDivision(_ value: Int, by divisor: Int) -> Int {
        guard value > 0 else { return 0 }
        return (value + divisor - 1) / divisor
    }
}

final class LLMRewriteProgressTracker: @unchecked Sendable {
    struct Snapshot {
        let firstOutputElapsed: TimeInterval?
        let lastOutputElapsed: TimeInterval?
    }

    private let startedAt = ProcessInfo.processInfo.systemUptime
    private var firstOutputElapsed: TimeInterval?
    private var lastOutputElapsed: TimeInterval?
    private let lock = NSLock()

    func markOutput() {
        let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
        lock.lock()
        firstOutputElapsed = firstOutputElapsed ?? elapsed
        lastOutputElapsed = elapsed
        lock.unlock()
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(
            firstOutputElapsed: firstOutputElapsed,
            lastOutputElapsed: lastOutputElapsed
        )
    }

    var elapsed: TimeInterval {
        ProcessInfo.processInfo.systemUptime - startedAt
    }
}
