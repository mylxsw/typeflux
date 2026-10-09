import AppKit
import Foundation

/// Where the file index stands, for the launcher's notice and the settings page.
struct AskFileIndexStatus: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case off
        /// Reading the saved index.
        case loading
        /// Scanning the search folders; `estimate` is the last index's size, when known.
        case building(found: Int, estimate: Int?)
        case ready
    }

    var phase: Phase = .off
    var count = 0
    var bytes = 0
    var updatedAt: Date?
    /// Folders in the search folders left out until Typeflux has Full Disk Access.
    var blocked: [String] = []
    /// The index stopped at `AskFileCrawler.maximumEntries`.
    var truncated = false
    var timedOut = 0
    var failed = 0
    var nonLocalMounts = 0

    var incomplete: Bool { timedOut + failed > 0 }

    var isBuilding: Bool { if case .building = phase { true } else { false } }

    /// 0…1 while building with a known size; nil otherwise.
    var progress: Double? {
        guard case let .building(found, estimate?) = phase, estimate > 0 else { return nil }
        return min(0.99, Double(found) / Double(estimate))
    }
}

/// What the launcher needs from the file index. Tests supply their own.
protocol AskFileSearching: AnyObject, Sendable {
    func search(_ query: AskSearchQuery, options: AskFileSearchOptions) -> [AskFileHit]
    func recent(options: AskFileSearchOptions) -> [AskFileHit]
    var status: AskFileIndexStatus { get }
    /// How often each path was opened from the launcher.
    var usage: [String: Int] { get }
    /// Starts (or follows a settings change); cheap to call whenever the launcher opens.
    func start()
    /// Remembers a file opened from the launcher, to rank it higher.
    func recordOpen(_ path: String)
    /// Forgets an entry that turned out to be gone.
    func forget(_ path: String)
    /// Builds the index again from scratch.
    func rebuild()
    /// Stops, frees the memory and deletes the saved index.
    func clear()
}

/// The names of the files in the search folders, kept in memory and up to date.
/// See `docs/design/launcher-content-search.md` §3. One serial queue owns the
/// index and changes it; searches read the last published copy without waiting.
final class AskFileIndex: AskFileSearching, @unchecked Sendable {
    /// Off inside test runs: a test must never scan the Mac it runs on. Tests inject their own index.
    static let shared = AskFileIndex(configuration: isTesting ? { (false, AskLauncherSearchSettings()) } : storedConfiguration)

    static var isTesting: Bool {
        NSClassFromString("XCTest.XCTestCase") != nil || NSClassFromString("XCTestCase") != nil
    }
    static let didChange = Notification.Name("AskFileIndex.didChange")
    private static let usageKey = "ask.quickResults.fileOpens"
    static let maximumUsage = 2000
    /// The building index is published this often, so results appear while it grows.
    static let publishEvery = 20000

    private let configuration: () -> (enabled: Bool, settings: AskLauncherSearchSettings)
    private let fullDiskAccess: () -> Bool
    private let snapshotURL: URL
    private let defaults: UserDefaults
    private let makeWatcher: () -> AskFileWatching
    private let home: String

    private let preparation = DispatchQueue(label: "typeflux.ask.files.prepare", qos: .utility)
    private let makeReader: () -> AskFileReading
    private var reader: AskFileReading
    private let queue = DispatchQueue(label: "typeflux.ask.files.index", qos: .utility)
    private let lock = NSLock()
    private var published: AskFileIndexState
    private var currentStatus = AskFileIndexStatus()
    private var usageCounts: [String: Int]
    /// What the queue is working towards; nil when off. Changing it cancels a scan under way.
    private var target: String?
    private var generation = 0
    private var preparationGeneration = 0

    // Owned by `queue`.
    private var working: AskFileIndexState
    private var scope: AskFileScope?
    private var fingerprint: String?
    private var watcher: AskFileWatching?
    private var lastEventID: UInt64 = 0
    private var dirty = false
    private var saveScheduled = false
    private var skippedMounts = Set<String>()
    private var observers: [NSObjectProtocol] = []

    init(configuration: @escaping () -> (enabled: Bool, settings: AskLauncherSearchSettings) = AskFileIndex.storedConfiguration,
         fullDiskAccess: @escaping () -> Bool = { AskFullDiskAccess.isGranted() },
         snapshotURL: URL = AskFileIndex.defaultSnapshotURL, defaults: UserDefaults = .standard,
         home: String = NSHomeDirectory(), makeReader: @escaping () -> AskFileReading = { AskFileReader() },
         makeWatcher: @escaping () -> AskFileWatching = { AskFSEventsWatcher() }) {
        self.configuration = configuration
        self.fullDiskAccess = fullDiskAccess
        self.snapshotURL = snapshotURL
        self.defaults = defaults
        self.home = home
        self.makeWatcher = makeWatcher
        self.makeReader = makeReader
        reader = makeReader()
        published = AskFileIndexState(home: home)
        working = AskFileIndexState(home: home)
        usageCounts = defaults.dictionary(forKey: Self.usageKey) as? [String: Int] ?? [:]
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    static func storedConfiguration() -> (enabled: Bool, settings: AskLauncherSearchSettings) {
        let store = SettingsStore()
        return (store.askQuickFileSearchEnabled, store.askLauncherSearchSettings)
    }

    static var defaultSnapshotURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("Typeflux", isDirectory: true).appendingPathComponent("file-index.bin")
    }

}

extension AskFileIndex {
    // MARK: - Reading

    func search(_ query: AskSearchQuery, options: AskFileSearchOptions) -> [AskFileHit] {
        let (state, usage) = lock.withLock { (published, usageCounts) }
        var options = options
        options.usage = usage
        return state.search(query, options: options)
    }

    func recent(options: AskFileSearchOptions) -> [AskFileHit] {
        lock.withLock { published }.recent(options: options)
    }

    var status: AskFileIndexStatus { lock.withLock { currentStatus } }
    var usage: [String: Int] { lock.withLock { usageCounts } }

    func recordOpen(_ path: String) {
        let snapshot = lock.withLock { () -> [String: Int] in
            usageCounts[path, default: 0] += 1
            if usageCounts.count > Self.maximumUsage,
               let least = usageCounts.filter({ $0.key != path }).min(by: { $0.value < $1.value })?.key {
                usageCounts[least] = nil
            }
            return usageCounts
        }
        defaults.set(snapshot, forKey: Self.usageKey)
    }

    // MARK: - Lifecycle

    func start() {
        let (enabled, settings) = configuration()
        let requested = lock.withLock { preparationGeneration += 1; return preparationGeneration }
        preparation.async { [weak self] in
            guard let self, self.lock.withLock({ self.preparationGeneration == requested }) else { return }
            let access = enabled && self.fullDiskAccess()
            let fingerprint = enabled && !settings.fileRoots.isEmpty ? Self.fingerprint(settings, access: access) : nil
            let run = self.lock.withLock { () -> Int? in
                guard self.preparationGeneration == requested,
                      fingerprint != self.target || (fingerprint == nil && self.currentStatus.phase != .off) else { return nil }
                self.target = fingerprint
                self.generation += 1
                return self.generation
            }
            if let run {
                self.queue.async {
                    if let fingerprint { self.follow(settings: settings, access: access, fingerprint: fingerprint, run: run) }
                    else { self.turnOff() }
                }
            }
        }
        lock.withLock {
            guard observers.isEmpty else { return }
            let center = NotificationCenter.default
            observers = [
                center.addObserver(forName: .askLauncherSearchSettingsDidChange, object: nil, queue: nil) { [weak self] _ in
                    self?.start()
                },
                center.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { [weak self] _ in
                    self?.saveBeforeQuitting()
                }
            ]
        }
    }

    func rebuild() {
        let (enabled, settings) = configuration()
        guard enabled else { return }
        let run = lock.withLock { preparationGeneration += 1; generation += 1; return generation }
        preparation.async { [weak self] in
            guard let self, self.isCurrent(run) else { return }
            let access = self.fullDiskAccess()
            let fingerprint = Self.fingerprint(settings, access: access)
            guard self.lock.withLock({ () -> Bool in
                guard self.generation == run else { return false }
                self.target = fingerprint
                return true
            }) else { return }
            self.queue.async {
                guard self.isCurrent(run) else { return }
                self.reader = self.makeReader()
                self.fingerprint = fingerprint
                let scope = AskFileScope(settings: settings, fullDiskAccess: access, home: self.home).resolved(using: self.reader)
                self.build(scope: scope, run: run)
            }
        }
    }

    static func fingerprint(_ settings: AskLauncherSearchSettings, access: Bool) -> String {
        settings.fileIndexFingerprint + "\u{3}" + (access ? "all" : "guarded") + "\u{3}policy-3"
    }

    func clear() {
        lock.withLock {
            target = nil
            preparationGeneration += 1
            generation += 1
        }
        queue.async { [weak self] in self?.turnOff() }
    }

    private func isCurrent(_ run: Int) -> Bool { lock.withLock { generation == run } }

    func forget(_ path: String) {
        queue.async { [weak self] in
            guard let self, working.remove(path) else { return }
            publish(phase: .ready)
            markDirty()
        }
    }

    /// Quitting stops a scan under way (it starts over next time) and saves what changed.
    func saveBeforeQuitting() {
        lock.withLock { preparationGeneration += 1; generation += 1 }
        queue.async { [self] in
            watcher?.stop()
            reader = makeReader()
            if lock.withLock({ currentStatus.phase }) == .ready { saveNow() }
        }
    }

    /// Waits until the queue has done everything asked of it so far; for tests.
    func waitUntilIdle() {
        preparation.sync {}
        queue.sync {}
    }

    /// Brings the index in line with the settings: off, already right, loaded from disk, or built.
    private func follow(settings: AskLauncherSearchSettings, access: Bool, fingerprint: String, run: Int) {
        guard isCurrent(run), fingerprint != self.fingerprint else { return }
        reader = makeReader()
        let scope = AskFileScope(settings: settings, fullDiskAccess: access, home: home).resolved(using: reader)
        self.fingerprint = fingerprint
        self.scope = scope
        publish(phase: .loading)
        if let data = try? Data(contentsOf: snapshotURL), let contents = AskFileSnapshot.decode(data),
           contents.fingerprint == fingerprint, contents.state.home == home {
            working = contents.state
            lastEventID = contents.eventID
            publish(phase: .ready, updatedAt: modificationDate(of: snapshotURL))
            watch(since: contents.eventID, run: run)
            return
        }
        build(scope: scope, run: run)
    }

    private func turnOff() {
        watcher?.stop()
        watcher = nil
        fingerprint = nil
        scope = nil
        reader = makeReader()
        working = AskFileIndexState(home: home)
        dirty = false
        try? FileManager.default.removeItem(at: snapshotURL)
        publish(phase: .off)
    }

    /// Scans every search folder into a fresh index, publishing as it grows.
    private func build(scope: AskFileScope, run: Int) {
        guard isCurrent(run) else { return }
        watcher?.stop()
        let count = status.count
        let estimate = count > 0 ? count : nil
        skippedMounts.removeAll()
        lock.withLock { currentStatus.timedOut = 0; currentStatus.failed = 0; currentStatus.nonLocalMounts = 0 }
        var lastPublish = ProcessInfo.processInfo.systemUptime
        let startEvent = AskFSEventsWatcher.currentEventID
        working = AskFileIndexState(home: home)
        self.scope = scope
        publish(phase: .building(found: 0, estimate: estimate))
        var truncated = false
        // Outer folders first, so a folder added inside another hangs under it when the outer scan reached it.
        for root in scope.roots.reversed() {
            guard scope.includes(root, isDirectory: true) else { continue }
            insertRoot(root)
            AskFileCrawler.crawl(root, scope: scope, limit: AskFileCrawler.maximumEntries - working.count,
                                 reader: reader, isCancelled: { [weak self] in self?.isCurrent(run) != true },
                                 skipped: recordSkip) { entry in
                insert(entry)
                let now = ProcessInfo.processInfo.systemUptime
                if working.count % Self.publishEvery == 0 || now - lastPublish >= 0.25 {
                    lastPublish = now
                    publish(phase: .building(found: working.count, estimate: estimate))
                }
                return true
            }
            if working.count >= AskFileCrawler.maximumEntries { truncated = true; break }
        }
        guard isCurrent(run) else { return }
        lastEventID = startEvent
        lock.withLock { currentStatus.truncated = truncated }
        publish(phase: .ready, updatedAt: Date())
        saveNow(force: true)
        watch(since: startEvent, run: run)
    }

    private func watch(since eventID: UInt64, run: Int) {
        guard let scope else { return }
        watcher?.stop()
        let watcher = makeWatcher()
        self.watcher = watcher
        let mounts = AskFileMounts.current()
        watcher.start(paths: scope.roots.filter { scope.includes($0, isDirectory: true) && mounts.blocking($0) == nil }, since: eventID) { [weak self] changes, last in
            self?.queue.async {
                guard let self, self.isCurrent(run) else { return }
                self.apply(changes)
                if last > self.lastEventID { self.lastEventID = last }
            }
        }
    }

    // MARK: - Changes

    /// Brings the index up to date with what the file system reported.
    func apply(_ changes: [AskFileChange]) {
        guard let scope, !changes.isEmpty else { return }
        // Each event batch starts with a fresh worker; earlier directory failures do not carry over.
        reader = makeReader()
        var changed = false
        var seen = Set<String>()
        for change in changes where seen.insert(change.path).inserted {
            var path = change.path
            while path.count > 1, path.hasSuffix("/") { path.removeLast() }
            guard scope.includes(path, isDirectory: false) || scope.includes(path, isDirectory: true) else { continue }
            do {
                let entry = try AskFileCrawler.metadata(at: path, scope: scope, reader: reader)
                if scope.roots.contains(path) {
                    guard change.rescan || entry == nil else { continue }
                    changed = working.remove(path) || changed
                    for root in scope.roots.reversed() where AskFileScope.isInside(root, path) {
                        guard scope.includes(root, isDirectory: true),
                              try AskFileCrawler.metadata(at: root, scope: scope, reader: reader) != nil else { continue }
                        insertRoot(root)
                        AskFileCrawler.crawl(root, scope: scope, reader: reader, skipped: recordSkip) { entry in
                            insert(entry)
                            return true
                        }
                        changed = true
                    }
                } else if change.rescan {
                    changed = working.remove(path) || changed
                    if let entry { changed = insertTree(entry, scope: scope) || changed }
                } else if let entry {
                    if let existing = working.record(at: path) { working.touch(existing, modified: entry.modified); changed = true }
                    else { changed = insertTree(entry, scope: scope) || changed }
                } else { changed = working.remove(path) || changed }
            } catch AskFileReadError.timeout { recordSkip(path, .timeout) }
            catch AskFileReadError.nonLocalMount { recordSkip(path, .nonLocalMount) }
            catch { recordSkip(path, .failed) }

        }
        guard changed else { return }
        if working.needsCompaction { working = working.compacted() }
        publish(phase: .ready, updatedAt: Date())
        markDirty()
    }

    /// Adds an entry found by an event, and everything in it when it is a folder moved in whole.
    private func insertTree(_ entry: AskFileCrawler.Entry, scope: AskFileScope) -> Bool {
        guard ensureParent(of: entry.path, scope: scope) else { return false }
        insert(entry)
        if entry.kind == .folder {
            AskFileCrawler.crawl(entry.path, scope: scope, reader: reader, skipped: recordSkip) { child in
                if working.record(at: child.path) == nil { insert(child) }
                return true
            }
        }
        return true
    }

    /// Makes sure the folder holding `path` is in the index, adding missing folders above it.
    private func ensureParent(of path: String, scope: AskFileScope) -> Bool {
        let parent = (path as NSString).deletingLastPathComponent
        if working.directoryIndex[parent] != nil { return true }
        if scope.roots.contains(parent) { insertRoot(parent); return true }
        guard scope.root(of: parent) != nil, let entry = AskFileCrawler.entry(at: parent, scope: scope, reader: reader),
              entry.kind == .folder, ensureParent(of: parent, scope: scope) else { return false }
        insert(entry)
        return true
    }

    private func insertRoot(_ root: String) {
        working.directory(root)
    }

    private func insert(_ entry: AskFileCrawler.Entry) {
        let parent = (entry.path as NSString).deletingLastPathComponent
        guard let directory = working.directoryIndex[parent] else { return }
        let name = (entry.path as NSString).lastPathComponent
        let index = working.add(name: name, directory: directory, kind: entry.kind, modified: entry.modified)
        if entry.kind == .folder { working.directory(entry.path, parent: directory, record: index) }
    }

    // MARK: - Publishing and saving

    private func publish(phase: AskFileIndexStatus.Phase, updatedAt: Date? = nil) {
        let state = working
        let blocked = scope?.blockedInScope ?? []
        let bytes = Self.bytes(of: state)
        lock.withLock {
            published = state
            currentStatus.phase = phase
            currentStatus.count = state.count
            currentStatus.bytes = bytes
            currentStatus.blocked = blocked
            if let updatedAt { currentStatus.updatedAt = updatedAt }
            if phase == .off { currentStatus = AskFileIndexStatus() }
        }
        DispatchQueue.main.async { NotificationCenter.default.post(name: Self.didChange, object: self) }
    }

    static func bytes(of state: AskFileIndexState) -> Int {
        state.records.count * MemoryLayout<AskFileRecord>.stride + state.keys.count + state.starts.count
            + state.names.count + state.directories.reduce(0) { $0 + 48 + $1.path.utf8.count + $1.key.count }
    }

    private func recordSkip(_ path: String, _ reason: AskFileCrawler.SkipReason) {
        if reason == .nonLocalMount, !skippedMounts.insert(path).inserted { return }
        lock.withLock {
            switch reason {
            case .timeout: currentStatus.timedOut += 1
            case .failed: currentStatus.failed += 1
            case .nonLocalMount: currentStatus.nonLocalMounts += 1
            }
        }
        publish(phase: status.phase)
    }

    private func markDirty() {
        dirty = true
        guard !saveScheduled else { return }
        saveScheduled = true
        queue.asyncAfter(deadline: .now() + 600) { [weak self] in
            self?.saveScheduled = false
            self?.saveNow()
        }
    }

    private func saveNow(force: Bool = false) {
        guard let fingerprint, force || dirty else { return }
        dirty = false
        // A partial snapshot remains useful on disk, but is rebuilt on the next launch.
        let savedFingerprint = fingerprint + (status.incomplete ? "\u{3}partial" : "")
        let data = AskFileSnapshot.encode(working, fingerprint: savedFingerprint, eventID: lastEventID)
        try? FileManager.default.createDirectory(at: snapshotURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: snapshotURL, options: .atomic)
    }

    private func modificationDate(of url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
}
