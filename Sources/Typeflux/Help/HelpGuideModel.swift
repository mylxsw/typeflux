import Combine
import Foundation

/// The usage guide's state. It rebuilds its catalog from the user's settings whenever a
/// shortcut, keyword or workflow changes, so the guide never shows a stale or default key.
@MainActor
final class HelpGuideModel: ObservableObject {
    /// Where the guide reads the user's setup from.
    struct Sources {
        var keywords: @MainActor (AppLanguage) -> [HelpKeywordSource]
        var usage: @MainActor () -> [String: Int]
        var settings: SettingsStore
        var permissions: @MainActor () -> [HelpPermissionStatus]
        /// Workflows live in files; reading them again picks up ones added since.
        var refreshWorkflows: @MainActor () async -> Void = {}
        /// Fires when the workflow list changes.
        var workflowChanges: AnyPublisher<Void, Never> = Empty().eraseToAnyPublisher()
        var language: @MainActor () -> AppLanguage = { AppLocalization.shared.language }
    }

    /// What the guide asks the app to do; the guide closes itself first where it should.
    struct Actions {
        var close: @MainActor () -> Void = {}
        var tryKeyword: @MainActor (AskKeyword, String) -> Void = { _, _ in }
        var askAI: @MainActor (String) -> Void = { _ in }
        var openLauncher: @MainActor () -> Void = {}
        var openSettings: @MainActor (HelpSettingsDestination) -> Void = { _ in }
        var fixPermission: @MainActor (PrivacyGuard.PermissionID) -> Void = { _ in }
        var openURL: @MainActor (URL) -> Void = { _ in }
    }

    enum Key: Equatable {
        case escape, up, down, enter, commandEnter, find
        case page(Int)
    }

    static let documentationURL = URL(string: "https://typeflux.app")!
    static let feedbackURL = URL(string: "https://github.com/mylxsw/typeflux/issues/new")!

    @Published var page: HelpPage = .start
    @Published var query = "" { didSet { if query != oldValue { searchFocus = 0 } } }
    /// Nil shows every group.
    @Published var filter: HelpKeywordGroup?
    @Published var selectedKeywordID: String?
    /// The highlighted search result, counted across all result groups.
    @Published var searchFocus = 0
    @Published var openQuestionID: String?
    /// Bumped to put the cursor back in the search field.
    @Published private(set) var focusRequest = 0
    @Published private(set) var catalog = HelpCatalog()
    @Published private(set) var permissions: [HelpPermissionStatus] = []

    let sources: Sources
    var actions = Actions()
    private var cancellables: Set<AnyCancellable> = []
    private(set) var isPresented = false

    init(sources: Sources, center: NotificationCenter = .default) {
        self.sources = sources
        let changes: [Notification.Name] = [.hotkeySettingsDidChange, .askLauncherSearchSettingsDidChange]
        for name in changes {
            center.publisher(for: name).receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.reloadIfPresented() }
                .store(in: &cancellables)
        }
        sources.workflowChanges.receive(on: RunLoop.main)
            .sink { [weak self] in self?.reloadIfPresented() }
            .store(in: &cancellables)
    }

    // MARK: - Presentation

    /// Called each time the guide opens: fresh data, on the page the query asks for.
    func prepare(query: String) {
        isPresented = true
        self.query = query
        filter = nil
        openQuestionID = nil
        if query.isEmpty { page = .start }
        reload()
        focusRequest += 1
        Task { [weak self] in
            await self?.sources.refreshWorkflows()
            self?.reloadIfPresented()
        }
    }

    func dismissed() {
        isPresented = false
    }

    func reload() {
        catalog = HelpCatalog.build(HelpCatalogInput(
            keywords: sources.keywords(sources.language()), settings: sources.settings, usage: sources.usage()
        ))
        reloadPermissions()
        if selectedKeywordID.flatMap(catalog.keyword(id:)) == nil {
            selectedKeywordID = visibleKeywords.first?.id
        }
        if openQuestionID == nil {
            openQuestionID = relevantQuestions.first?.id
        }
    }

    func reloadPermissions() {
        permissions = sources.permissions()
    }

    private func reloadIfPresented() {
        guard isPresented else { return }
        reload()
    }

    // MARK: - Derived

    var isSearching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    var searchResults: HelpSearchResults {
        HelpSearch.search(query, in: catalog)
    }

    /// Keywords on the keywords page, in group order, after the filter.
    var visibleKeywords: [HelpKeyword] {
        HelpKeywordGroup.allCases.filter { filter == nil || filter == $0 }.flatMap(catalog.keywords(in:))
    }

    var selectedKeyword: HelpKeyword? {
        selectedKeywordID.flatMap(catalog.keyword(id:))
    }

    var missingPermissions: [HelpPermissionStatus] {
        permissions.filter { !$0.granted }
    }

    /// Questions a missing permission makes likely, so the guide can point at them.
    var relevantQuestions: [HelpQuestion] {
        let missing = Set(missingPermissions.map(\.id))
        return catalog.questions.filter { $0.permission.map(missing.contains) ?? false }
    }

    func isRelevant(_ question: HelpQuestion) -> Bool {
        relevantQuestions.contains(question)
    }

    // MARK: - Navigation

    func show(_ page: HelpPage) {
        query = ""
        self.page = page
        if page == .keywords, selectedKeyword == nil { selectedKeywordID = visibleKeywords.first?.id }
    }

    func setFilter(_ group: HelpKeywordGroup?) {
        filter = group
        if let selected = selectedKeyword, visibleKeywords.contains(selected) { return }
        selectedKeywordID = visibleKeywords.first?.id
    }

    /// Opens the keywords page on one keyword, from the start page or a search result.
    func showKeyword(_ id: String) {
        query = ""
        filter = nil
        selectedKeywordID = id
        page = .keywords
    }

    func showQuestion(_ id: String) {
        query = ""
        openQuestionID = id
        page = .faq
    }

    func toggleQuestion(_ id: String) {
        openQuestionID = openQuestionID == id ? nil : id
    }

    /// The flat order of search results, matching how the list draws them.
    enum SearchItem: Equatable {
        case keyword(HelpKeyword)
        case shortcut(HelpShortcut)
        case command(HelpCommand)
        case question(HelpQuestion)
    }

    var searchItems: [SearchItem] {
        let results = searchResults
        return results.keywords.map(SearchItem.keyword) + results.shortcuts.map(SearchItem.shortcut)
            + results.commands.map(SearchItem.command) + results.questions.map(SearchItem.question)
    }

    func open(_ item: SearchItem) {
        switch item {
        case let .keyword(keyword): showKeyword(keyword.id)
        case .shortcut, .command: show(.shortcuts)
        case let .question(question): showQuestion(question.id)
        }
    }

    // MARK: - Actions

    func tryKeyword(_ keyword: HelpKeyword, argument: String = "") {
        guard keyword.isAvailable else { return }
        actions.close()
        actions.tryKeyword(keyword.keyword, argument.isEmpty ? "" : argument)
    }

    func askAI() {
        let question = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        actions.close()
        actions.askAI(question)
    }

    /// Settings, System Settings and web pages open in their own windows; the guide stays.
    func openSettings(_ destination: HelpSettingsDestination) {
        actions.openSettings(destination)
    }

    func openLauncher() {
        actions.close()
        actions.openLauncher()
    }

    func fix(_ permission: PrivacyGuard.PermissionID) {
        actions.fixPermission(permission)
    }

    func open(_ url: URL) {
        actions.openURL(url)
    }

    // MARK: - Keys

    /// Handles a key the guide owns. False lets it through, e.g. to the search field.
    @discardableResult
    func handle(_ key: Key) -> Bool {
        switch key {
        case .escape:
            if isSearching { query = "" } else { actions.close() }
            return true
        case let .page(number):
            guard HelpPage.allCases.indices.contains(number - 1) else { return false }
            show(HelpPage.allCases[number - 1])
            return true
        case .find:
            focusRequest += 1
            return true
        case .up, .down:
            moveSelection(by: key == .down ? 1 : -1)
            return isSearching || page == .keywords
        case .enter:
            return activate()
        case .commandEnter:
            if isSearching, searchResults.isEmpty {
                askAI()
                return true
            }
            if !isSearching, page == .keywords, let keyword = selectedKeyword {
                tryKeyword(keyword)
                return true
            }
            return activate()
        }
    }

    private func moveSelection(by step: Int) {
        if isSearching {
            let count = searchItems.count
            guard count > 0 else { return }
            searchFocus = min(max(searchFocus + step, 0), count - 1)
        } else if page == .keywords {
            let keywords = visibleKeywords
            guard !keywords.isEmpty else { return }
            let index = keywords.firstIndex { $0.id == selectedKeywordID } ?? -1
            selectedKeywordID = keywords[min(max(index + step, 0), keywords.count - 1)].id
        }
    }

    private func activate() -> Bool {
        if isSearching {
            let items = searchItems
            guard items.indices.contains(searchFocus) else { return false }
            open(items[searchFocus])
            return true
        }
        if page == .keywords, let keyword = selectedKeyword {
            tryKeyword(keyword)
            return true
        }
        return false
    }
}
