import Foundation

/// The web billing page for a given tab. The page token rides in the fragment,
/// so the tab goes in the query and the fragment is kept as is.
enum BillingPlansLink {
    static let creditsTab = "credits"

    static func url(_ plansURL: URL, tab: String?) -> URL {
        guard let tab, var components = URLComponents(url: plansURL, resolvingAgainstBaseURL: false) else {
            return plansURL
        }
        var items = (components.queryItems ?? []).filter { $0.name != "tab" }
        items.append(URLQueryItem(name: "tab", value: tab))
        components.queryItems = items
        return components.url ?? plansURL
    }
}
