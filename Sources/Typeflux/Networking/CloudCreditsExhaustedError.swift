import Foundation

/// `details` of a 402 `CREDITS_EXHAUSTED` response: what is left of the month
/// and of the add-on pool, and whether the account can buy more.
struct CloudCreditsExhaustedDetails: Decodable, Equatable, Sendable {
    let monthlyRemaining: Int
    let addonRemaining: Int
    let periodEnd: String?
    let purchasable: Bool

    init(monthlyRemaining: Int = 0, addonRemaining: Int = 0, periodEnd: String? = nil, purchasable: Bool = false) {
        self.monthlyRemaining = monthlyRemaining
        self.addonRemaining = addonRemaining
        self.periodEnd = periodEnd
        self.purchasable = purchasable
    }

    enum CodingKeys: String, CodingKey {
        case purchasable
        case monthlyRemaining = "monthly_remaining"
        case addonRemaining = "addon_remaining"
        case periodEnd = "period_end"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            monthlyRemaining: values.decodeIfPresent(Int.self, forKey: .monthlyRemaining) ?? 0,
            addonRemaining: values.decodeIfPresent(Int.self, forKey: .addonRemaining) ?? 0,
            periodEnd: values.decodeIfPresent(String.self, forKey: .periodEnd),
            purchasable: values.decodeIfPresent(Bool.self, forKey: .purchasable) ?? false
        )
    }
}

/// The account has no monthly or add-on credits left. Shown by code, never with
/// the server's English message.
struct CloudCreditsExhaustedError: LocalizedError, Equatable, Sendable {
    static let code = "CREDITS_EXHAUSTED"

    let details: CloudCreditsExhaustedDetails?

    var errorDescription: String? { L("cloud.error.creditsExhausted") }

    /// Reads a `CREDITS_EXHAUSTED` envelope; any other body or code is not this error.
    static func parse(data: Data) -> CloudCreditsExhaustedError? {
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == code
        else { return nil }
        return CloudCreditsExhaustedError(details: envelope.details)
    }

    private struct Envelope: Decodable {
        let code: String
        let details: CloudCreditsExhaustedDetails?

        enum CodingKeys: String, CodingKey { case code, details }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            code = try values.decode(String.self, forKey: .code)
            // Details are optional context; a different shape still means exhausted.
            details = (try? values.decodeIfPresent(CloudCreditsExhaustedDetails.self, forKey: .details)) ?? nil
        }
    }
}
