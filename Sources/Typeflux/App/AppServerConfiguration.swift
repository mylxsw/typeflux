import Foundation

enum AppServerConfiguration {
    private static let defaultBaseURLs = ["https://typeflux-api.gulu.ai"]
    private static let defaultGoogleOAuthClientID = "567492048493-bh84p3mfjfjimsfvga7pil3cc373d389.apps.googleusercontent.com"
    private static let defaultGoogleCloudOAuthClientID = "86325451552-drgdrf01ffjo0on25a1psmg4mpvlo8gi.apps.googleusercontent.com"
    private static let defaultGithubOAuthClientID = "Ov23lidqnPDEOAvE8RvH"

    private static func configuredValue(
        environmentKey: String,
        infoPlistKey: String,
        default defaultValue: String
    ) -> String {
        if let value = ProcessInfo.processInfo.environment[environmentKey], !value.isEmpty {
            return value
        }
        if let value = Bundle.main.object(forInfoDictionaryKey: infoPlistKey) as? String, !value.isEmpty {
            return value
        }
        return defaultValue
    }

    /// Ordered list of Typeflux Cloud server base URLs.
    /// Sources, in priority order:
    /// 1. `TYPEFLUX_API_URLS` env var or Info.plist key — comma-separated list
    /// 2. `TYPEFLUX_API_URL` env var or Info.plist key — single URL (legacy)
    /// 3. Built-in default
    /// The list always has at least one entry.
    static var apiBaseURLs: [String] {
        if let multi = parseList(rawMultiEndpointValue()), !multi.isEmpty {
            return multi
        }
        let single = configuredValue(
            environmentKey: "TYPEFLUX_API_URL",
            infoPlistKey: "TYPEFLUX_API_URL",
            default: defaultBaseURLs.first ?? ""
        )
        return [single]
    }

    /// Backwards-compatible single base URL accessor — returns the first
    /// configured endpoint. New code should use `apiBaseURLs` together with
    /// `CloudEndpointSelector` for latency-based routing and failover.
    static var apiBaseURL: String {
        apiBaseURLs.first ?? (defaultBaseURLs.first ?? "")
    }

    private static func rawMultiEndpointValue() -> String? {
        if let value = ProcessInfo.processInfo.environment["TYPEFLUX_API_URLS"], !value.isEmpty {
            return value
        }
        if let value = Bundle.main.object(forInfoDictionaryKey: "TYPEFLUX_API_URLS") as? String, !value.isEmpty {
            return value
        }
        return nil
    }

    static func parseList(_ raw: String?) -> [String]? {
        guard let raw, !raw.isEmpty else { return nil }
        let parts = raw
            .split(separator: ",", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        // Preserve order while removing duplicates so users can paste a list
        // without worrying about repeated entries.
        var seen = Set<String>()
        var result: [String] = []
        for part in parts {
            if seen.insert(part).inserted {
                result.append(part)
            }
        }
        return result.isEmpty ? nil : result
    }

    /// Google OAuth 2.0 Client ID from Google Cloud Console.
    /// Recommended: create an iOS-type client (no secret required).
    /// Desktop-type clients also work but require GOOGLE_OAUTH_CLIENT_SECRET as well.
    /// When empty, Google Sign-In is disabled in the login UI.
    static var googleOAuthClientID: String {
        configuredValue(
            environmentKey: "GOOGLE_OAUTH_CLIENT_ID",
            infoPlistKey: "GOOGLE_OAUTH_CLIENT_ID",
            default: defaultGoogleOAuthClientID
        )
    }

    /// Google OAuth 2.0 Client Secret — only required for Desktop-type clients.
    /// iOS-type clients are public clients and do not need a secret.
    /// Leave empty (default) when using an iOS-type client ID.
    static var googleOAuthClientSecret: String {
        configuredValue(
            environmentKey: "GOOGLE_OAUTH_CLIENT_SECRET",
            infoPlistKey: "GOOGLE_OAUTH_CLIENT_SECRET",
            default: ""
        )
    }

    /// Google OAuth 2.0 Client ID used only for direct Google Cloud Speech-to-Text access.
    /// Keep this separate from Google Sign-In so adding Cloud API scopes does not affect login verification.
    /// Falls back to the sign-in client until a dedicated Cloud client is configured.
    static var googleCloudOAuthClientID: String {
        configuredValue(
            environmentKey: "GOOGLE_CLOUD_OAUTH_CLIENT_ID",
            infoPlistKey: "GOOGLE_CLOUD_OAUTH_CLIENT_ID",
            default: defaultGoogleCloudOAuthClientID
        )
    }

    /// Google OAuth 2.0 Client Secret for the dedicated Google Cloud Speech client.
    /// Required only if that client is a Desktop app client.
    static var googleCloudOAuthClientSecret: String {
        configuredValue(
            environmentKey: "GOOGLE_CLOUD_OAUTH_CLIENT_SECRET",
            infoPlistKey: "GOOGLE_CLOUD_OAUTH_CLIENT_SECRET",
            default: googleOAuthClientSecret
        )
    }

    /// GitHub OAuth App client ID from https://github.com/settings/developers.
    /// When empty, GitHub Sign-In is disabled in the login UI.
    static var githubOAuthClientID: String {
        configuredValue(
            environmentKey: "GITHUB_OAUTH_CLIENT_ID",
            infoPlistKey: "GITHUB_OAUTH_CLIENT_ID",
            default: defaultGithubOAuthClientID
        )
    }

}
