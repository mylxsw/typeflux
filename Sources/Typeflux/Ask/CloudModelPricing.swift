import Foundation

struct CloudModelPricing: Codable, Equatable, Sendable {
    var multiplier: String
    var baseRateVersion: String?
    var unit: String?
    var inputPer1k: String? = nil
    var outputPer1k: String? = nil
    var cachedPer1k: String? = nil

    enum CodingKeys: String, CodingKey {
        case multiplier, baseRateVersion, unit
        case inputPer1k = "inputPer1K"
        case outputPer1k = "outputPer1K"
        case cachedPer1k = "cachedPer1K"
    }

    /// Catalog rates already include all pricing adjustments.
    var label: String? {
        guard let input = Self.rate(inputPer1k), let output = Self.rate(outputPer1k) else { return nil }
        return "↓ \(input) / ↑ \(output) Credits / 1K Tokens"
    }

    var tooltip: String? {
        guard let input = Self.rate(inputPer1k), let output = Self.rate(outputPer1k) else { return nil }
        let cached = Self.rate(cachedPer1k).map { "\($0) Credits / 1K Tokens" }
            ?? L("models.cloud.price.unavailable")
        return String(format: L("models.cloud.price.details"), input, output, cached)
    }

    private static func rate(_ raw: String?) -> String? {
        guard let raw, let value = Double(raw), value.isFinite, value >= 0 else { return nil }
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 16
        guard let formatted = formatter.string(from: NSNumber(value: value)) else { return nil }
        // Preserve very small nonzero rates instead of suggesting that they are free.
        return value > 0 && Double(formatted) == 0 ? raw : formatted
    }

}

extension AskCloudModel {
    var registered: RegisteredModel {
        RegisteredModel(id: id, name: name, reference: reference,
                        vision: vision ?? (modelVersion == nil && id == "default" ? true : nil),
                        scenarios: scenarios, pricing: pricing,
                        contextWindowTokens: contextWindowTokens, maxOutputTokens: maxOutputTokens, reasoning: capabilities?["reasoning"],
                        reasoningEfforts: reasoningEfforts)
    }
}
