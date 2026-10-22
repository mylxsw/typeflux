import Foundation

/// The same feedback choices in the menu bar and the usage guide.
enum FeedbackDestination: String, CaseIterable, Identifiable, Codable {
    case direct, email, github

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .direct: L("sidebar.feedback.directOption")
        case .email: L("sidebar.feedback.emailOption")
        case .github: L("sidebar.feedback.githubOption")
        }
    }

    /// Direct feedback is presented in the app; external choices open their own apps.
    var url: URL? {
        switch self {
        case .direct: return nil
        case .github: return URL(string: "https://github.com/mylxsw/typeflux/issues/new")
        case .email:
            var components = URLComponents()
            components.scheme = "mailto"
            components.path = "mylxsw@aicode.cc"
            components.queryItems = [
                URLQueryItem(name: "subject", value: "Typeflux Feedback"),
                URLQueryItem(name: "body", value: "Hi,\n\nI want to share some feedback about Typeflux:\n")
            ]
            return components.url
        }
    }
}
