import Foundation

/// Provider-neutral thinking levels. Auto omits the request parameter so the
/// provider can choose its default; cloud capabilities are authoritative.
public enum ChatReasoningEffort: String, CaseIterable, Sendable {
    case providerDefault = ""
    case low, medium, high, xhigh, max

    public static let levels: [Self] = [.low, .medium, .high, .xhigh, .max]
    public static let defaultLevels: [Self] = [.low, .medium, .high]

    public static func levels(for model: ChatModel?) -> [Self] {
        guard model?.reasoning == true else { return [] }
        let listed = Set((model?.reasoningEfforts ?? []).compactMap(Self.init(rawValue:)))
        let offered = levels.filter(listed.contains)
        return offered.isEmpty ? defaultLevels : offered
    }

    /// Choose the closest supported level, favoring the lighter one on a tie.
    public func nearest(in offered: [Self]) -> Self {
        guard self != .providerDefault, !offered.isEmpty, !offered.contains(self),
              let origin = Self.levels.firstIndex(of: self) else {
            return offered.isEmpty ? .providerDefault : self
        }
        let rank = { (effort: Self) in Self.levels.firstIndex(of: effort) ?? 0 }
        return offered.min { lhs, rhs in
            let left = abs(rank(lhs) - origin), right = abs(rank(rhs) - origin)
            return left == right ? rank(lhs) < rank(rhs) : left < right
        } ?? self
    }

    public func isTop(in levels: [Self]) -> Bool {
        self != .providerDefault && self == levels.last
    }

    public func requestValue(for model: ChatModel?) -> String? {
        let offered = Self.levels(for: model)
        guard self != .providerDefault, !offered.isEmpty else { return nil }
        return nearest(in: offered).rawValue
    }
}
