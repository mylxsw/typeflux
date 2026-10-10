import AppKit
import Carbon

protocol AskBrowserSearching: Sendable {
    func snapshot(kind: AskBrowserSearchEntry.Kind, browsers: [AskSearchBrowser], interactive: Bool) async
        -> AskBrowserSearchSnapshot
    func focus(_ target: AskBrowserTabTarget) async throws
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
    private var cache: [String: Cache] = [:]
    private var pending: [String: Task<AskBrowserSearchSnapshot, Never>] = [:]

    init(runner: (any ProcessCommandRunning)? = nil,
         home: URL = FileManager.default.homeDirectoryForCurrentUser,
         running: @escaping @MainActor @Sendable (AskSearchBrowser) -> Bool = {
             !NSRunningApplication.runningApplications(withBundleIdentifier: $0.bundleID).isEmpty
         },
         authorized: @escaping @Sendable (AskSearchBrowser) -> Bool = { browser in
             let target = NSAppleEventDescriptor(bundleIdentifier: browser.bundleID)
             return AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, false) == noErr
         }) {
        self.runner = runner ?? AskAutomationScriptRunner(timeout: 20, outputLimit: 1_000_000)
        backgroundRunner = runner ?? AskAutomationScriptRunner(timeout: 3, outputLimit: 1_000_000)
        self.home = home
        self.running = running
        self.authorized = authorized
    }

    // Cache reuse, browser selection and independent source batches share this lifecycle.
    // swiftlint:disable:next cyclomatic_complexity
    func snapshot(kind: AskBrowserSearchEntry.Kind, browsers: [AskSearchBrowser],
                  interactive: Bool) async -> AskBrowserSearchSnapshot {
        let selected = AskSearchBrowser.allCases.filter { browsers.contains($0) }
        let key = kind.rawValue + ":" + selected.map(\.id).joined(separator: ",") + ":" + String(interactive)
        let lifetime: TimeInterval = kind == .tab ? 2 : 5
        cache = cache.filter { Date().timeIntervalSince($0.value.date) < 5 }
        if cache.count > 8 { cache.removeAll() }
        if let cached = cache[key], Date().timeIntervalSince(cached.date) < lifetime { return cached.snapshot }
        if let task = pending[key] { return await task.value }
        let runner = interactive ? runner : backgroundRunner, home = home, running = running, authorized = authorized
        let task = Task {
            await withTaskGroup(of: (Int, AskBrowserSearchSnapshot).self) { group in
                for (index, browser) in selected.enumerated() {
                    group.addTask {
                        if kind == .bookmark { return (index, AskBrowserBookmarks.read(browser, home: home)) }
                        guard await running(browser) else { return (index, .init()) }
                        // Background search may only use a grant the user already gave.
                        // The system permission check is synchronous and can wait on TCC;
                        // keep it off the main actor so it cannot freeze the launcher.
                        if !interactive, !authorized(browser) { return (index, .init()) }
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
        }
        pending[key] = task
        let snapshot = await task.value
        pending[key] = nil
        cache[key] = Cache(date: Date(), snapshot: snapshot)
        return snapshot
    }

    func focus(_ target: AskBrowserTabTarget) async throws {
        defer { cache = cache.filter { !$0.key.hasPrefix("tab:") } }
        let result = try await runner.run(executablePath: "/usr/bin/osascript",
                                          arguments: ["-l", "JavaScript", "-e", AskBrowserTabScripts.focus(target)],
                                          environment: nil, currentDirectoryURL: nil)
        guard result.exitCode == 0, result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "focused" else {
            throw AskPluginFailure(message: L("ask.browser.gone"))
        }
    }
}
