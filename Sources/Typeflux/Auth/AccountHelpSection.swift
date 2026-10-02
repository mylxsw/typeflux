import AppKit
import SwiftUI

/// Privacy policy, the "paid but not active" refresh, invoices and contact.
struct AccountHelpSection: View {
    static let privacyURL = URL(string: "https://typeflux.app/privacy")!
    static let contactAddress = "mylxsw@aicode.cc"

    let showsSubscriptionSync: Bool
    let showsInvoices: Bool
    let isSyncing: Bool
    let onSync: () -> Void
    let onOpenPortal: () -> Void

    var body: some View {
        StudioCard(padding: StudioTheme.Spacing.mediumLarge) {
            VStack(spacing: 0) {
                row(L("account.page.privacy"), action: L("account.page.view"), external: true) {
                    NSWorkspace.shared.open(Self.privacyURL)
                }
                if showsSubscriptionSync {
                    Divider()
                    row(L("account.page.refreshSubscription"), action: L("account.page.refreshSubscriptionAction"),
                        external: false, loading: isSyncing, action: onSync)
                }
                if showsInvoices {
                    Divider()
                    row(L("account.page.invoices"), action: L("account.page.openPortal"), external: true,
                        action: onOpenPortal)
                }
                Divider()
                row(L("account.page.contact"), action: L("account.page.sendEmail"), external: true) {
                    if let url = Self.contactURL { NSWorkspace.shared.open(url) }
                }
            }
        }
    }

    static var contactURL: URL? {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = contactAddress
        components.queryItems = [URLQueryItem(name: "subject", value: "Typeflux Cloud")]
        return components.url
    }

    private func row(_ title: String, action label: String, external: Bool, loading: Bool = false,
                     action: @escaping () -> Void) -> some View {
        HStack {
            Text(title)
                .font(.studioBody(StudioTheme.Typography.body))
                .foregroundStyle(StudioTheme.textPrimary)
            Spacer()
            Button(action: action) {
                HStack(spacing: 3) {
                    if loading { ProgressView().controlSize(.mini) }
                    Text(label)
                    if external { Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .semibold)) }
                }
                .font(.studioBody(StudioTheme.Typography.bodySmall))
                .foregroundStyle(StudioTheme.accent)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(loading)
        }
        .frame(height: 40)
    }
}
