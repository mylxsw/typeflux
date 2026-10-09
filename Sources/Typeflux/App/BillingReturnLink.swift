import Foundation

/// `typeflux://billing/return`: the web billing page's "Back to Typeflux" link
/// after a purchase. Opening it only refreshes the balance; it carries no state.
enum BillingReturnLink {
    static let scheme = "typeflux"

    static func matches(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == scheme, url.host?.lowercased() == "billing" else { return false }
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        return path == "return"
    }

    /// Fetches the balance now, so a paused Ask run sees the new credits at once.
    @MainActor
    static func handle(auth: AuthState) async {
        auth.invalidateAccountSummary()
        await auth.refreshAccountSummary()
    }
}
