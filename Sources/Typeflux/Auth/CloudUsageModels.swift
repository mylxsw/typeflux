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

struct CloudCreditSummary: Decodable, Equatable {
    let limit: Int
    let used: Int
    let remaining: Int
    let unlimited: Bool
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
