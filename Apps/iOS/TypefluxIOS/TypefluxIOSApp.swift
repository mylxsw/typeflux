import SwiftUI
import TypefluxChat
import Network

@main
struct TypefluxIOSApp: App {
    @State private var store: ChatStore
    @State private var preferences: ChatPreferences
    @Environment(\.scenePhase) private var scenePhase

    init() {
        #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--synthetic-preview") {
                _store = State(initialValue: SyntheticPreview.makeStore())
                _preferences = State(initialValue: ChatPreferences
                    .synthetic(arguments: ProcessInfo.processInfo.arguments))
                return
            }
        #endif
        let endpoint = AppConfiguration.endpoint
        _preferences = State(initialValue: ChatPreferences())
        _store = State(initialValue: ChatStore(
            service: ChatAPIClient(baseURL: endpoint, deviceId: DeviceIdentity.persistentID()),
            credentials: KeychainCredentialStore(endpoint: endpoint),
            deviceID: DeviceIdentity.persistentID()
        ))
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if store.isAuthenticated {
                    ChatRootView(store: store, preferences: preferences)
                } else {
                    LoginView(store: store)
                }
            }
            .tint(ChatTheme.accent)
            .preferredColorScheme(preferredColorScheme)
            .task { await store.restore() }
            .onChange(of: scenePhase) { _, phase in
                Task { await store.setForeground(phase == .active) }
            }
        }
    }

    private var preferredColorScheme: ColorScheme? {
        #if DEBUG
            if store.isSynthetic, ProcessInfo.processInfo.arguments.contains("--synthetic-dark") {
                return .dark
            }
        #endif
        return preferences.appearance.colorScheme
    }
}

enum AppConfiguration {
    static let endpoint = resolve(
        Bundle.main.object(forInfoDictionaryKey: "TYPEFLUX_API_URL") as? String,
        allowLocalHTTP: Bundle.main.object(forInfoDictionaryKey: "TYPEFLUX_ALLOW_INSECURE_HTTP") as? String == "YES"
    )

    static func resolve(_ configured: String?, allowLocalHTTP: Bool = false) -> URL {
        // Match the primary macOS AppServerConfiguration endpoint. Endpoint changes
        // are build-time only and have separate Keychain namespaces.
        let fallback = URL(string: "https://api.typeflux.app")!
        guard let configured, !configured.contains(where: \.isWhitespace),
              let url = URL(string: configured), let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.port.map({ (1...65535).contains($0) }) ?? true else { return fallback }
        var localHTTPAllowed = false
        #if DEBUG
            localHTTPAllowed = allowLocalHTTP && url.scheme == "http" && isLocalDevelopmentHost(host)
        #endif
        guard url.scheme == "https" || localHTTPAllowed else { return fallback }
        return url
    }

    static func isLocalDevelopmentHost(_ host: String) -> Bool {
        let name = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if name == "localhost" || (name.hasSuffix(".local") && name.count > 6) { return true }
        if let bytes = IPv4Address(name)?.rawValue {
            return bytes[0] == 127 || bytes[0] == 10 ||
                (bytes[0] == 172 && (16...31).contains(bytes[1])) ||
                (bytes[0] == 192 && bytes[1] == 168) || (bytes[0] == 169 && bytes[1] == 254)
        }
        if let bytes = IPv6Address(name)?.rawValue {
            return (bytes.dropLast().allSatisfy { $0 == 0 } && bytes.last == 1) ||
                bytes[0] & 0xfe == 0xfc || (bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80)
        }
        return false
    }
}
