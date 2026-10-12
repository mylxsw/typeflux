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
                    .font(compact ? .subheadline : .callout)
                    .foregroundStyle(TypefluxColor.secondaryLabel.color)
                Spacer(minLength: 8)
                Text(AccountUsageDisplayFormatter.creditAmount(addon.remaining))
                    .font(compact ? .body.weight(.semibold) : .headline)
                    .foregroundStyle(TypefluxColor.label.color)
                    .monospacedDigit()
            }
            if let note = AccountStatusText.addonExpiry(addon, locale: localization.locale) {
                HStack(spacing: 5) {
                    if addon.expiresSoon {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.body.weight(.semibold))
                    }
                    Text(note).fixedSize(horizontal: false, vertical: true)
                }
                .font(.body)
                .foregroundStyle(addon.expiresSoon ? TypefluxColor.warning.color : TypefluxColor.tertiaryLabel.color)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("account.addon")
    }
}
