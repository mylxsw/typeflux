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

    /// Catalog rates already include all pricing adjustments; only convert the display unit.
    var label: String? {
        guard let inputPer1k, let outputPer1k,
              let input = Double(inputPer1k), let output = Double(outputPer1k),
              input.isFinite, output.isFinite, input >= 0, output >= 0,
              (input * 1000).isFinite, (output * 1000).isFinite else { return nil }
        return "↓ " + AccountUsageDisplayFormatter.creditAmount(input * 1000)
            + " / ↑ " + AccountUsageDisplayFormatter.creditAmount(output * 1000) + " Credits / 1M Tokens"
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
