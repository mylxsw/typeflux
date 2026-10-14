import AppKit
import Carbon

protocol AskBrowserSearching: Sendable {
    /// A fresh in-memory snapshot; never reads files, automates a browser or requests permission.
    func cachedSnapshot(kind: AskBrowserSearchEntry.Kind, browsers: [AskSearchBrowser], interactive: Bool) async
        -> AskBrowserSearchSnapshot?
    func snapshot(kind: AskBrowserSearchEntry.Kind, browsers: [AskSearchBrowser], interactive: Bool) async
        -> AskBrowserSearchSnapshot
    func refreshSnapshot(kind: AskBrowserSearchEntry.Kind, browsers: [AskSearchBrowser], interactive: Bool) async
        -> AskBrowserSearchSnapshot
    func focus(_ target: AskBrowserTabTarget) async throws
}

extension AskBrowserSearching {
    func cachedSnapshot(kind _: AskBrowserSearchEntry.Kind, browsers _: [AskSearchBrowser], interactive _: Bool) async
        -> AskBrowserSearchSnapshot? {
        nil
    }

    func refreshSnapshot(kind: AskBrowserSearchEntry.Kind, browsers: [AskSearchBrowser], interactive: Bool) async
        -> AskBrowserSearchSnapshot {
        await snapshot(kind: kind, browsers: browsers, interactive: interactive)
    }
}

actor AskBrowserSearchService: AskBrowserSearching {
    private struct Cache {
        var date: Date
        var snapshot: AskBrowserSearchSnapshot
    }

    private let runner: any ProcessCommandRunning
    private let backgroundRunner: any ProcessCommandRunning
    private let home: URL
    private let running: @MainActor @Sendable (AskSearchBrowser) -> Bool
    private let authorized: @Sendable (AskSearchBrowser) -> Bool
    private let clock: @Sendable () -> Date
    private var cache: [String: Cache] = [:]
    private var pending: [String: (id: UUID, task: Task<AskBrowserSearchSnapshot, Never>)] = [:]

    init(runner: (any ProcessCommandRunning)? = nil,
         home: URL = FileManager.default.homeDirectoryForCurrentUser,
         running: @escaping @MainActor @Sendable (AskSearchBrowser) -> Bool = {
             !NSRunningApplication.runningApplications(withBundleIdentifier: $0.bundleID).isEmpty
         },
         authorized: @escaping @Sendable (AskSearchBrowser) -> Bool = { browser in
             let target = NSAppleEventDescriptor(bundleIdentifier: browser.bundleID)
             return AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, false) == noErr
         },
         clock: @escaping @Sendable () -> Date = { Date() }) {
        self.runner = runner ?? AskAutomationScriptRunner(timeout: 20, outputLimit: 1_000_000)
        backgroundRunner = runner ?? AskAutomationScriptRunner(timeout: 3, outputLimit: 1_000_000)
        self.home = home
        self.running = running
        self.authorized = authorized
        self.clock = clock
    }

    private func cacheKey(kind: AskBrowserSearchEntry.Kind, browsers: [AskSearchBrowser], interactive: Bool) -> String {
        let selected = AskSearchBrowser.allCases.filter { browsers.contains($0) }
        return kind.rawValue + ":" + selected.map(\.id).joined(separator: ",") + ":" + String(interactive)
    }

    func cachedSnapshot(kind: AskBrowserSearchEntry.Kind, browsers: [AskSearchBrowser], interactive: Bool) async
        -> AskBrowserSearchSnapshot? {
        let key = cacheKey(kind: kind, browsers: browsers, interactive: interactive)
        let lifetime: TimeInterval = kind == .tab ? 2 : 5
        guard let cached = cache[key], clock().timeIntervalSince(cached.date) < lifetime else { return nil }
        return cached.snapshot
    }

    func snapshot(kind: AskBrowserSearchEntry.Kind, browsers: [AskSearchBrowser],
                  interactive: Bool) async -> AskBrowserSearchSnapshot {
        let key = cacheKey(kind: kind, browsers: browsers, interactive: interactive)
        if let cached = await cachedSnapshot(kind: kind, browsers: browsers, interactive: interactive) {
            return cached
        }
        let recent = kind == .tab ? cache[key]
            .flatMap { clock().timeIntervalSince($0.date) < 60 ? $0.snapshot : nil } : nil
        let task = refreshTask(kind: kind, browsers: browsers, interactive: interactive)
        // Keep cached tabs actionable while a bounded refresh updates the next rerun.
        // Focus still checks the live tab identity and URL before switching.
        if let recent {
            return recent
        }
        return await task.value
    }

    func refreshSnapshot(kind: AskBrowserSearchEntry.Kind, browsers: [AskSearchBrowser], interactive: Bool) async
        -> AskBrowserSearchSnapshot {
        await refreshTask(kind: kind, browsers: browsers, interactive: interactive).value
    }

    /// Cache reuse, browser selection and independent source batches share this lifecycle.
    private func refreshTask(kind: AskBrowserSearchEntry.Kind, browsers: [AskSearchBrowser], interactive: Bool)
        -> Task<AskBrowserSearchSnapshot, Never> {
        let key = cacheKey(kind: kind, browsers: browsers, interactive: interactive)
        cache = cache.filter { clock().timeIntervalSince($0.value.date) < ($0.key.hasPrefix("tab:") ? 60 : 5) }
        if let pending = pending[key] {
            return pending.task
        }
        let id = UUID()
        let runner = interactive ? runner : backgroundRunner, home = home, running = running, authorized = authorized
        let task = Task { [weak self] in
            let snapshot = await withTaskGroup(of: (Int, AskBrowserSearchSnapshot).self) { group in
                for (index, browser) in AskSearchBrowser.allCases.filter({ browsers.contains($0) }).enumerated() {
                    group.addTask {
                        if kind == .bookmark {
                            return (index, AskBrowserBookmarks.read(browser, home: home))
                        }
                        guard await running(browser) else { return (index, .init()) }
                        // Background search may only use a grant the user already gave.
                        // The system permission check is synchronous and can wait on TCC;
                        // keep it off the main actor so it cannot freeze the launcher.
                        if !interactive, !authorized(browser) {
                            return (index, .init())
                        }
                        do {
                            let result = try await runner.run(executablePath: "/usr/bin/osascript",
                                                              arguments: [
                                                                  "-l",
                                                                  "JavaScript",
                                                                  "-e",
                                                                  AskBrowserTabScripts.list(browser)
                                                              ],
                                                              environment: nil, currentDirectoryURL: nil)
                            guard result.exitCode == 0 else { throw AskAutomationError.unavailable }
                            return try (index, AskBrowserTabScripts.parse(result.stdout, browser: browser))
                        } catch {
                            return (index, .init(issues: [.init(browser: browser, reason: .automation)]))
                        }
                    }
                }
                var batches: [(Int, AskBrowserSearchSnapshot)] = []
                for await batch in group {
                    batches.append(batch)
                }
                var snapshot = AskBrowserSearchSnapshot()
                for (_, batch) in batches.sorted(by: { $0.0 < $1.0 }) {
                    snapshot.entries += batch.entries
                    snapshot.issues += batch.issues
                }
                return snapshot
            }
            await self?.store(snapshot, key: key, id: id)
            return snapshot
        }
        pending[key] = (id, task)
        return task
    }

    private func store(_ snapshot: AskBrowserSearchSnapshot, key: String, id: UUID) {
        // A focus operation can invalidate a refresh while its browser is replying.
        guard pending[key]?.id == id else { return }
        pending[key] = nil
        if cache.count >= 16 {
            cache.removeAll()
        }
        cache[key] = Cache(date: clock(), snapshot: snapshot)
    }

    func focus(_ target: AskBrowserTabTarget) async throws {
        defer {
            cache = cache.filter { !$0.key.hasPrefix("tab:") }
            for (key, refresh) in pending where key.hasPrefix("tab:") {
                refresh.task.cancel()
                pending[key] = nil
            }
        }
        let result = try await runner.run(executablePath: "/usr/bin/osascript",
                                          arguments: ["-l", "JavaScript", "-e", AskBrowserTabScripts.focus(target)],
                                          environment: nil, currentDirectoryURL: nil)
        guard result.exitCode == 0, result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "focused" else {
            throw AskPluginFailure(message: L("ask.browser.gone"))
        }
    }
}
