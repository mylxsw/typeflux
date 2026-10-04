import Foundation

struct CloudModelPricing: Codable, Equatable, Sendable {
    var multiplier: String
    var baseRateVersion: String?
    var unit: String?

    var label: String? {
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
