import AppKit
import SwiftUI

/// Privacy policy, the subscription refresh, invoices and contact.
struct AccountHelpSection: View {
    static let privacyURL = URL(string: "https://typeflux.app/privacy")!
    static let contactAddress = "mylxsw@aicode.cc"
    let showsSubscriptionSync: Bool
    let showsInvoices: Bool
    let isSyncing: Bool
    let onSync: () -> Void
    let onOpenPortal: () -> Void

    var body: some View {
        Group {
            row(L("account.page.privacy"), action: L("account.page.view"), external: true) {
                NSWorkspace.shared.open(Self.privacyURL)
            }
            if showsSubscriptionSync {
                row(L("account.page.refreshSubscription"), action: L("account.page.refreshSubscriptionAction"),
                    external: false, loading: isSyncing, action: onSync)
            }
            if showsInvoices {
                row(L("account.page.invoices"), action: L("account.page.openPortal"),
                    external: true, action: onOpenPortal)
            }
            row(L("account.page.contact"), action: L("account.page.sendEmail"), external: true) {
                if let url = Self.contactURL { NSWorkspace.shared.open(url) }
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
        TypefluxSettingsRow(title) {
            TypefluxButton(kind: .link, action: action) {
                HStack {
                    if loading { TypefluxProgress(label).labelsHidden().accessibilityHidden(true) }
                    if external { Label(label, systemImage: "arrow.up.right") } else { Text(label) }
                }
            }.accessibilityLabel(label).disabled(loading)
        }
    }
}
