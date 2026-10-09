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
    private var currentChinese = false
    private var currentText = ""
    private var currentSettings = AskLauncherSearchSettings()
    var fileDebounce: Duration = .milliseconds(60)
    private static let log = OSLog(subsystem: "com.typeflux", category: "LauncherSearch")

    init(imageCache: AskResultImageCache = .shared) {
        self.imageCache = imageCache
    }

    /// Keep the empty, non-executable search placeholder out of the visible list.
    var presentation: AskQuickResults? {
        if let pendingResults { return pendingResults }
        if isSearching, results?.rows == [.askAI], results?.notice == nil { return nil }
        return results
    }

    private struct FileBatch: Sendable {
        var hits: [AskFileHit]
        var status: AskFileIndexStatus
    }

    func update(text: String, chinese: Bool, calculator: Bool, sources: AskQuickResults.Sources) {
        let previous = results
        let presentation = self.presentation
        let appID = sources.apps.map(ObjectIdentifier.init), fileID = sources.files.map(ObjectIdentifier.init)
        let sameQuery = currentText == text && currentSettings == sources.settings
            && currentApp == appID && currentFile == fileID && currentCalculator == calculator && currentChinese == chinese
        cancel()
        currentApp = appID
        currentFile = fileID
        currentCalculator = calculator
        currentChinese = chinese
        currentText = text
        currentSettings = sources.settings
        previousChoice = previous
        retainedFiles = sameQuery ? previous?.files ?? [] : []
        os_signpost(.event, log: Self.log, name: "Input accepted", "%{public}d", generation)

        guard isVisible else { results = nil; return }

        // Calculation never consults either index, including incomplete expressions.
        if calculator {
            switch AskCalculator.read(text) {
            case .notExpression: break
            default:
                results = AskQuickResults.resolve(text: text, previous: previous, chinese: chinese,
                                                  calculator: true, sources: .init())
                return
            }
        }
        let query = AskSearchQuery(text)
        guard query.isSearchable || query.hasFilters else { results = nil; return }
        let appIndex = query.hasFilters ? nil : sources.apps
        guard appIndex != nil || sources.files != nil else { results = nil; return }
        let ticket = generation
        appsReady = appIndex == nil
        appResults = []
        fileResults = sources.files == nil ? FileBatch(hits: [], status: .init()) : nil
        isSearching = true
        pendingResults = sameQuery ? nil : presentation
        // Old-query rows must not remain actionable while the next query runs.
        results = sameQuery ? previous : AskQuickResults(apps: [], lead: false)
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
        guard publication == nil else { return }
        let ticket = generation
        let grace: Duration = appsReady && fileResults == nil ? .milliseconds(80) : .milliseconds(16)
        publication = Task { [weak self] in
            do { try await Task.sleep(for: grace) } catch { return }
            guard let self, generation == ticket, !Task.isCancelled else { return }
            publication = nil
            commitResults()
        }
    }

    private func commitResults() {
        guard appsReady || currentSettings.mode == .filesFirst else { return }
        isSearching = !appsReady || fileResults == nil
        var next = AskQuickResults.assemble(currentText, matches: appResults, hits: fileResults?.hits ?? retainedFiles,
                                            status: fileResults?.status, settings: currentSettings)
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
        delay?.cancel()
        delay = nil
        publication?.cancel()
        publication = nil
        apps.cancel()
        files.cancel()
        isSearching = false
        pendingResults = nil
    }

    deinit { delay?.cancel(); publication?.cancel() }
}
