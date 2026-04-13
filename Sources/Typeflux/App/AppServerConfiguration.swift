import Foundation

enum AppServerConfiguration {
    private static let defaultBaseURL = "https://typeflux.gulu.ai"
    private static let defaultGoogleOAuthClientID = "567492048493-bh84p3mfjfjimsfvga7pil3cc373d389.apps.googleusercontent.com"

    static var apiBaseURL: String {
        ProcessInfo.processInfo.environment["TYPEFLUX_API_URL"] ?? defaultBaseURL
    }

    /// Google OAuth 2.0 Client ID from Google Cloud Console.
    /// Recommended: create an iOS-type client (no secret required).
    /// Desktop-type clients also work but require GOOGLE_OAUTH_CLIENT_SECRET as well.
    /// When empty, Google Sign-In is disabled in the login UI.
    static var googleOAuthClientID: String {
        ProcessInfo.processInfo.environment["GOOGLE_OAUTH_CLIENT_ID"] ?? defaultGoogleOAuthClientID
    }

    /// Google OAuth 2.0 Client Secret — only required for Desktop-type clients.
    /// iOS-type clients are public clients and do not need a secret.
    /// Leave empty (default) when using an iOS-type client ID.
    static var googleOAuthClientSecret: String {
        ProcessInfo.processInfo.environment["GOOGLE_OAUTH_CLIENT_SECRET"] ?? ""
    }
}
