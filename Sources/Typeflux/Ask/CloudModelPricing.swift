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

    var label: String? {
        if let inputPer1k, let outputPer1k,
           let input = Double(inputPer1k), let output = Double(outputPer1k), input.isFinite, output.isFinite, input >= 0, output >= 0 {
            return "↓ " + AccountUsageDisplayFormatter.creditAmount(input) + " / ↑ " + AccountUsageDisplayFormatter.creditAmount(output) + " Credits / 1K"
        }
        guard multiplier.range(of: #"^[0-9]+(?:\.[0-9]{1,4})?$"#, options: .regularExpression) != nil,
              let value = Decimal(string: multiplier, locale: Locale(identifier: "en_US_POSIX")),
              value > 0, value <= 100 else { return nil }
        return NSDecimalNumber(decimal: value).stringValue + "X"
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
