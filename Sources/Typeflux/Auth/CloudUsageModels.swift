import Foundation

struct CloudUsageStats: Decodable, Equatable {
    let asrCount: Int64
    let asrAudioDurationMs: Int64
    let asrOutputChars: Int64
    let chatCount: Int64
    let chatOutputChars: Int64
    let chatInputTokens: Int64
    let chatOutputTokens: Int64
    let chatTotalTokens: Int64

    enum CodingKeys: String, CodingKey {
        case asrCount = "asr_count"
        case asrAudioDurationMs = "asr_audio_duration_ms"
        case asrOutputChars = "asr_output_chars"
        case chatCount = "chat_count"
        case chatOutputChars = "chat_output_chars"
        case chatInputTokens = "chat_input_tokens"
        case chatOutputTokens = "chat_output_tokens"
        case chatTotalTokens = "chat_total_tokens"
    }

    static let empty = CloudUsageStats(
        asrCount: 0,
        asrAudioDurationMs: 0,
        asrOutputChars: 0,
        chatCount: 0,
        chatOutputChars: 0,
        chatInputTokens: 0,
        chatOutputTokens: 0,
        chatTotalTokens: 0
    )

    var totalRequests: Int64 {
        asrCount + chatCount
    }
}

/// `limit`, `used` and `remaining` keep their monthly meaning; servers with
/// add-on credits also report the combined balance and the add-on pool.
struct CloudCreditSummary: Decodable, Equatable {
    let limit: Int
    let used: Int
    let remaining: Int
    let unlimited: Bool
    /// Monthly plus add-on credits that can still be spent; nil from older servers.
    let totalRemaining: Int?
    let addon: CloudAddonCredits?

    init(limit: Int, used: Int, remaining: Int, unlimited: Bool,
         totalRemaining: Int? = nil, addon: CloudAddonCredits? = nil) {
        self.limit = limit
        self.used = used
        self.remaining = remaining
        self.unlimited = unlimited
        self.totalRemaining = totalRemaining
        self.addon = addon
    }

    enum CodingKeys: String, CodingKey {
        case limit, used, remaining, unlimited, addon
        case totalRemaining = "total_remaining"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            limit: values.decode(Int.self, forKey: .limit),
            used: values.decode(Int.self, forKey: .used),
            remaining: values.decode(Int.self, forKey: .remaining),
            unlimited: values.decode(Bool.self, forKey: .unlimited),
            totalRemaining: values.decodeIfPresent(Int.self, forKey: .totalRemaining),
            // A malformed add-on block must not hide the monthly balance.
            addon: (try? values.decodeIfPresent(CloudAddonCredits.self, forKey: .addon)) ?? nil
        )
    }

    var monthlyRemaining: Int { max(0, remaining) }

    var addonRemaining: Int { max(0, addon?.remaining ?? 0) }

    /// What the account can still spend. Servers without add-ons report only the month.
    var spendableRemaining: Int {
        max(0, totalRemaining ?? monthlyRemaining + addonRemaining)
    }

    /// Unlimited plans never pause; otherwise only an empty combined balance does.
    var canSpend: Bool { unlimited || spendableRemaining > 0 }
}

/// Purchased credits, spent only after the monthly allowance.
struct CloudAddonCredits: Decodable, Equatable {
    /// Unsettled balance, before this period's overflow is subtracted.
    let balance: Int
    let usedThisPeriod: Int
    let remaining: Int
    let nextExpiry: CloudAddonExpiry?

    init(balance: Int, usedThisPeriod: Int, remaining: Int, nextExpiry: CloudAddonExpiry? = nil) {
        self.balance = balance
        self.usedThisPeriod = usedThisPeriod
        self.remaining = remaining
        self.nextExpiry = nextExpiry
    }

    enum CodingKeys: String, CodingKey {
        case balance, remaining
        case usedThisPeriod = "used_this_period"
        case nextExpiry = "next_expiry"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            balance: values.decodeIfPresent(Int.self, forKey: .balance) ?? 0,
            usedThisPeriod: values.decodeIfPresent(Int.self, forKey: .usedThisPeriod) ?? 0,
            remaining: values.decodeIfPresent(Int.self, forKey: .remaining) ?? 0,
            nextExpiry: (try? values.decodeIfPresent(CloudAddonExpiry.self, forKey: .nextExpiry)) ?? nil
        )
    }
}

/// The add-on purchase that expires first and how many of its credits go with it.
struct CloudAddonExpiry: Decodable, Equatable {
    let credits: Int
    let expiresAt: String

    enum CodingKeys: String, CodingKey {
        case credits
        case expiresAt = "expires_at"
    }

    var date: Date? { ISO8601DateFormatter.typefluxBillingDate(from: expiresAt) }
}

struct CloudUsageCurrentPeriodStats: Decodable, Equatable {
    let periodStart: String
    let periodEnd: String
    let stats: CloudUsageStats
    let credits: CloudCreditSummary?

    init(periodStart: String, periodEnd: String, stats: CloudUsageStats, credits: CloudCreditSummary? = nil) {
        self.periodStart = periodStart
        self.periodEnd = periodEnd
        self.stats = stats
        self.credits = credits
    }

    enum CodingKeys: String, CodingKey {
        case periodStart = "period_start"
        case periodEnd = "period_end"
        case stats
        case credits
    }
}

/// Credits spent per day and per feature in the current usage period, in the
/// time zone the client asked for.
struct CloudUsageBreakdown: Decodable, Equatable {
    struct Day: Decodable, Equatable {
        /// `YYYY-MM-DD` in the breakdown's time zone.
        let date: String
        let voice: Int
        let rewrite: Int
        let ask: Int

        var total: Int {
            voice + rewrite + ask
        }
    }

    let periodStart: String
    let periodEnd: String
    let timezone: String
    let days: [Day]
    let voice: Int
    let rewrite: Int
    let ask: Int

    var total: Int {
        voice + rewrite + ask
    }

    enum CodingKeys: String, CodingKey {
        case periodStart = "period_start"
        case periodEnd = "period_end"
        case timezone
        case days
        case voice
        case rewrite
        case ask
    }
}
