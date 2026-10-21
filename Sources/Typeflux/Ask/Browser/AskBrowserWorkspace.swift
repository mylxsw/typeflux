import Combine
import Foundation
import WebKit

/// The embedded browser shared by the 随便问 window: its tabs, its persistent
/// profile, and the state the user controls while the AI works (pause, hand-off).
@MainActor
final class AskBrowserWorkspace: ObservableObject {
    nonisolated static let maxTabs = 8
    /// Identifies the persistent profile; changing it would sign the user out of every site.
    nonisolated static let profileIdentifier = UUID(uuidString: "6F1C2A8E-5B3D-4E7A-9C41-7A2B9D0E4F17")!
    /// Appended to WebKit's user agent so sites treat the browser like Safari.
    nonisolated static let applicationNameForUserAgent = "Version/18.0 Safari/605.1.15"

    struct Handoff: Identifiable, Equatable {
        typealias Reason = AskBrowserHandoffReason
        let id = UUID()
        let tabId: UUID
        let reason: Reason
        let message: String
    }

    struct Activity: Equatable {
        let conversationId: String
        let tabId: UUID
        let text: String
    }

    struct Site: Identifiable, Equatable {
        var id: String {
            (isOrigin ? "origin:" : isLegacy ? "legacy:" : "data:") + host
        }

        let host: String
        var hasData: Bool
        var permission: AskBrowserSitePermission
        var isOrigin = false
        var isLegacy = false
    }

    enum WorkspaceError: LocalizedError {
        case tooManyTabs, tabMissing, cancelled
        var errorDescription: String? {
            switch self {
            case .tooManyTabs: L("ask.web.tooManyTabs", AskBrowserWorkspace.maxTabs)
            case .tabMissing: L("ask.web.tabMissing")
            case .cancelled: L("ask.web.handoffCancelled")
            }
        }
    }

    @Published private(set) var tabs: [AskBrowserTab] = []
    @Published var selectedTabId: UUID?
    /// Bumped when the AI needs the panel visible; the window opens it.
    @Published private(set) var presentationRequest = 0
    @Published private(set) var paused = false
    /// The user took over by hand rather than pressing pause.
    @Published private(set) var takenOver = false
    @Published private(set) var handoff: Handoff?
    @Published private(set) var activity: Activity?
    let policy: AskBrowserSitePolicy
    let dataStore: WKWebsiteDataStore
    private var nextNumber = 1
    private var handoffContinuation: CheckedContinuation<Bool, Never>?
    private var tabObservers: [UUID: AnyCancellable] = [:]

    init(policy: AskBrowserSitePolicy? = nil, dataStore: WKWebsiteDataStore? = nil) {
        self.policy = policy ?? AskBrowserSitePolicy()
        self.dataStore = dataStore ?? Self.persistentStore()
    }

    /// Separate from the app's other web views, so signing in here never leaks into them.
    static func persistentStore() -> WKWebsiteDataStore {
        if #available(macOS 14.0, *) { return WKWebsiteDataStore(forIdentifier: profileIdentifier) }
        return .default()
    }

    var selectedTab: AskBrowserTab? { tabs.first { $0.id == selectedTabId } }

    func tab(number: Int) -> AskBrowserTab? { tabs.first { $0.number == number } }
    func tab(id: UUID) -> AskBrowserTab? { tabs.first { $0.id == id } }

    func configuration(isPrivate: Bool) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = isPrivate ? .nonPersistent() : dataStore
        configuration.applicationNameForUserAgent = Self.applicationNameForUserAgent
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        return configuration
    }

    @discardableResult
    func newTab(url: URL? = nil, owner: AskBrowserTab.Owner = .user, isPrivate: Bool = false,
                configuration: WKWebViewConfiguration? = nil, select: Bool = true) throws -> AskBrowserTab {
        guard tabs.count < Self.maxTabs else { throw WorkspaceError.tooManyTabs }
        let tab = AskBrowserTab(number: nextNumber,
                                configuration: configuration ?? self.configuration(isPrivate: isPrivate),
                                isPrivate: isPrivate, owner: owner)
        nextNumber += 1
        tab.openPopup = { [weak self, weak tab] configuration in
            guard let self, let tab else { return nil }
            return (try? self.newTab(owner: tab.owner, isPrivate: tab.isPrivate, configuration: configuration))?.webView
        }
        // Republish so the tab strip follows each tab's title and URL.
        tabObservers[tab.id] = tab.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        tabs.append(tab)
        if select { selectedTabId = tab.id }
        if let url { tab.load(url) }
        return tab
    }

    func select(_ tab: AskBrowserTab) { selectedTabId = tab.id }

    func close(_ tab: AskBrowserTab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        if handoff?.tabId == tab.id { finishHandoff(completed: false) }
        if activity?.tabId == tab.id { activity = nil }
        tab.close()
        tabs.remove(at: index)
        tabObservers[tab.id] = nil
        if selectedTabId == tab.id {
            selectedTabId = tabs.isEmpty ? nil : tabs[max(0, index - 1)].id
        }
    }

    /// Asks the window to show the panel, for example when the AI opens a page.
    func requestPresentation() { presentationRequest += 1 }

    // MARK: - Address bar

    /// A URL for typed text: explicit http(s) URLs, bare domains, or a web search.
    static func url(forInput input: String) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let url = URL(string: text), let scheme = url.scheme?.lowercased() {
            if ["http", "https"].contains(scheme), url.host != nil { return url }
            if scheme == "about" { return url }
        }
        let domain = #"^(localhost|[\p{L}0-9-]+(\.[\p{L}0-9-]+)+)(:\d+)?(/.*)?$"#
        if !text.contains(" "), text.range(of: domain, options: .regularExpression) != nil {
            let scheme = text.hasPrefix("localhost") ? "http://" : "https://"
            return URL(string: scheme + text)
        }
        var components = URLComponents(string: "https://www.google.com/search")
        components?.queryItems = [URLQueryItem(name: "q", value: text)]
        return components?.url
    }

    // MARK: - User control while the AI works

    func setPaused(_ paused: Bool, takenOver: Bool = false) {
        self.paused = paused
        self.takenOver = paused && takenOver
    }

    /// Called before every AI action. Returns once the user resumes; throws on cancellation.
    /// A pause belongs to the conversation that was acting, so it never holds another one.
    func waitUntilResumed(conversationId: String) async throws {
        while handoff != nil || (paused && activity.map { $0.conversationId == conversationId } ?? true) {
            try await Task.sleep(for: .milliseconds(150))
        }
        try Task.checkCancellation()
    }

    func beginActivity(_ text: String, conversationId: String, tab: AskBrowserTab) {
        if let activity, activity.conversationId != conversationId { paused = false; takenOver = false }
        activity = .init(conversationId: conversationId, tabId: tab.id, text: text)
    }

    /// A run ended: its conversation no longer controls any page. Nil ends any activity.
    func endActivity(conversationId: String? = nil) {
        if let conversationId, let activity, activity.conversationId != conversationId { return }
        activity = nil
        paused = false
        takenOver = false
    }

    /// Hands the page to the user (sign-in, captcha, payment) and waits for them.
    /// Returns false when the user cancels or the task is cancelled.
    func requestHandoff(tab: AskBrowserTab, reason: Handoff.Reason, message: String) async -> Bool {
        finishHandoff(completed: false)
        select(tab)
        requestPresentation()
        let request = Handoff(tabId: tab.id, reason: reason, message: message)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled { continuation.resume(returning: false); return }
                handoff = request
                handoffContinuation = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard self?.handoff?.id == request.id else { return }
                self?.finishHandoff(completed: false)
            }
        }
    }

    func finishHandoff(completed: Bool) {
        let continuation = handoffContinuation
        handoffContinuation = nil
        handoff = nil
        continuation?.resume(returning: completed)
    }

    // MARK: - Sites and sign-ins

    /// Sites with stored data in the profile, plus any the user gave a permission.
    func sites() async -> [Site] {
        let records = await dataStore.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
        let hosts = Set(records.compactMap { AskBrowserSitePolicy.normalized($0.displayName) })
        let origins = Set(policy.permissions.keys).union(tabs.compactMap { AskHTTPOrigin($0.url)?.description })
        let dataRows = hosts.sorted().map { Site(host: $0, hasData: true, permission: .ask) }
        let originRows = origins.sorted().map {
            Site(host: $0, hasData: false, permission: policy.permission(for: $0), isOrigin: true)
        }
        let legacyRows = policy.legacyPreferences.keys.sorted().map {
            Site(host: $0, hasData: false, permission: policy.legacyPreferences[$0] ?? .ask, isLegacy: true)
        }
        return originRows + legacyRows + dataRows
    }

    /// Signs out of a site: removes its cookies and storage. The permission stays.
    func clearData(for host: String) async {
        let records = await dataStore.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
        let matching = records.filter { record in
            guard let name = AskBrowserSitePolicy.normalized(record.displayName) else { return false }
            return name == host || name.hasSuffix("." + host) || host.hasSuffix("." + name)
        }
        guard !matching.isEmpty else { return }
        await dataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: matching)
    }

    func clearAllData() async {
        await dataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
    }
}

/// Why the AI hands a page to the user.
enum AskBrowserHandoffReason: String, CaseIterable, Sendable {
    case login, captcha, verification, payment, other
}
