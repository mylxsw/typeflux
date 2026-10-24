import Foundation

/// Queries the system's existing text index without opening documents or building another index.
@MainActor
final class AskSpotlightSearch {
    struct Item: Sendable {
        var path: String
        var modified: Date
    }

    typealias Lookup = @MainActor @Sendable (NSPredicate, [String], Int) async -> [Item]
    private let lookup: Lookup

    init(lookup: @escaping Lookup = { predicate, roots, limit in
        guard !AskFileIndex.isTesting else { return [] }
        // Filename matches remain immediate; short typing bursts need only one system query.
        do { try await Task.sleep(for: .milliseconds(75)) } catch { return [] }
        return await Session(predicate: predicate, roots: roots, limit: limit).run()
    }) {
        self.lookup = lookup
    }

    func search(_ text: String, type: AskFileType, limit: Int, scope: AskFileScope) async -> [AskFileHit] {
        guard limit > 0, type != .folder, !scope.roots.isEmpty,
              let content = SemanticFilePolicy.query(text, type: type), !Task.isCancelled else { return [] }
        let query = AskSearchQuery(text)
        let words = content.split(whereSeparator: \.isWhitespace).map(String.init)
        let clauses = words.map {
            NSPredicate(format: "%K CONTAINS[cd] %@", "kMDItemTextContent", $0)
        }
        guard let first = clauses.first else { return [] }
        // NSMetadataQuery throws an Objective-C exception for a one-child AND.
        // Pass a single comparison directly; only combine multiple search terms.
        let predicate = clauses.count == 1 ? first : NSCompoundPredicate(andPredicateWithSubpredicates: clauses)
        // Filtering happens locally too: Spotlight can return hidden or excluded descendants.
        let items = await lookup(predicate, scope.roots, min(512, max(1, min(limit, 128)) * 4))
        guard !Task.isCancelled else { return [] }
        var seen = Set<String>()
        return Array(items.compactMap { item -> AskFileHit? in
            let path = item.path
            let ext = (path as NSString).pathExtension.lowercased()
            guard path.hasPrefix("/"), AskFileScope.normalize(path) == path,
                  scope.includes(path, isDirectory: false),
                  type.matches(kind: .file, extension: ext),
                  query.fileExtension.map({ $0 == ext }) ?? true,
                  query.folder.map({ folder in
                      String(decoding: AskSearchText.normalize((path as NSString).deletingLastPathComponent), as: UTF8.self)
                          .contains(String(decoding: folder, as: UTF8.self))
                  }) ?? true,
                  seen.insert(path).inserted else { return nil }
            return AskFileHit(path: path, name: (path as NSString).lastPathComponent, kind: .file,
                              modified: item.modified, score: 0.5,
                              evidence: .init(text: "", segmentKind: "spotlight"))
        }.prefix(limit))
    }

    /// Each keystroke owns a query. Cancellation/timeout stop it and release its observers.
    @MainActor final class Session {
        private let query: NSMetadataQuery
        private let timeout: Duration
        private var observers: [NSObjectProtocol] = []
        private var deadline: Task<Void, Never>?
        private var continuation: CheckedContinuation<[Item], Never>?
        private let limit: Int

        init(predicate: NSPredicate, roots: [String], limit: Int, timeout: Duration = .milliseconds(500),
             query: NSMetadataQuery = NSMetadataQuery()) {
            self.query = query; self.limit = limit; self.timeout = timeout
            query.predicate = predicate
            query.searchScopes = roots
            query.notificationBatchingInterval = 0.05
        }

        func run() async -> [Item] {
            guard !Task.isCancelled else { return [] }
            return await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    self.continuation = continuation
                    for notification in [NSNotification.Name.NSMetadataQueryDidFinishGathering,
                                         NSNotification.Name.NSMetadataQueryGatheringProgress] {
                        observers.append(NotificationCenter.default.addObserver(forName: notification,
                            object: query, queue: .main) { [weak self] notification in
                            MainActor.assumeIsolated {
                                guard let self else { return }
                                if notification.name == .NSMetadataQueryDidFinishGathering
                                    || self.query.resultCount >= self.limit { self.finish() }
                            }
                        })
                    }
                    guard query.start() else { finish(); return }
                    guard self.continuation != nil else { return }
                    deadline = Task { [weak self, timeout] in
                        do { try await Task.sleep(for: timeout) } catch { return }
                        self?.finish()
                    }
                }
            } onCancel: {
                Task { @MainActor in self.finish(cancelled: true) }
            }
        }

        private func finish(cancelled: Bool = false) {
            guard let continuation else { return }
            self.continuation = nil
            query.disableUpdates()
            let items: [Item] = cancelled ? [] : (0 ..< min(limit, query.resultCount)).compactMap { index in
                guard let item = query.result(at: index) as? NSMetadataItem,
                      let path = item.value(forAttribute: NSMetadataItemPathKey) as? String else { return nil }
                return Item(path: path,
                            modified: item.value(forAttribute: NSMetadataItemFSContentChangeDateKey) as? Date ?? .distantPast)
            }
            query.stop()
            deadline?.cancel(); deadline = nil
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
            continuation.resume(returning: items)
        }
    }
}

/// Shares the ordinary file-search scope. AI enrichment keeps its existing opt-in and index scope.
@MainActor
final class AskFileContentSearch: SemanticFileSearching {
    private let spotlight: AskSpotlightSearch
    private let settings: @MainActor () -> AskLauncherSearchSettings
    private let enabled: @MainActor () -> Bool
    private let semantic: @MainActor () -> (any SemanticFileSearching)?
    private let access: () -> Bool

    init(spotlight: AskSpotlightSearch? = nil,
         settings: @escaping @MainActor () -> AskLauncherSearchSettings,
         enabled: @escaping @MainActor () -> Bool,
         semantic: @escaping @MainActor () -> (any SemanticFileSearching)?,
         access: @escaping () -> Bool = { AskFullDiskAccess.isGranted() }) {
        self.spotlight = spotlight ?? AskSpotlightSearch(); self.settings = settings; self.enabled = enabled
        self.semantic = semantic; self.access = access
    }

    var isEnabled: Bool { enabled() }

    func search(_ text: String, type: AskFileType, limit: Int) async -> [AskFileHit] {
        await search(text, type: type, limit: limit, progress: { _ in })
    }

    func search(_ text: String, type: AskFileType, limit: Int,
                progress: @escaping @MainActor @Sendable ([AskFileHit]) -> Void) async -> [AskFileHit] {
        guard isEnabled, limit > 0, !Task.isCancelled else { return [] }
        let scope = AskFileScope(settings: settings(), fullDiskAccess: access())
        let ai = semantic().flatMap { $0.isEnabled ? $0 : nil }
        let publication = Publication(progress: progress, limit: limit, current: { [weak self] in
            guard let self else { return false }
            return self.isEnabled && scope == AskFileScope(settings: self.settings(), fullDiskAccess: self.access())
        })
        async let system = spotlight.search(text, type: type, limit: limit, scope: scope)
        async let enhanced = ai?.search(text, type: type, limit: limit) { hits in publication.updateAI(hits) }
        let systemHits = await system
        guard !Task.isCancelled else { return [] }
        publication.updateSystem(systemHits)
        let aiHits = await enhanced ?? []
        guard !Task.isCancelled, isEnabled,
              scope == AskFileScope(settings: settings(), fullDiskAccess: access()) else { return [] }
        publication.updateAI(aiHits)
        return publication.hits
    }

    @MainActor private final class Publication {
        private var system: [AskFileHit] = [], ai: [AskFileHit] = []
        private let progress: @MainActor @Sendable ([AskFileHit]) -> Void
        private let limit: Int
        private let current: @MainActor () -> Bool
        init(progress: @escaping @MainActor @Sendable ([AskFileHit]) -> Void, limit: Int,
             current: @escaping @MainActor () -> Bool) {
            self.progress = progress; self.limit = limit; self.current = current
        }
        var hits: [AskFileHit] {
            var seen = Set<String>()
            return Array((ai + system).filter { seen.insert($0.path).inserted }.prefix(limit))
        }
        func updateAI(_ hits: [AskFileHit]) { ai = hits; publish() }
        func updateSystem(_ hits: [AskFileHit]) { system = hits; publish() }
        private func publish() { if !Task.isCancelled, current(), !hits.isEmpty { progress(hits) } }
    }
}
