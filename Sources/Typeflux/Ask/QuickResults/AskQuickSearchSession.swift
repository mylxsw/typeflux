import AppKit
import Combine
import Foundation
import os

/// The main actor only parses input and publishes small result batches. Apps
/// and files have independent workers with a bounded publication grace period.
@MainActor
final class AskQuickSearchSession: ObservableObject {
    @Published var isVisible = true
    @Published var results: AskQuickResults?
    /// Last-query rows remain visible, but never executable, until the first new batch.
    @Published private(set) var pendingResults: AskQuickResults?
    @Published private(set) var isSearching = false
    private let apps = AskSearchWorker<[AskAppMatch]>(label: "typeflux.ask.search.apps")
    private let files = AskSearchWorker<FileBatch>(label: "typeflux.ask.search.files")
    private let imageCache: AskResultImageCache
    private let publicationGrace: Duration
    private var browserTask: Task<Void, Never>?
    private var semanticTask: Task<Void, Never>?
    private var semanticResults: [AskFileHit] = []
    private var semanticReady = true
    private var currentSemantic: ObjectIdentifier?
    private var browserResults: [AskBrowserSearchEntry] = []
    private var browserReady = true
    private var currentBrowserSettings = AskBrowserSearchSettings()
    private var delay: Task<Void, Never>?
    private var publication: Task<Void, Never>?
    private var generation = 0
    private var appResults: [AskAppMatch] = []
    private var fileResults: FileBatch?
    private var appsReady = false
    private var previousChoice: AskQuickResults?
    private var retainedFiles: [AskFileHit] = []
    private var currentApp: ObjectIdentifier?
    private var currentFile: ObjectIdentifier?
    private var currentCalculator = false
    private var currentNumberConversions = false
    private var currentChinese = false
    private var currentText = ""
    private var currentSettings = AskLauncherSearchSettings()
    private var currentEntries: [AskLauncherSearchEntry] = []
    private var numberResults: AskQuickResults?
    var fileDebounce: Duration = .milliseconds(16)
    private static let log = OSLog(subsystem: "com.typeflux", category: "LauncherSearch")

    init(imageCache: AskResultImageCache? = nil, publicationGrace: Duration = .milliseconds(24)) {
        self.imageCache = imageCache ?? .shared
        self.publicationGrace = publicationGrace
    }

    /// Keep empty placeholders hidden until local search completes. Browser
    /// refreshes must not delay the local answer or leave the panel empty.
    var presentation: AskQuickResults? {
        if let pendingResults { return pendingResults }
        if isSearching, !appsReady || fileResults == nil,
           results?.rows == [.askAI], results?.notice == nil { return nil }
        return results
    }

    private struct FileBatch: Sendable {
        var hits: [AskFileHit]
        var status: AskFileIndexStatus
    }

    func update(text: String, chinese: Bool, calculator: Bool, numberConversions: Bool = true,
                sources: AskQuickResults.Sources) {
        let previous = results
        let presentation = self.presentation
        let appID = sources.apps.map(ObjectIdentifier.init), fileID = sources.files.map(ObjectIdentifier.init)
        let semanticID = sources.semantic.map(ObjectIdentifier.init)
        let sameQuery = currentText == text && currentSettings == sources.settings && currentEntries == sources.entries
            && currentBrowserSettings == sources.browserSettings && currentApp == appID && currentFile == fileID
            && currentCalculator == calculator && currentNumberConversions == numberConversions && currentChinese == chinese
            && currentSemantic == semanticID
        cancel()
        currentApp = appID
        currentFile = fileID
        currentSemantic = semanticID
        semanticResults = []; semanticReady = true
        currentCalculator = calculator
        currentNumberConversions = numberConversions
        currentChinese = chinese
        currentText = text
        currentSettings = sources.settings
        currentBrowserSettings = sources.browserSettings
        browserResults = []
        browserReady = true
        currentEntries = sources.entries
        previousChoice = previous
        retainedFiles = sameQuery ? previous?.files ?? [] : []
        numberResults = nil
        os_signpost(.event, log: Self.log, name: "Input accepted", "%{public}d", generation)

        guard isVisible else { results = nil; return }

        // Pure numbers convert immediately while both indexes continue searching.
        // Arithmetic, including incomplete expressions, still only uses the calculator.
        if calculator || numberConversions {
            switch AskCalculator.read(text, arithmetic: calculator, numberConversions: numberConversions) {
            case .notExpression: break
            case let .calculation(calculation) where calculation.isNumericInput:
                numberResults = AskQuickResults.resolve(text: text, previous: nil, chinese: chinese,
                                                       calculator: true, sources: .init())
            default:
                results = AskQuickResults.resolve(text: text, previous: previous, chinese: chinese,
                                                  calculator: calculator, numberConversions: numberConversions, sources: .init())
                return
            }
        }
        let query = AskSearchQuery(text)
        let semanticEnabled = sources.files != nil && sources.semantic?.isEnabled == true && SemanticFilePolicy.query(text) != nil
        guard query.isSearchable || query.hasFilters || semanticEnabled else {
            results = numberResults
            results?.keepChoice(from: previous)
            return
        }
        let appIndex = query.hasFilters || !query.isSearchable ? nil : sources.apps
        let features = AskLauncherSearchEntry.search(sources.entries, text: text)
        let browserEnabled = !query.hasFilters && sources.browsers != nil &&
            ((sources.browserSettings.tabsEnabled && sources.browserSettings.directTabs) ||
             (sources.browserSettings.bookmarksEnabled && sources.browserSettings.directBookmarks))
        guard appIndex != nil || sources.files != nil || browserEnabled else {
            results = AskQuickResults.addingNumberConversions(numberResults, to:
                AskQuickResults.assemble(text, matches: [], hits: [], status: nil, settings: sources.settings, entries: sources.entries))
            results?.keepChoice(from: previous)
            return
        }
        let ticket = generation
        appsReady = appIndex == nil
        appResults = []
        fileResults = sources.files == nil ? FileBatch(hits: [], status: .init()) : nil
        browserReady = !browserEnabled
        isSearching = true
        let disabledNumberPresentation = !numberConversions && presentation?.calculation?.isNumericInput == true
        pendingResults = sameQuery || !features.isEmpty || numberResults != nil || disabledNumberPresentation ? nil : presentation
        // Old-query rows must not remain actionable while the next query runs.
        var immediate = AskQuickResults.addingNumberConversions(numberResults, to:
            AskQuickResults.assemble(text, matches: [], hits: [], status: nil,
                settings: sources.settings, entries: sources.entries))
        immediate?.keepChoice(from: previous)
        results = (sameQuery ? previous : nil) ?? immediate ?? AskQuickResults(apps: [], lead: false)
        if browserEnabled { startBrowserQuery(text: text, sources: sources, ticket: ticket) }
        if semanticEnabled, let semantic = sources.semantic {
            semanticReady = false
            semanticTask = Task { [weak self] in
                let hits = await semantic.search(text, type: .all, limit: 24)
                guard let self, generation == ticket, !Task.isCancelled else { return }
                semanticResults = hits; semanticReady = true; publish()
            }
        }
        startQueries(text: text, query: query, appIndex: appIndex, fileIndex: sources.files,
                     fuzzy: sources.settings.fuzzy, ticket: ticket)
    }

    private func startQueries(text: String, query: AskSearchQuery, appIndex: (any AskAppSearching)?,
                              fileIndex: (any AskFileSearching)?, fuzzy: Bool, ticket: Int) {
        if let appIndex {
            apps.submit(operation: { token in
                guard !token.isCancelled else { return [] }
                return appIndex.search(text, limit: AskQuickResults.appLimit + AskQuickResults.paneLimit + 4)
            }, completion: { [weak self] matches in
                guard let self, generation == ticket else { return }
                appResults = matches
                prefetchIcons(matches.map { .init(url: $0.entry.url, thumbnail: false) })
                appsReady = true
                os_signpost(.event, log: Self.log, name: "Applications ready", "%{public}d", ticket)
                publish()
            })
        }
        if let fileIndex {
            delay = Task { [weak self] in
                guard let self else { return }
                do { try await Task.sleep(for: fileDebounce) } catch { return }
                guard generation == ticket, !Task.isCancelled else { return }
                files.submit(operation: { token in
                    let hits = fileIndex.search(query, options: .init(limit: 24, fuzzy: fuzzy, cancellation: token))
                    return FileBatch(hits: hits, status: fileIndex.status)
                }, completion: { [weak self] batch in
                    guard let self, generation == ticket else { return }
                    fileResults = batch
                    prefetchIcons(batch.hits.map { .init(url: $0.url, thumbnail: false, modified: $0.modified) })
                    os_signpost(.event, log: Self.log, name: "Files ready", "%{public}d", ticket)
                    publish()
                })
            }
        }
    }

    private func startBrowserQuery(text: String, sources: AskQuickResults.Sources, ticket: Int) {
        guard let service = sources.browsers else { return }
        let settings = sources.browserSettings
        browserTask = Task { [weak self] in
            async let cachedTabs: AskBrowserSearchSnapshot? = settings.tabsEnabled && settings.directTabs
                ? service.cachedSnapshot(kind: .tab, browsers: settings.tabBrowsers, interactive: false) : .some(.init())
            async let cachedBookmarks: AskBrowserSearchSnapshot? = settings.bookmarksEnabled && settings.directBookmarks
                ? service.cachedSnapshot(kind: .bookmark, browsers: settings.bookmarkBrowsers, interactive: false) : .some(.init())
            let (cachedTabBatch, cachedBookmarkBatch) = await (cachedTabs, cachedBookmarks)
            guard let self, generation == ticket, !Task.isCancelled else { return }
            if cachedTabBatch != nil || cachedBookmarkBatch != nil {
                browserResults = AskBrowserSearchEntry.search(cachedTabBatch?.entries ?? [], query: text, limit: 5) +
                    AskBrowserSearchEntry.search(cachedBookmarkBatch?.entries ?? [], query: text, limit: 5)
                browserReady = cachedTabBatch != nil && cachedBookmarkBatch != nil
                if browserReady || !browserResults.isEmpty { publish() }
                if browserReady { return }
            }
            do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
            async let tabs: AskBrowserSearchSnapshot = settings.tabsEnabled && settings.directTabs
                ? service.snapshot(kind: .tab, browsers: settings.tabBrowsers, interactive: false) : .init()
            async let bookmarks: AskBrowserSearchSnapshot = settings.bookmarksEnabled && settings.directBookmarks
                ? service.snapshot(kind: .bookmark, browsers: settings.bookmarkBrowsers, interactive: false) : .init()
            let (tabBatch, bookmarkBatch) = await (tabs, bookmarks)
            guard generation == ticket, !Task.isCancelled else { return }
            browserResults = AskBrowserSearchEntry.search(tabBatch.entries, query: text, limit: 5) +
                AskBrowserSearchEntry.search(bookmarkBatch.entries, query: text, limit: 5)
            browserReady = true
            publish()
        }
    }

    private func prefetchIcons(_ keys: [AskResultImageCache.Key]) {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        imageCache.prefetch(keys.map { key in
            var key = key
            key.scale = scale
            return key
        })
    }

    private func publish() {
        // Give debounced files a bounded chance to join the application batch.
        // Slow providers still publish independently after this short grace period.
        // Once both local providers finish there is no batch left to coalesce.
        // Cancel the grace timer rather than delaying an already complete answer.
        if appsReady, fileResults != nil {
            publication?.cancel()
            publication = nil
            commitResults()
            return
        }
        guard publication == nil else { return }
        let ticket = generation
        let grace: Duration = appsReady && fileResults == nil ? publicationGrace : .milliseconds(16)
        publication = Task { [weak self] in
            do { try await Task.sleep(for: grace) } catch { return }
            guard let self, generation == ticket, !Task.isCancelled else { return }
            publication = nil
            commitResults()
        }
    }

    private func commitResults() {
        guard appsReady || currentSettings.mode == .filesFirst else { return }
        isSearching = !appsReady || fileResults == nil || !browserReady || !semanticReady
        let names = fileResults?.hits ?? retainedFiles
        var combined = SemanticFilePolicy.merge(names, semanticResults, limit: 48)
        // A late batch must not evict a row the user already chose.
        if let current = results, current.chosen, let selected = current.file(at: current.highlightedRow),
           let hit = combined.first(where: { $0.path == selected.path }),
           !combined.filter({ $0.isFolder == selected.isFolder })
               .prefix(selected.isFolder ? AskQuickResults.folderLimit : AskQuickResults.fileLimit)
               .contains(where: { $0.path == selected.path }) {
            combined.removeAll { $0.path == hit.path }; combined.insert(hit, at: 0)
        }
        var next = AskQuickResults.addingNumberConversions(numberResults, to:
            AskQuickResults.assemble(currentText, matches: appResults, hits: combined,
                status: fileResults?.status, settings: currentSettings, entries: currentEntries))
        next = AskQuickResults.addingBrowsers(browserResults, to: next)
        next?.keepChoice(from: results?.chosen == true ? results : previousChoice)
        results = next ?? (isSearching ? AskQuickResults(apps: [], lead: false) : nil)
        // An empty application batch is not the final answer while files are
        // still searching. Do not flash Ask AI between two useful batches.
        if next != nil || !isSearching { pendingResults = nil }
    }

    func isCurrent(text: String) -> Bool { isVisible && text == currentText }

    func setVisible(_ visible: Bool) {
        isVisible = visible
        if !visible { cancel(); results = nil }
    }

    func cancel() {
        generation += 1
        semanticTask?.cancel(); semanticTask = nil
        browserTask?.cancel()
        browserTask = nil
        delay?.cancel()
        delay = nil
        publication?.cancel()
        publication = nil
        apps.cancel()
        files.cancel()
        isSearching = false
        pendingResults = nil
    }

    deinit { delay?.cancel(); browserTask?.cancel(); semanticTask?.cancel(); publication?.cancel() }
}
