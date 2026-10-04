import SwiftUI

/// How hard the model thinks before answering. `providerDefault` ("Auto") sends
/// nothing and lets the model decide; the levels go from lightest to heaviest.
enum AskReasoningEffort: String, CaseIterable {
    case providerDefault = ""
    case low, medium, high, xhigh, max

    /// Every level, lightest first.
    static let levels: [AskReasoningEffort] = [.low, .medium, .high, .xhigh, .max]
    /// What a reasoning model offers when its catalog entry lists no levels, and what
    /// the user's own models offer: the three levels Ask had before levels existed.
    static let defaultLevels: [AskReasoningEffort] = [.low, .medium, .high]

    var label: String {
        L("ask.reasoning." + (self == .providerDefault ? "default" : rawValue))
    }

    /// One line under the slider, so the trade-off is visible before picking.
    var caption: String {
        L("ask.reasoning." + (self == .providerDefault ? "default" : rawValue) + ".caption")
    }

    /// The levels `model` accepts, lightest first; empty when it cannot be adjusted.
    /// Cloud models declare reasoning and their levels in the catalog. The user's own
    /// models get the default levels unless known not to reason; a provider that
    /// rejects the parameter is retried without it (see `AskReasoningRequest`).
    static func levels(for model: RegisteredModel?) -> [AskReasoningEffort] {
        guard let model else { return [] }
        guard model.reference.hasPrefix("cloud:") else { return model.reasoning == false ? [] : defaultLevels }
        guard model.reasoning == true else { return [] }
        let listed = Set((model.reasoningEfforts ?? []).compactMap(Self.init(rawValue:)))
        let offered = levels.filter(listed.contains)
        return offered.isEmpty ? defaultLevels : offered
    }

    static func isAvailable(for model: RegisteredModel?) -> Bool {
        !levels(for: model).isEmpty
    }

    /// This level if offered, else the closest offered one (the lighter on a tie).
    /// "Auto" stays "Auto"; with nothing offered there is nothing to choose.
    func nearest(in offered: [AskReasoningEffort]) -> AskReasoningEffort {
        guard self != .providerDefault, !offered.isEmpty, !offered.contains(self),
              let origin = Self.levels.firstIndex(of: self) else { return offered.isEmpty ? .providerDefault : self }
        let rank = { (effort: AskReasoningEffort) in Self.levels.firstIndex(of: effort) ?? 0 }
        return offered.min { lhs, rhs in
            let left = abs(rank(lhs) - origin), right = abs(rank(rhs) - origin)
            return left == right ? rank(lhs) < rank(rhs) : left < right
        } ?? self
    }

    /// The value sent with the request: the nearest level the model accepts, or nothing.
    func requestValue(for model: RegisteredModel?) -> String? {
        let offered = Self.levels(for: model)
        guard self != .providerDefault, !offered.isEmpty else { return nil }
        return nearest(in: offered).rawValue
    }
}
