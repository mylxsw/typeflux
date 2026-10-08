import SwiftUI

/// Add-on credits under the monthly balance, on the Ask account card and the
/// account page: what is left, and when the first purchase expires.
struct AccountAddonCreditRow: View {
    let addon: AccountUsageCreditPresentation.Addon
    var compact = true
    @ObservedObject private var localization = AppLocalization.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(L("account.addon.title"))
                    .font(.system(size: compact ? 11.5 : 12.5))
                    .foregroundStyle(StudioTheme.textSecondary)
                Spacer(minLength: 8)
                Text(AccountUsageDisplayFormatter.creditAmount(addon.remaining))
                    .font(.system(size: compact ? 13 : 14, weight: .semibold))
                    .foregroundStyle(StudioTheme.textPrimary)
                    .monospacedDigit()
            }
            if let note = AccountStatusText.addonExpiry(addon, locale: localization.locale) {
                HStack(spacing: 5) {
                    if addon.expiresSoon {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    Text(note).fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: 11))
                .foregroundStyle(addon.expiresSoon ? StudioTheme.warning : StudioTheme.textTertiary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("account.addon")
    }
}
