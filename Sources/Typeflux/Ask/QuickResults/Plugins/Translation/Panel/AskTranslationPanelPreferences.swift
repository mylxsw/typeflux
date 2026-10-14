import Foundation

enum AskTranslationPanelPosition: String, Codable, CaseIterable, Sendable {
    case center, mouse, lastPosition
    var title: String {
        L("ask.translation.panel.position." + rawValue)
    }
}

enum AskTranslationPanelHeight: String, Codable, CaseIterable, Sendable {
    case sixty, eighty, full
    var fraction: Double {
        switch self {
        case .sixty: 0.6
        case .eighty: 0.8
        case .full: 1
        }
    }

    var title: String {
        L("ask.translation.panel.height." + rawValue)
    }
}

enum AskTranslationAutoCopy: String, Codable, CaseIterable, Sendable {
    case none, original, first, second, third
    var title: String {
        L("ask.translation.panel.autoCopy." + rawValue)
    }

    func text(original: String, results: [AskTranslationResult]) -> String? {
        let index: Int
        switch self {
        case .none: return nil
        case .original: return original.isEmpty ? nil : original
        case .first: index = 0
        case .second: index = 1
        case .third: index = 2
        }
        return results.indices.contains(index) ? results[index].completedText : nil
    }
}

enum AskTranslationKeepState: String, Codable, CaseIterable, Sendable {
    case none, tenSeconds, minute, fiveMinutes, forever
    var title: String {
        L("ask.translation.panel.keep." + rawValue)
    }

    var seconds: TimeInterval? {
        switch self {
        case .none: 0
        case .tenSeconds: 10
        case .minute: 60
        case .fiveMinutes: 300
        case .forever: nil
        }
    }

    func retains(dismissedAt: Date?, now: Date) -> Bool {
        guard let seconds else { return true }
        guard seconds > 0, let dismissedAt else { return false }
        return now.timeIntervalSince(dismissedAt) < seconds
    }
}
