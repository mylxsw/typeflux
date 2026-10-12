import AppKit
import SwiftUI

/// Four settings rows for the period: voice input, text produced, AI requests and the
/// time saved (the last one is this Mac's own count).
struct AccountUsageMetricsGrid: View {
    let stats: CloudUsageStats
    let savedMinutes: Int

    var body: some View {
        VStack(alignment: .leading) {
            metric(title: L("account.card.voice"),
                   value: L("account.card.times", AccountUsageDisplayFormatter.count(stats.asrCount)),
                   detail: L("account.page.voiceDetail",
                             AccountUsageDisplayFormatter.audioDuration(stats.asrAudioDurationMs)))
            metric(title: L("account.page.text"),
                   value: L("account.page.chars",
                            AccountUsageDisplayFormatter.count(stats.asrOutputChars + stats.chatOutputChars)),
                   detail: L("account.page.textDetail"))
            metric(title: L("account.card.aiRequests"),
                   value: L("account.card.times", AccountUsageDisplayFormatter.count(stats.chatCount)),
                   detail: L("account.page.tokens", AccountUsageDisplayFormatter.count(stats.chatTotalTokens)))
            metric(title: L("account.page.saved"),
                   value: savedMinutes > 0
                       ? AccountUsageDisplayFormatter.audioDuration(Int64(savedMinutes) * 60000) : "—",
                   detail: L("account.page.savedDetail"))
        }
    }

    private func metric(title: String, value: String, detail: String) -> some View {
        TypefluxSettingsRow(title, description: detail) {
            Text(value).monospacedDigit().textSelection(.enabled)
        }
    }
}
