import SwiftUI
import TypefluxChat

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
    static let endpoint = resolve(Bundle.main.object(forInfoDictionaryKey: "TYPEFLUX_API_URL") as? String)

    static func resolve(_ configured: String?) -> URL {
        // Match the primary macOS AppServerConfiguration endpoint. Endpoint changes
        // are build-time only and have separate Keychain namespaces.
        let fallback = URL(string: "https://api.typeflux.app")!
        guard let configured, let url = URL(string: configured), url.scheme == "https",
              url.host != nil, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil else { return fallback }
        return url
    }
}
