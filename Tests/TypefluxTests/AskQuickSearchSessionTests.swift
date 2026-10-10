import AppKit
import Foundation
import Combine
import Testing
@testable import Typeflux

/// Providers deliberately stall off the main thread; all waits have a deadline.
final class AskControlledSearchIndex: AskAppSearching, AskFileSearching, @unchecked Sendable {
    let lock = NSLock()
    var appSearch: @Sendable (String) -> [AskAppMatch] = { _ in [] }
    var fileSearch: @Sendable (AskFileSearchOptions) -> [AskFileHit] = { _ in [] }
    private var queries: [String] = []
    private var onMain = false
    var calls: [String] { lock.withLock { queries } }
    var searchedOnMain: Bool { lock.withLock { onMain } }
    var status = AskFileIndexStatus(phase: .ready)
    var usage: [String: Int] { [:] }
    func search(_ query: String, limit: Int) -> [AskAppMatch] {
        lock.withLock { queries.append(query); onMain = onMain || Thread.isMainThread }
        return appSearch(query)
    }
    func search(_ query: AskSearchQuery, options: AskFileSearchOptions) -> [AskFileHit] {
        lock.withLock { queries.append(query.text); onMain = onMain || Thread.isMainThread }
        return fileSearch(options)
    }
    func recent(options: AskFileSearchOptions) -> [AskFileHit] { fileSearch(options) }
    func refreshIfStale() {}
    func recordLaunch(_ entry: AskAppEntry) {}
    func start() {}
    func recordOpen(_ path: String) {}
    func forget(_ path: String) {}
    func rebuild() {}
    func clear() {}
}

@Suite("Staged launcher search", .serialized, .exclusiveUIState)
@MainActor
struct AskQuickSearchSessionTests {
    @Test func disablingConversionsDuringSearchRemovesThemAndRejectsThePreviousBatch() async throws {
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let apps = AskControlledSearchIndex()
        apps.appSearch = { _ in _ = gate.wait(timeout: .now() + 5); return [Self.app] }
        let session = AskQuickSearchSession()
        session.update(text: "255", chinese: false, calculator: true, numberConversions: true, sources: .init(apps: apps))
        try await Self.wait { !apps.calls.isEmpty }
        #expect(session.presentation?.calculation?.isNumericInput == true)
        session.update(text: "255", chinese: false, calculator: true, numberConversions: false, sources: .init(apps: apps))
        #expect(session.presentation?.calculation == nil && session.pendingResults == nil)
        gate.signal()
        gate.signal()
        try await Self.wait { !session.isSearching }
        #expect(session.results?.calculation == nil && session.results?.formats.isEmpty == true)
        #expect(session.results?.apps.count == 1 && apps.calls == ["255", "255"])
    }

    @Test func numbersConvertImmediatelyAndKeepTheChosenFormatWhenSearchArrives() async throws {
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let apps = AskControlledSearchIndex(), files = AskControlledSearchIndex()
        apps.appSearch = { _ in _ = gate.wait(timeout: .now() + 5); return [Self.app] }
        files.fileSearch = { _ in [Self.file] }
        let session = AskQuickSearchSession()
        session.fileDebounce = .zero
        update(session, "2024", apps: apps, files: files, calculator: true)
        #expect(session.isSearching && session.pendingResults == nil)
        #expect(session.presentation?.value(of: .calculation) == "2024")
        let format = try #require(session.results?.rows.firstIndex(of: .format(0)))
        session.results?.highlight(format)
        try await Self.wait { !apps.calls.isEmpty && !files.calls.isEmpty }
        gate.signal()
        try await Self.wait { !session.isSearching }
        let result = try #require(session.results)
        #expect(apps.calls == ["2024"] && files.calls == ["2024"])
        #expect(!apps.searchedOnMain && !files.searchedOnMain)
        #expect(result.apps.count == 1 && result.files.count == 1)
        #expect(result.rows.contains(.calculation) && result.rows.contains(.file(0)))
        #expect(result.highlightedRow == .format(0) && result.chosen)
    }

    @Test func numericSearchKeepsConversionsWithNoMatchesOrNoProviders() async throws {
        let index = AskControlledSearchIndex()
        let session = AskQuickSearchSession()
        update(session, "255", apps: index, files: index, calculator: true)
        try await Self.wait { !session.isSearching }
        #expect(index.calls == ["255", "255"])
        #expect(session.results?.value(of: .calculation) == "255")
        #expect(session.results?.highlightedRow == .calculation)
        #expect(session.results?.formats.first?.value == "贰佰伍拾伍")
        update(session, "256", calculator: true)
        #expect(!session.isSearching)
        #expect(session.presentation?.value(of: .calculation) == "256")
    }

    @Test func changingNumbersReplacesConversionsAndRejectsOldSearchBatches() async throws {
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let apps = AskControlledSearchIndex()
        apps.appSearch = { query in
            if query == "2024" { _ = gate.wait(timeout: .now() + 5) }
            return [.init(entry: AskTestAppIndex.app(query), score: 1)]
        }
        let session = AskQuickSearchSession()
        update(session, "2024", apps: apps, calculator: true)
        try await Self.wait { apps.calls == ["2024"] }
        update(session, "2025", apps: apps, calculator: true)
        #expect(session.presentation?.value(of: .calculation) == "2025")
        #expect(session.results?.apps.isEmpty == true && session.pendingResults == nil)
        gate.signal()
        try await Self.wait { !session.isSearching }
        #expect(session.results?.apps.first?.entry.name == "2025")
        #expect(session.results?.value(of: .calculation) == "2025")
        update(session, "note", apps: apps, calculator: true)
        try await Self.wait { !session.isSearching }
        #expect(session.results?.calculation == nil && session.results?.formats.isEmpty == true)
        #expect(session.results?.apps.first?.entry.name == "note")
    }

    @Test func searchBatchesPrefetchIconsBeforeRowsAreCreated() async throws {
        let expected = NSImage(size: .init(width: 28, height: 28))
        var loaded: [AskResultImageCache.Key] = []
        let cache = AskResultImageCache { key in
            loaded.append(key)
            return expected
        }
        let apps = AskControlledSearchIndex(), files = AskControlledSearchIndex()
        apps.appSearch = { _ in [Self.app] }
        files.fileSearch = { _ in [Self.file] }
        let session = AskQuickSearchSession(imageCache: cache)
        update(session, apps: apps, files: files)
        try await Self.wait { !session.isSearching }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        #expect(cache.cached(.init(url: Self.app.entry.url, thumbnail: false, scale: scale)) === expected)
        #expect(cache.cached(.init(url: Self.file.url, thumbnail: false, modified: Self.file.modified,
                                  scale: scale)) === expected)
        #expect(loaded.count == 2, "Search must warm both types of rows without waiting for a view task")
        #expect(loaded.allSatisfy { !$0.thumbnail })
    }

    nonisolated static let app = AskAppMatch(entry: AskTestAppIndex.app("Notes"), score: 0.9)
    nonisolated static let file = AskFileHit(path: "/notes.txt", name: "notes.txt", kind: .file,
                                 modified: Date(), score: 1.06, match: 1)

    static func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<1000 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(condition(), "the search must finish within two seconds")
    }

    private func update(_ session: AskQuickSearchSession, _ text: String = "note",
                        apps: (any AskAppSearching)? = nil, files: (any AskFileSearching)? = nil,
                        calculator: Bool = false) {
        session.update(text: text, chinese: false, calculator: calculator, sources: .init(apps: apps, files: files))
    }

    @Test func firstSearchNeverPresentsAnEmptyAskAIRowWhileWaiting() async throws {
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let apps = AskControlledSearchIndex()
        apps.appSearch = { query in
            if query == "note" { _ = gate.wait(timeout: .now() + 5) }
            return [Self.app]
        }
        let session = AskQuickSearchSession()
        update(session, apps: apps)
        #expect(session.isSearching)
        #expect(session.presentation == nil)
        update(session, "notebook", apps: apps)
        #expect(session.presentation == nil, "rapid typing before the first batch must not expose a placeholder")
        gate.signal()
        try await Self.wait { !session.isSearching }
        #expect(session.presentation?.apps.count == 1)
    }

    @Test func fastProvidersPublishOneCombinedUsefulBatch() async throws {
        let apps = AskControlledSearchIndex(), files = AskControlledSearchIndex()
        apps.appSearch = { _ in [Self.app] }
        files.fileSearch = { _ in [Self.file] }
        let session = AskQuickSearchSession()
        var batches: [AskQuickResults] = []
        let subscription = session.$results.sink { result in
            if let result, !result.apps.isEmpty || !result.files.isEmpty { batches.append(result) }
        }
        defer { subscription.cancel() }
        update(session, apps: apps, files: files)
        try await Self.wait { !session.isSearching }
        #expect(batches.count == 1)
        #expect(batches.first?.apps.count == 1 && batches.first?.files.count == 1)
    }

    @Test func pendingQueriesKeepTheirPresentationWithoutRetainingExecutableRows() async throws {
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let apps = AskControlledSearchIndex()
        apps.appSearch = { query in
            if query != "note" { _ = gate.wait(timeout: .now() + 5) }
            return [.init(entry: AskTestAppIndex.app(query), score: 1)]
        }
        let session = AskQuickSearchSession()
        update(session, apps: apps)
        try await Self.wait { !session.isSearching }
        let first = session.results
        update(session, "notebook", apps: apps)
        #expect(session.pendingResults == first)
        #expect(session.presentation == first)
        #expect(session.results?.apps.isEmpty == true)
        update(session, "notebooks", apps: apps)
        #expect(session.pendingResults == first, "rapid typing keeps the last real batch")
        gate.signal()
        gate.signal()
        try await Self.wait { !session.isSearching }
        #expect(session.pendingResults == nil)
        #expect(session.results?.apps.first?.entry.name == "notebooks")
    }

    @Test func clearingOrHidingTheQueryRemovesThePendingPresentation() async throws {
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let apps = AskControlledSearchIndex()
        apps.appSearch = { query in
            if query != "note" { _ = gate.wait(timeout: .now() + 5) }
            return [Self.app]
        }
        let session = AskQuickSearchSession()
        update(session, apps: apps)
        try await Self.wait { !session.isSearching }
        update(session, "next", apps: apps)
        #expect(session.pendingResults != nil)
        update(session, "", apps: apps)
        #expect(session.pendingResults == nil && session.results == nil)
        update(session, "note", apps: apps)
        gate.signal()
        try await Self.wait { !session.isSearching }
        update(session, "later", apps: apps)
        session.setVisible(false)
        #expect(session.pendingResults == nil && session.results == nil)
    }

    @Test func anEmptyApplicationBatchDoesNotFlashBetweenTwoUsefulBatches() async throws {
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let apps = AskControlledSearchIndex(), files = AskControlledSearchIndex()
        apps.appSearch = { query in query == "note" ? [Self.app] : [] }
        files.fileSearch = { _ in _ = gate.wait(timeout: .now() + 5); return [Self.file] }
        let session = AskQuickSearchSession()
        session.fileDebounce = .zero
        update(session, apps: apps)
        try await Self.wait { !session.isSearching }
        let first = session.results
        update(session, "report", apps: apps, files: files)
        try await Self.wait { !files.calls.isEmpty && apps.calls.count == 2 }
        #expect(session.isSearching)
        #expect(session.pendingResults == first)
        #expect(session.results?.apps.isEmpty == true)
        gate.signal()
        try await Self.wait { !session.isSearching }
        #expect(session.pendingResults == nil && session.results?.files.count == 1)
    }

    @Test func slowFilesNeverBlockApplicationsOrChangeTheirSelection() async throws {
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let apps = AskControlledSearchIndex(), files = AskControlledSearchIndex()
        apps.appSearch = { _ in [Self.app] }
        files.fileSearch = { _ in _ = gate.wait(timeout: .now() + 5); return [Self.file] }
        let session = AskQuickSearchSession()
        session.fileDebounce = .zero
        update(session, apps: apps, files: files)
        try await Self.wait { session.results?.apps.count == 1 && !files.calls.isEmpty }
        #expect(session.isSearching)
        #expect(!apps.searchedOnMain && !files.searchedOnMain)
        session.results?.highlight(0)
        gate.signal()
        try await Self.wait { !session.isSearching }
        #expect(session.results?.files.count == 1)
        #expect(session.results?.highlightedRow == .app(0))
        #expect(session.results?.rows.first == .app(0), "a stronger file cannot steal Return")
    }

    @Test func filesWaitForTheApplicationBatch() async throws {
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let apps = AskControlledSearchIndex(), files = AskControlledSearchIndex()
        apps.appSearch = { _ in _ = gate.wait(timeout: .now() + 5); return [Self.app] }
        files.fileSearch = { _ in [Self.file] }
        let session = AskQuickSearchSession()
        session.fileDebounce = .zero
        update(session, apps: apps, files: files)
        try await Self.wait { !files.calls.isEmpty }
        #expect(session.results?.files.isEmpty == true)
        gate.signal()
        try await Self.wait { !session.isSearching }
        #expect(session.results?.rows.first == .app(0))
    }

    @Test func oldQueriesCannotOverwriteNewOnesAndPendingWorkIsReplaced() async throws {
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let apps = AskControlledSearchIndex()
        apps.appSearch = { query in
            if query == "first" { _ = gate.wait(timeout: .now() + 5) }
            return [.init(entry: AskTestAppIndex.app(query), score: 1)]
        }
        let session = AskQuickSearchSession()
        update(session, "first", apps: apps)
        try await Self.wait { apps.calls == ["first"] }
        for index in 0..<100 { update(session, "query\(index)", apps: apps) }
        #expect(session.results?.apps.isEmpty == true, "previous-query rows cannot be executed")
        gate.signal()
        try await Self.wait { !session.isSearching }
        #expect(apps.calls == ["first", "query99"])
        #expect(session.results?.apps.first?.entry.name == "query99")
    }

    @Test func cancelledFileSearchStopsAndCannotPublish() async throws {
        let files = AskControlledSearchIndex()
        let observed = AskSearchCancellation()
        files.fileSearch = { options in
            let deadline = Date().addingTimeInterval(3)
            while options.cancellation?.isCancelled != true && Date() < deadline { Thread.sleep(forTimeInterval: 0.001) }
            if options.cancellation?.isCancelled == true { observed.cancel() }
            return [Self.file]
        }
        let session = AskQuickSearchSession()
        session.fileDebounce = .zero
        update(session, files: files)
        try await Self.wait { !files.calls.isEmpty }
        update(session, "", files: files)
        try await Self.wait { observed.isCancelled }
        #expect(session.results == nil)
        #expect(!session.isSearching)
    }

    @Test func debounceCoalescesTypingAndCancellationPreventsDispatch() async throws {
        let files = AskControlledSearchIndex()
        let session = AskQuickSearchSession()
        session.fileDebounce = .milliseconds(20)
        for index in 0..<50 { update(session, "note\(index)", files: files) }
        try await Self.wait { !session.isSearching }
        #expect(files.calls == ["note49"])
        update(session, "cancel", files: files)
        session.cancel()
        try await Task.sleep(for: .milliseconds(30))
        #expect(files.calls == ["note49"])
    }

    @Test func arithmeticAndDisabledSearchDoNotReachProviders() {
        let index = AskControlledSearchIndex()
        let session = AskQuickSearchSession()
        update(session, "2+2", apps: index, files: index, calculator: true)
        #expect(session.results?.calculation?.number?.copyText == "4")
        update(session, "2+", apps: index, files: index, calculator: true)
        #expect(session.results?.stale == true)
        update(session, "note")
        #expect(session.results == nil)
        #expect(index.calls.isEmpty)
    }

    @Test func filtersSkipApplicationsAndIndexingWithoutHitsIsVisible() async throws {
        let index = AskControlledSearchIndex()
        index.status = .init(phase: .building(found: 12, estimate: 100))
        let session = AskQuickSearchSession()
        session.fileDebounce = .zero
        update(session, ".pdf", apps: index, files: index)
        try await Self.wait { !session.isSearching }
        #expect(index.calls == [".pdf"], "only the file provider is called")
        #expect(session.results?.notice == .indexing(found: 12, progress: 0.12))
    }

    @Test func sameQueryRefreshKeepsResultsWhileWaiting() async throws {
        let apps = AskControlledSearchIndex()
        apps.appSearch = { _ in [Self.app] }
        let session = AskQuickSearchSession()
        update(session, apps: apps)
        try await Self.wait { !session.isSearching }
        session.results?.highlight(0)
        update(session, apps: apps)
        #expect(session.results?.apps.count == 1)
        try await Self.wait { !session.isSearching }
        #expect(session.results?.chosen == true)
    }
    @Test func filesFirstCanPublishBeforeASlowAppProvider() async throws {
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let apps = AskControlledSearchIndex(), files = AskControlledSearchIndex()
        apps.appSearch = { _ in _ = gate.wait(timeout: .now() + 5); return [Self.app] }
        files.fileSearch = { _ in [Self.file] }
        var settings = AskLauncherSearchSettings()
        settings.mode = .filesFirst
        let session = AskQuickSearchSession()
        session.fileDebounce = .zero
        session.update(text: "note", chinese: false, calculator: false,
                       sources: .init(apps: apps, files: files, settings: settings))
        try await Self.wait { session.results?.files.count == 1 }
        #expect(session.isSearching)
        session.results?.highlight(0)
        gate.signal()
        try await Self.wait { !session.isSearching }
        #expect(session.results?.highlightedRow == .file(0))
    }

    @Test func disabledSourcesAndHiddenSessionsCannotRetainExecutableResults() async throws {
        let apps = AskControlledSearchIndex(), files = AskControlledSearchIndex()
        apps.appSearch = { _ in [Self.app] }
        files.fileSearch = { _ in [Self.file] }
        let session = AskQuickSearchSession()
        session.fileDebounce = .zero
        update(session, apps: apps, files: files)
        try await Self.wait { !session.isSearching }
        #expect(session.results?.files.count == 1)
        update(session, apps: apps)
        #expect(session.results?.files.isEmpty == true)
        try await Self.wait { !session.isSearching }
        session.setVisible(false)
        update(session, apps: apps, files: files)
        #expect(session.results == nil)
        #expect(!session.isSearching)
    }

}
