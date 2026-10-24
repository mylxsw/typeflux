import Combine
import Foundation

/// One file opened in the side panel.
@MainActor
final class AskFileTab: ObservableObject, Identifiable {
    let id = UUID()
    /// File tabs belong to the conversation whose workspace or grants admitted them.
    let conversationId: String
    let target: AskSidePanelFileAccess.Target
    let kind: AskSidePanelFileKind
    /// HTML, Markdown and CSV tabs can switch to their source.
    @Published var showsSource = false
    /// Bumped to reload the file, for example after a run changed it.
    @Published private(set) var revision = 0

    init(conversationId: String, target: AskSidePanelFileAccess.Target, kind: AskSidePanelFileKind) {
        self.conversationId = conversationId
        self.target = target
        self.kind = kind
    }

    var name: String { AskWorkspaceFile.displayName(target.relativePath) }

    func reload() { revision += 1 }
}

/// A tab of the side panel: the pinned Files tab, a web page, or a file.
enum AskSidePanelTab: Identifiable {
    case files
    case web(AskBrowserTab)
    case file(AskFileTab)

    enum ID: Hashable {
        case files
        case web(UUID)
        case file(UUID)
    }

    var id: ID {
        switch self {
        case .files: .files
        case let .web(tab): .web(tab.id)
        case let .file(tab): .file(tab.id)
        }
    }
}

/// The panel beside the conversation. Web tabs stay owned by `AskBrowserWorkspace` (AI
/// actions, pause and hand-off are unchanged); this model adds the Files tab and file tabs
/// and keeps one strip order and selection for all of them.
@MainActor
final class AskSidePanel: ObservableObject {
    nonisolated static let maxFileTabs = 12

    enum PanelError: LocalizedError, Equatable {
        case tooManyFileTabs
        var errorDescription: String? { L("ask.sidePanel.tooManyFiles", AskSidePanel.maxFileTabs) }
    }

    let browser: AskBrowserWorkspace?
    /// Web and file tabs in strip order; the Files tab is pinned before them.
    @Published private(set) var order: [AskSidePanelTab.ID] = []
    @Published private(set) var fileTabs: [AskFileTab] = []
    /// Nil until the user first picks a tab; opening the panel then shows Files.
    @Published private(set) var selection: AskSidePanelTab.ID?
    @Published var notice: String?

    // MARK: Files tab state

    @Published private(set) var files: [AskWorkspaceFile] = []
    @Published private(set) var filesConversationId: String?
    @Published private(set) var filesRoot: URL?
    @Published private(set) var filesLoading = false
    @Published private(set) var filesError: String?
    @Published var fileQuery = AskWorkspaceFileQuery()
    private var filesGeneration = 0
    private var observers: Set<AnyCancellable> = []

    init(browser: AskBrowserWorkspace?) {
        self.browser = browser
        guard let browser else { return }
        // Only the tab list: page titles and progress are observed by the strip's buttons, so
        // loading a page never re-renders whatever observes the panel.
        browser.$tabs
            .sink { [weak self] tabs in self?.reconcile(webTabs: tabs) }
            .store(in: &observers)
        browser.$selectedTabId
            .sink { [weak self] id in self?.followBrowserSelection(id) }
            .store(in: &observers)
    }

    var tabs: [AskSidePanelTab] {
        [.files] + order.compactMap(tab)
    }

    func tab(_ id: AskSidePanelTab.ID) -> AskSidePanelTab? {
        switch id {
        case .files: return .files
        case let .web(id): return browser?.tab(id: id).map(AskSidePanelTab.web)
        case let .file(id): return fileTabs.first { $0.id == id }.map(AskSidePanelTab.file)
        }
    }

    var selectedTab: AskSidePanelTab? { selection.flatMap(tab) }
    var selectedFileTab: AskFileTab? {
        if case let .file(tab)? = selectedTab { return tab }
        return nil
    }

    /// The Files tab cannot close.
    var canCloseSelection: Bool {
        guard let selection, selection != .files else { return false }
        return tab(selection) != nil
    }

    // MARK: Selection

    func select(_ id: AskSidePanelTab.ID) {
        guard tab(id) != nil else { return }
        selection = id
        if case let .web(tabId) = id, let tab = browser?.tab(id: tabId) { browser?.select(tab) }
    }

    func showFiles() { selection = .files }

    /// Shown when the panel opens: the last tab picked, else Files.
    func prepareForPresentation() {
        if selection.flatMap(tab) == nil { selection = .files }
    }

    /// The AI asked for the browser: show its selected page, opening a blank one if none.
    func presentBrowser() {
        guard let browser else { return }
        if browser.tabs.isEmpty { _ = try? browser.newTab() }
        if let tab = browser.selectedTab ?? browser.tabs.last { select(.web(tab.id)) }
    }

    @discardableResult
    func newWebTab(url: URL? = nil, isPrivate: Bool = false) throws -> AskBrowserTab? {
        guard let browser else { return nil }
        let tab = try browser.newTab(url: url, isPrivate: isPrivate)
        select(.web(tab.id))
        return tab
    }

    // MARK: File tabs

    /// Opens a file in a tab, or switches to the tab already showing it.
    @discardableResult
    func open(_ target: AskSidePanelFileAccess.Target, conversationId: String,
              kind: AskSidePanelFileKind? = nil) throws -> AskFileTab {
        if let existing = fileTabs.first(where: { $0.target == target && $0.conversationId == conversationId }) {
            selection = .file(existing.id)
            return existing
        }
        guard fileTabs.count < Self.maxFileTabs else { throw PanelError.tooManyFileTabs }
        let ext = (target.relativePath as NSString).pathExtension
        let tab = AskFileTab(conversationId: conversationId, target: target,
                             kind: kind ?? AskSidePanelFileKind.kind(forExtension: ext))
        fileTabs.append(tab)
        order.append(.file(tab.id))
        selection = .file(tab.id)
        return tab
    }

    /// File tabs from other conversations close when the conversation changes: a tab
    /// may only show files its own conversation admitted.
    func retainFiles(conversationId: String?) {
        for tab in fileTabs where tab.conversationId != conversationId { close(.file(tab.id)) }
        if filesConversationId != conversationId {
            filesGeneration += 1
            files = []
            filesRoot = nil
            filesError = nil
            filesLoading = false
            filesConversationId = conversationId
        }
    }

    /// Reloads open file tabs, for example when a run ends.
    func reloadFileTabs() { fileTabs.forEach { $0.reload() } }

    // MARK: Closing

    func close(_ id: AskSidePanelTab.ID) {
        guard id != .files, let index = order.firstIndex(of: id) else { return }
        let wasSelected = selection == id
        switch id {
        case .files: return
        case let .web(tabId):
            // The workspace removes it; `reconcile` then drops it from the strip.
            if let tab = browser?.tab(id: tabId) { browser?.close(tab) }
            order.removeAll { $0 == id }
        case let .file(tabId):
            fileTabs.removeAll { $0.id == tabId }
            order.remove(at: index)
        }
        if wasSelected { selection = index > 0 ? order[min(index, order.count) - 1] : .files }
    }

    func closeSelected() {
        guard canCloseSelection, let selection else { return }
        close(selection)
    }

    /// Web tabs the AI opens join the strip; tabs it closes leave it.
    private func reconcile(webTabs: [AskBrowserTab]) {
        let ids = Set(webTabs.map(\.id))
        let previous = order
        order.removeAll { if case let .web(id) = $0 { !ids.contains(id) } else { false } }
        for tab in webTabs where !order.contains(.web(tab.id)) { order.append(.web(tab.id)) }
        if let selection, case let .web(id) = selection, !ids.contains(id) {
            // The AI closed the page being shown: fall back to the tab before it.
            let index = previous.firstIndex(of: selection) ?? 0
            self.selection = previous[..<index].reversed().first { order.contains($0) } ?? .files
        }
    }

    /// While a web page shows, the panel follows the page the AI switches to; it never pulls
    /// the user away from the Files tab or a file.
    private func followBrowserSelection(_ id: UUID?) {
        guard let id, case .web? = selection, selection != .web(id), order.contains(.web(id)) else { return }
        selection = .web(id)
    }

    // MARK: Files list

    /// Loads the conversation's files; a newer load or a conversation change wins.
    func refreshFiles(conversationId: String?,
                      load: @escaping () async throws -> (root: URL, files: [AskWorkspaceFile])?) async {
        filesGeneration += 1
        let generation = filesGeneration
        filesConversationId = conversationId
        guard conversationId != nil else {
            files = []; filesRoot = nil; filesError = nil; filesLoading = false
            return
        }
        filesLoading = true
        do {
            let result = try await load()
            guard generation == filesGeneration else { return }
            files = result?.files ?? []
            filesRoot = result?.root
            filesError = nil
        } catch {
            guard generation == filesGeneration else { return }
            filesError = error.localizedDescription
        }
        filesLoading = false
    }
}
