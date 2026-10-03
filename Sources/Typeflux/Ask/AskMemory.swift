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

    struct Budget: Codable, Equatable, Sendable {
        var globalScalars: Int
        var appScalars: Int
        var globalLimit = AskMemory.maximumGlobalLength
        var excerptLimit = AskMemory.maximumExcerptLength
        var excerptCountLimit = AskMemory.maximumExcerpts
    }

    // Mirrors the server's limits. Go counts runes, which are Unicode scalars.
    static let maximumGlobalLength = 1000
    static let maximumExcerptLength = 1000
    static let maximumExcerpts = 4
    static let maximumAppIDBytes = 256
    static let maximumAppNameLength = 200

    var global: String?
    var app: App?
    var owner: String?
    var capturedAt: Date?
    var expiry: Date?
    /// Additive wire provenance. Emission remains opt-in until API/client acceptance.
    var sources: [MemoryProvenance]?
    var budget: Budget?

    func usable(owner: String? = nil, at date: Date = Date(),
                invalidations: MemoryInvalidationStore = .shared) -> AskMemory? {
        guard !isEmpty, expiry.map({ $0 > date }) ?? true,
              sources?.allSatisfy({ $0.expiry.map { $0 > date } ?? true }) ?? true else { return nil }
        let account = owner ?? self.owner
        if let account, !invalidations.permits(self, owner: account) {
            return nil
        }
        return self
    }

    /// Remove only the generated memory system message, preserving conversation history.
    static func removingInjection(from payload: String) -> String {
        guard var object = (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any],
              let messages = object["messages"] as? [[String: Any]] else { return payload }
        object["messages"] = messages.filter {
            !(($0["role"] as? String) == "system" && ($0["content"] as? String)?.hasPrefix("<user_memory>\n") == true)
        }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        else { return payload }
        return String(data: data, encoding: .utf8) ?? payload
    }

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
    private let structuredMemoryEnabled: Bool
    private let settings: SettingsStore
    private let soulStore: GlobalSoulMemoryStore
    private let recentStore: RecentInputMemoryStore
    private let noteStore: AskMemoryNoteStore
    private let ownerID: @MainActor () -> String
    private let ownBundleIdentifier: String?
    private let resolveScope: (String) -> RecentInputMemoryScope?

    init(
        settings: SettingsStore,
        structuredMemoryEnabled: Bool? = nil,
        soulStore: GlobalSoulMemoryStore = .shared,
        recentStore: RecentInputMemoryStore = .shared,
        noteStore: AskMemoryNoteStore = .shared,
        ownerID: @escaping @MainActor () -> String = { GlobalSoulOwner.currentID },
        ownBundleIdentifier: String? = Bundle.main.bundleIdentifier,
        resolveScope: @escaping (String) -> RecentInputMemoryScope? = {
            RecentInputMemoryScope.resolve(bundleIdentifier: $0)
        }
    ) {
        self.settings = settings
        self.structuredMemoryEnabled = structuredMemoryEnabled ?? MemoryRollout.enabled(settings.defaults)
        self.soulStore = soulStore
        self.recentStore = recentStore
        self.noteStore = noteStore
        self.ownerID = ownerID
        self.ownBundleIdentifier = ownBundleIdentifier
        self.resolveScope = resolveScope
    }

    func memory(bundleIdentifier: String?, appName: String?) -> AskMemory? {
        let owner = ownerID()
        var result = AskMemory(owner: owner, capturedAt: Date())
        var sources: [MemoryProvenance] = []
        // Explicit corrections and notes have first claim on the global budget.
        let notes = noteStore.list(owner: owner)
        var global = AskMemoryNoteStore.memoryText(notes, limit: AskMemory.maximumGlobalLength) ?? ""
        sources += AskMemoryNoteStore.injectionNotes(notes, limit: AskMemory.maximumGlobalLength)
            .compactMap(\.provenance)
        if settings.globalSoulMemoryEnabled, let soul = soulStore.soul(ownerID: owner) {
            let room = AskMemory.maximumGlobalLength - global.unicodeScalars.count - (global.isEmpty ? 0 : 2)
            let text = AskMemory.clipped(soul.text, to: max(0, room))
            if !text.isEmpty {
                global += (global.isEmpty ? "" : "\n\n") + text
                if let source = soul.provenance {
                    sources.append(source)
                }
            }
        }
        if !global.isEmpty {
            result.global = global
        }
        result.app = appMemory(bundleIdentifier: bundleIdentifier, appName: appName, sources: &sources)
        result.expiry = sources.compactMap(\.expiry).min()
        if structuredMemoryEnabled {
            result.sources = sources
            result.budget = .init(globalScalars: global.unicodeScalars.count,
                                  appScalars: result.app?.excerpts.reduce(0) { $0 + $1.unicodeScalars.count } ?? 0)
        }
        return result.isEmpty ? nil : result
    }

    private func appMemory(bundleIdentifier: String?, appName: String?, sources: inout [MemoryProvenance]) -> AskMemory
        .App? {
        // Check the switches before resolving: browser scopes read the page URL via Apple Events.
        guard let bundleIdentifier, !bundleIdentifier.isEmpty,
              bundleIdentifier.utf8.count <= AskMemory.maximumAppIDBytes,
              bundleIdentifier != ownBundleIdentifier,
              settings.recentInputMemoryAllowed(for: bundleIdentifier),
              let scope = resolveScope(bundleIdentifier),
              settings.recentInputMemoryAllowed(for: scope.appIdentifier)
        else { return nil }
        let items = recentStore.list(owner: ownerID()).filter { $0.scope == scope.key }
            .prefix(AskMemory.maximumExcerpts)
        sources += items.compactMap(\.provenance)
        let excerpts = items
            .map { AskMemory.clipped($0.text, to: AskMemory.maximumExcerptLength) }
            .filter { !$0.isEmpty }
        guard !excerpts.isEmpty else { return nil }
        let name = appName.map { AskMemory.clipped($0, to: AskMemory.maximumAppNameLength) }
        return AskMemory.App(id: scope.appIdentifier, name: name?.isEmpty == false ? name : nil, excerpts: excerpts)
    }
}
