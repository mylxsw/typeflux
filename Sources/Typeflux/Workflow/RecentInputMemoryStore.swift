import AppKit
import CryptoKit
import Foundation

struct RecentInputMemory: Codable, Identifiable, Equatable {
    let id: UUID
    let appIdentifier: String
    let scope: String
    let text: String
    let recordedAt: Date
}

/// Stores short, observed input excerpts locally. The store never persists a raw transcript.
final class RecentInputMemoryStore: @unchecked Sendable {
    static let shared = RecentInputMemoryStore()
    static let lifetime: TimeInterval = 24 * 60 * 60
    static let maximumPerApp = 20
    static let maximumExcerptLength = 700

    private let lock = NSLock()
    private let fileURL: URL
    private var items: [RecentInputMemory]
    private var generation = 0

    init(fileURL: URL? = nil) {
        let baseDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Typeflux", isDirectory: true)
        self.fileURL = fileURL ?? baseDirectory.appendingPathComponent("recent-input-memory.json")
        items = (try? Data(contentsOf: self.fileURL)).flatMap { try? JSONDecoder().decode([RecentInputMemory].self, from: $0) } ?? []
    }

    func currentGeneration() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return generation
    }

    @discardableResult
    func upsert(
        id: UUID,
        appIdentifier: String,
        scope: String,
        text: String,
        at date: Date = Date(),
        expectedGeneration: Int? = nil
    ) -> Bool {
        let excerpt = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maximumExcerptLength))
        guard !excerpt.isEmpty else { return false }
        lock.lock()
        defer { lock.unlock() }
        if let expectedGeneration, expectedGeneration != generation { return false }
        purgeExpired(at: date)
        items.removeAll { $0.id == id }
        items.append(RecentInputMemory(id: id, appIdentifier: appIdentifier, scope: scope, text: excerpt, recordedAt: date))
        let appItems = items.filter { $0.appIdentifier == appIdentifier }.sorted { $0.recordedAt > $1.recordedAt }
        if appItems.count > Self.maximumPerApp {
            let surplus = Set(appItems.dropFirst(Self.maximumPerApp).map(\.id))
            items.removeAll { surplus.contains($0.id) }
        }
        persist()
        return true
    }

    func recent(scope: String, limit: Int = 4, at date: Date = Date()) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        purgeExpired(at: date)
        return items.filter { $0.scope == scope }
            .sorted { $0.recordedAt > $1.recordedAt }
            .prefix(limit)
            .map(\.text)
    }

    func appIdentifiers(at date: Date = Date()) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        purgeExpired(at: date)
        return Array(Set(items.map(\.appIdentifier))).sorted()
    }

    func list(at date: Date = Date()) -> [RecentInputMemory] {
        lock.lock()
        defer { lock.unlock() }
        purgeExpired(at: date)
        return items.sorted { $0.recordedAt > $1.recordedAt }
    }

    func delete(id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        guard items.contains(where: { $0.id == id }) else { return }
        generation += 1
        items.removeAll { $0.id == id }
        persist()
        GlobalSoulMemoryStore.shared.removeInput(id: id)
    }

    func clear(appIdentifier: String? = nil) {
        lock.lock()
        defer { lock.unlock() }
        generation += 1
        if let appIdentifier {
            items.removeAll { $0.appIdentifier == appIdentifier }
        } else {
            items.removeAll()
        }
        persist()
        GlobalSoulMemoryStore.shared.clearPending(appIdentifier: appIdentifier)
    }

    private func purgeExpired(at date: Date) {
        let count = items.count
        items.removeAll { date.timeIntervalSince($0.recordedAt) >= Self.lifetime }
        if items.count != count { persist() }
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(items).write(to: fileURL, options: .atomic)
        } catch {
            ErrorLogStore.shared.log("Recent input memory save failed: \(error.localizedDescription)")
        }
    }
}

struct RecentInputMemoryScope: Equatable {
    let appIdentifier: String
    let key: String

    static func resolve(bundleIdentifier: String?) -> RecentInputMemoryScope? {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return nil }
        if ["org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition", "org.mozilla.nightly"].contains(bundleIdentifier.lowercased()) {
            return nil
        }
        if let browser = AXTextInjector.browserAutomationKind(for: bundleIdentifier) {
            guard let url = browserURL(bundleIdentifier: browser.bundleIdentifier, command: browser.command),
                  let scope = browserScope(bundleIdentifier: bundleIdentifier, url: url)
            else { return nil }
            return scope
        }
        return RecentInputMemoryScope(appIdentifier: bundleIdentifier, key: bundleIdentifier)
    }

    static func browserScope(bundleIdentifier: String, url: URL) -> RecentInputMemoryScope? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host?.lowercased(),
              ["https", "http"].contains(components.scheme?.lowercased() ?? "")
        else { return nil }
        let pageIdentity = (components.path.isEmpty ? "/" : components.path)
            + (components.query.map { "?\($0)" } ?? "")
        let origin = "\(components.scheme?.lowercased() ?? "https")://\(host):\(components.port ?? 0)"
        let digest = SHA256.hash(data: Data((origin + pageIdentity).utf8))
            .map { String(format: "%02x", $0) }.joined()
        return RecentInputMemoryScope(appIdentifier: bundleIdentifier, key: "\(bundleIdentifier)|\(digest)")
    }

    private static func browserURL(
        bundleIdentifier: String,
        command: AXTextInjector.BrowserAutomationKind.Command
    ) -> URL? {
        let quotedIdentifier = AXTextInjector.appleScriptQuotedString(bundleIdentifier)
        let script: String
        switch command {
        case .chromium:
            script = "tell application id \(quotedIdentifier) to get URL of active tab of front window"
        case .safari:
            script = "tell application id \(quotedIdentifier) to get URL of front document"
        }
        var error: NSDictionary?
        guard let value = NSAppleScript(source: script)?.executeAndReturnError(&error), error == nil,
              let address = value.stringValue else { return nil }
        return URL(string: address)
    }
}
