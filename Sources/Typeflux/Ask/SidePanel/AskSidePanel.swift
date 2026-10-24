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

/// A device-only artifact a run kept (`artifact` tool, generated images), opened in the
/// side panel instead of a modal preview. It is read through `AskArtifactAccess`, never a path.
@MainActor
final class AskArtifactTab: Identifiable {
    let id = UUID()
    let conversationId: String
    let ref: AskArtifactRef
    let name: String

    init(conversationId: String, ref: AskArtifactRef, name: String) {
        self.conversationId = conversationId
        self.ref = ref
        self.name = name
    }
}

/// Something the side panel opened lately, offered again on the new tab page.
enum AskSidePanelRecent: Identifiable, Equatable {
    case file(AskSidePanelFileAccess.Target, conversationId: String)
    case web(URL)

    var id: String {
        switch self {
        case let .file(target, conversationId): "file:" + conversationId + "\0" + target.path
        case let .web(url): "web:" + url.absoluteString
        }
    }

    var title: String {
        switch self {
        case let .file(target, _): AskWorkspaceFile.displayName(target.relativePath)
        case let .web(url): url.host ?? url.absoluteString
        }
    }

    /// The file's path in its workspace, or the page's address.
    var detail: String {
        switch self {
        case let .file(target, _): target.relativePath
        case let .web(url): url.absoluteString
        }
    }

    func matches(_ other: AskSidePanelRecent) -> Bool {
        switch (self, other) {
        case let (.web(lhs), .web(rhs)): AskSidePanel.samePage(lhs, rhs)
        default: self == other
        }
    }
}

/// A tab of the side panel: the pinned Files tab, a web page, a file, or an artifact.
enum AskSidePanelTab: Identifiable {
    case files
    case web(AskBrowserTab)
    case file(AskFileTab)
    case artifact(AskArtifactTab)

    enum ID: Hashable {
        case files
        case web(UUID)
        case file(UUID)
        case artifact(UUID)
    }

    var id: ID {
        switch self {
        case .files: .files
        case let .web(tab): .web(tab.id)
        case let .file(tab): .file(tab.id)
        case let .artifact(tab): .artifact(tab.id)
        }
    }
}

/// The panel beside the conversation. Web tabs stay owned by `AskBrowserWorkspace` (AI
/// actions, pause and hand-off are unchanged); this model adds the Files tab and file tabs
/// and keeps one strip order and selection for all of them.
@MainActor
final class AskSidePanel: ObservableObject {
    nonisolated static let maxFileTabs = 12
    nonisolated static let maxRecents = 8

    enum PanelError: LocalizedError, Equatable {
        case tooManyFileTabs
        var errorDescription: String? { L("ask.sidePanel.tooManyFiles", AskSidePanel.maxFileTabs) }
    }

    let browser: AskBrowserWorkspace?
    /// Web and file tabs in strip order; the Files tab is pinned before them.
    @Published private(set) var order: [AskSidePanelTab.ID] = []
    @Published private(set) var fileTabs: [AskFileTab] = []
    @Published private(set) var artifactTabs: [AskArtifactTab] = []
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
    /// Files and pages opened lately, newest first, for the new tab page.
    @Published private(set) var recents: [AskSidePanelRecent] = []
    /// Links the panel opened, by web tab: a page that has not committed yet has no URL.
    private var requestedURLs: [UUID: URL] = [:]
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
        case let .artifact(id): return artifactTabs.first { $0.id == id }.map(AskSidePanelTab.artifact)
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

    /// Opens a link in a web tab, or switches to the tab already showing that page.
    @discardableResult
    func openWeb(_ url: URL) throws -> AskBrowserTab? {
        guard let browser else { return nil }
        if let existing = browser.tabs.first(where: { Self.samePage($0.url ?? requestedURLs[$0.id], url) }) {
            select(.web(existing.id))
            remember(.web(url))
            return existing
        }
        let tab = try newWebTab(url: url)
        if let tab { requestedURLs[tab.id] = url }
        remember(.web(url))
        return tab
    }

    /// The same page: an empty `#` or the `/` of an empty path does not make another one.
    nonisolated static func samePage(_ lhs: URL?, _ rhs: URL) -> Bool {
        guard let lhs else { return false }
        func normalized(_ url: URL) -> String {
            var text = url.absoluteString
            if text.hasSuffix("#") { text.removeLast() }
            if url.path.isEmpty || url.path == "/", text.hasSuffix("/") { text.removeLast() }
            return text
        }
        return normalized(lhs) == normalized(rhs)
    }

    // MARK: File tabs

    /// Opens a file in a tab, or switches to the tab already showing it.
    @discardableResult
    func open(_ target: AskSidePanelFileAccess.Target, conversationId: String,
              kind: AskSidePanelFileKind? = nil) throws -> AskFileTab {
        if let existing = fileTabs.first(where: { $0.target == target && $0.conversationId == conversationId }) {
            selection = .file(existing.id)
            remember(.file(target, conversationId: conversationId))
            return existing
        }
        guard fileTabs.count + artifactTabs.count < Self.maxFileTabs else { throw PanelError.tooManyFileTabs }
        let ext = (target.relativePath as NSString).pathExtension
        let tab = AskFileTab(conversationId: conversationId, target: target,
                             kind: kind ?? AskSidePanelFileKind.kind(forExtension: ext))
        fileTabs.append(tab)
        order.append(.file(tab.id))
        selection = .file(tab.id)
        remember(.file(target, conversationId: conversationId))
        return tab
    }

    /// Opens an artifact in a tab, or switches to the tab already showing it.
    @discardableResult
    func open(artifact ref: AskArtifactRef, name: String, conversationId: String) throws -> AskArtifactTab {
        if let existing = artifactTabs.first(where: { $0.ref.id == ref.id && $0.conversationId == conversationId }) {
            selection = .artifact(existing.id)
            return existing
        }
        guard fileTabs.count + artifactTabs.count < Self.maxFileTabs else { throw PanelError.tooManyFileTabs }
        let tab = AskArtifactTab(conversationId: conversationId, ref: ref, name: name)
        artifactTabs.append(tab)
        order.append(.artifact(tab.id))
        selection = .artifact(tab.id)
        return tab
    }

    /// File and artifact tabs from other conversations close when the conversation changes:
    /// a tab may only show files its own conversation admitted.
    func retainFiles(conversationId: String?) {
        for tab in fileTabs where tab.conversationId != conversationId { close(.file(tab.id)) }
        for tab in artifactTabs where tab.conversationId != conversationId { close(.artifact(tab.id)) }
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
        case let .artifact(tabId):
            artifactTabs.removeAll { $0.id == tabId }
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
        requestedURLs = requestedURLs.filter { ids.contains($0.key) }
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

/// Strip order and the new tab page's recent items.
extension AskSidePanel {
    // MARK: Order

    /// Moves a tab before another one in the strip, or to its end when `target` is nil.
    /// The Files tab stays pinned first: it never moves, and nothing moves before it.
    func move(_ id: AskSidePanelTab.ID, before target: AskSidePanelTab.ID?) {
        guard id != .files, id != target, let from = order.firstIndex(of: id) else { return }
        if let target, target != .files, !order.contains(target) { return }
        order.remove(at: from)
        let destination = target.flatMap { target in target == .files ? 0 : order.firstIndex(of: target) }
        order.insert(id, at: destination ?? order.count)
    }

    // MARK: Recents

    /// Recently opened files of one conversation, and recent pages, for the new tab page.
    func recents(conversationId: String?) -> [AskSidePanelRecent] {
        recents.filter { recent in
            if case let .file(_, owner) = recent { return owner == conversationId }
            return true
        }
    }

    /// Opens a recent file or page from a new tab's start page; the blank tab it was picked
    /// on closes, as if the tab had navigated there. Files of other conversations never open.
    func openRecent(_ recent: AskSidePanelRecent, conversationId: String?) throws {
        var blank: AskBrowserTab?
        if case let .web(tab)? = selectedTab, tab.url == nil, requestedURLs[tab.id] == nil { blank = tab }
        switch recent {
        case let .file(target, owner):
            guard owner == conversationId else { return }
            try open(target, conversationId: owner)
        case let .web(url):
            // The blank tab itself shows the page, unless another tab already does.
            let shown = browser?.tabs.contains { Self.samePage($0.url ?? requestedURLs[$0.id], url) } == true
            if let blank, !shown {
                blank.load(url)
                requestedURLs[blank.id] = url
                remember(.web(url))
                return
            }
            try openWeb(url)
        }
        if let blank, selection != .web(blank.id) { close(.web(blank.id)) }
    }

    /// Opens a recent item from the start page; a failure shows as the panel's notice.
    func open(recent: AskSidePanelRecent, conversationId: String?) {
        do {
            try openRecent(recent, conversationId: conversationId)
            notice = nil
        } catch {
            notice = error.localizedDescription
        }
    }

    /// Drag-and-drop reordering: a tab dragged onto another takes its place, landing after it
    /// when dragged rightwards and before it when dragged leftwards.
    func move(_ id: AskSidePanelTab.ID, onto target: AskSidePanelTab.ID) {
        guard let from = order.firstIndex(of: id), let onto = order.firstIndex(of: target) else {
            if target == .files { move(id, before: .files) }
            return
        }
        guard from != onto else { return }
        move(id, before: from < onto ? (onto + 1 < order.count ? order[onto + 1] : nil) : target)
    }

    fileprivate func remember(_ recent: AskSidePanelRecent) {
        var list = recents.filter { !$0.matches(recent) }
        list.insert(recent, at: 0)
        recents = Array(list.prefix(Self.maxRecents))
    }
}
