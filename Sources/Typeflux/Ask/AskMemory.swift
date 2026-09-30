import Foundation

extension Notification.Name {
    /// Posted after the user clears or disables local memory, so Ask can drop
    /// captured copies and remove the copies pinned to server conversations.
    static let askMemoryDidClear = Notification.Name("AskMemory.didClear")
}

/// Device memory sent with the opening message of an Ask conversation. The
/// server pins it to the conversation; follow-ups never send it again.
struct AskMemory: Codable, Equatable, Sendable {
    struct App: Codable, Equatable, Sendable {
        var id: String
        var name: String?
        var excerpts: [String]
    }

    // Mirrors the server's limits. Go counts runes, which are Unicode scalars.
    static let maximumGlobalLength = 1000
    static let maximumExcerptLength = 1000
    static let maximumExcerpts = 4
    static let maximumAppIDBytes = 256
    static let maximumAppNameLength = 200

    var global: String?
    var app: App?

    /// An empty value means memory was resolved and is unavailable or removed by the user.
    var isEmpty: Bool {
        (global ?? "").isEmpty && (app?.excerpts.isEmpty ?? true)
    }

    var chipTitle: String {
        guard let app, !app.excerpts.isEmpty else { return L("ask.memory") }
        return L("ask.memory.app", app.name ?? app.id)
    }

    static func clipped(_ text: String, to limit: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.unicodeScalars.count > limit else { return trimmed }
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: trimmed.unicodeScalars.prefix(limit))
        return String(scalars)
    }
}

@MainActor
protocol AskMemoryProviding {
    /// Global memory is always included when enabled. Application memory is
    /// included only when `bundleIdentifier` resolves to an allowed scope.
    func memory(bundleIdentifier: String?, appName: String?) -> AskMemory?
}

/// Reads the same stores, switches and exclusions as dictation memory.
@MainActor
struct AskMemoryProvider: AskMemoryProviding {
    private let settings: SettingsStore
    private let soulStore: GlobalSoulMemoryStore
    private let recentStore: RecentInputMemoryStore
    private let ownerID: @MainActor () -> String
    private let ownBundleIdentifier: String?
    private let resolveScope: (String) -> RecentInputMemoryScope?

    init(
        settings: SettingsStore,
        soulStore: GlobalSoulMemoryStore = .shared,
        recentStore: RecentInputMemoryStore = .shared,
        ownerID: @escaping @MainActor () -> String = { GlobalSoulOwner.currentID },
        ownBundleIdentifier: String? = Bundle.main.bundleIdentifier,
        resolveScope: @escaping (String) -> RecentInputMemoryScope? = {
            RecentInputMemoryScope.resolve(bundleIdentifier: $0)
        }
    ) {
        self.settings = settings
        self.soulStore = soulStore
        self.recentStore = recentStore
        self.ownerID = ownerID
        self.ownBundleIdentifier = ownBundleIdentifier
        self.resolveScope = resolveScope
    }

    func memory(bundleIdentifier: String?, appName: String?) -> AskMemory? {
        var result = AskMemory()
        if settings.globalSoulMemoryEnabled, let soul = soulStore.soul(ownerID: ownerID())?.text {
            let text = AskMemory.clipped(soul, to: AskMemory.maximumGlobalLength)
            if !text.isEmpty { result.global = text }
        }
        result.app = appMemory(bundleIdentifier: bundleIdentifier, appName: appName)
        return result.isEmpty ? nil : result
    }

    private func appMemory(bundleIdentifier: String?, appName: String?) -> AskMemory.App? {
        // Check the switches before resolving: browser scopes read the page URL via Apple Events.
        guard let bundleIdentifier, !bundleIdentifier.isEmpty,
              bundleIdentifier.utf8.count <= AskMemory.maximumAppIDBytes,
              bundleIdentifier != ownBundleIdentifier,
              settings.recentInputMemoryAllowed(for: bundleIdentifier),
              let scope = resolveScope(bundleIdentifier),
              settings.recentInputMemoryAllowed(for: scope.appIdentifier)
        else { return nil }
        let excerpts = recentStore.recent(scope: scope.key, limit: AskMemory.maximumExcerpts)
            .map { AskMemory.clipped($0, to: AskMemory.maximumExcerptLength) }
            .filter { !$0.isEmpty }
        guard !excerpts.isEmpty else { return nil }
        let name = appName.map { AskMemory.clipped($0, to: AskMemory.maximumAppNameLength) }
        return AskMemory.App(id: scope.appIdentifier, name: name?.isEmpty == false ? name : nil, excerpts: excerpts)
    }
}
