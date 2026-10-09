import Foundation

/// File mode: `f` and a name lists every matching file and folder, best first,
/// with nothing typed the most recently changed ones. ⇥ narrows to a type
/// (folders, documents, pictures, PDFs…). Return opens, ⌘R shows in Finder,
/// ⇧⌘C copies the path, ⌘Y previews. Only names are searched, never contents.
struct AskFileSearchPlugin: AskLauncherPlugin {
    static let id = "files"
    static let typeOption = "type"
    private let queue = DispatchQueue(label: "typeflux.ask.search.filePlugin", qos: .userInitiated)
    static let keywords = [AskKeyword(keyword: "f", pluginID: id)]

    /// The index to search; read when a run starts, so tests can swap it.
    var index: @MainActor @Sendable () -> (any AskFileSearching)?
    var settings: @Sendable () -> AskLauncherSearchSettings

    var id: String { Self.id }
    var title: String { L("ask.plugin.files.title") }
    var symbol: String { "doc.text.magnifyingglass" }
    var optionName: String? { L("ask.plugin.files.option") }
    var runsWithoutInput: Bool { true }
    var defaultKeywords: [AskKeyword] { Self.keywords }

    func placeholder(selectionLines: Int?) -> String { L("ask.plugin.files.placeholder") }

    func chipDetail(for keyword: AskKeyword, language: AppLanguage) -> String? {
        Self.type(of: keyword.options).map(\.title)
    }

    static func type(of options: [String: String]) -> AskFileType? {
        options[typeOption].flatMap(AskFileType.init(rawValue:)).flatMap { $0 == .all ? nil : $0 }
    }

    /// Searching is local and quick, so it runs while typing.
    func plan(_ request: AskPluginRequest) async -> AskPluginPlan {
        let type = Self.type(of: request.options) ?? .all
        return AskPluginPlan(mode: .live, title: title, meta: [AskPluginMeta(text: type.title)],
                             values: [Self.typeOption: type.rawValue], debounce: .milliseconds(60))
    }

    func run(_ request: AskPluginRequest, plan: AskPluginPlan,
             progress: @escaping AskPluginProgress) async throws -> AskPluginOutput {
        guard let index = await index() else {
            return output([Self.notice(L("ask.plugin.files.off"), symbol: "exclamationmark.circle")], note: nil)
        }
        let settings = settings()
        let type = Self.type(of: request.options) ?? .all
        let text = request.origin == .selection ? request.text.replacingOccurrences(of: "\n", with: " ") : request.text
        let query = AskSearchQuery(text)
        let token = AskSearchCancellation()
        let options = AskFileSearchOptions(limit: settings.limit, fuzzy: settings.fuzzy, type: type, cancellation: token)
        let hits: [AskFileHit] = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    guard !token.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                    let hits = query.isEmpty ? index.recent(options: options) : index.search(query, options: options)
                    if token.isCancelled { continuation.resume(throwing: CancellationError()) }
                    else { continuation.resume(returning: hits) }
                }
            }
        } onCancel: { token.cancel() }
        try Task.checkCancellation()
        var items = hits.map(Self.item)
        if items.isEmpty {
            items.append(Self.notice(L(query.isEmpty ? "ask.plugin.files.none.recent" : "ask.plugin.files.none"),
                                     symbol: "doc.questionmark"))
        }
        let status = index.status
        if !status.blocked.isEmpty {
            var unlock = Self.notice(L("ask.plugin.files.unlock", Self.folderNames(status.blocked)), symbol: "lock")
            unlock.valid = true
            unlock.subtitle = L("ask.plugin.files.unlock.subtitle")
            unlock.actions = [AskPluginAction(kind: .open(AskFullDiskAccess.settingsURL),
                                              title: L("ask.plugin.files.unlock.action"), symbol: "lock.open",
                                              shortcut: .enter)]
            items.append(unlock)
        }
        var note: String?
        if case let .building(found, _) = status.phase { note = L("ask.quick.file.indexing", found.formatted()) }
        if let summary = AskFileLabels.skipped(status) {
            note = [note, summary].compactMap { $0 }.joined(separator: " · ")
        }
        return output(items, note: note)
    }

    func nextOptions(after plan: AskPluginPlan, request: AskPluginRequest, step: Int) -> [String: String]? {
        let current = Self.type(of: request.options) ?? .all
        return [Self.typeOption: current.next(step).rawValue]
    }

    private func output(_ items: [AskPluginItem], note: String?) -> AskPluginOutput {
        AskPluginOutput(body: items.map(\.title).joined(separator: "\n"), original: "", meta: [],
                        source: L("ask.plugin.files.source"), note: note, actions: [], items: items)
    }

    /// One file as a row: where it is and when it changed, and what its keys do.
    static func item(_ hit: AskFileHit) -> AskPluginItem {
        let url = hit.url
        let place = AskLauncherSearchSettings.abbreviate(hit.folder)
        var actions = [
            AskPluginAction(kind: .open(url), title: L("ask.quick.action.open"), symbol: "arrow.up.forward.app",
                            shortcut: .enter),
            AskPluginAction(kind: .reveal(url), title: L("ask.quick.action.reveal"), symbol: "folder", shortcut: .commandR),
            AskPluginAction(kind: .copy(hit.path), title: L("ask.quick.action.copyPath"), symbol: "link",
                            shortcut: .shiftCommandC)
        ]
        if hit.isFolder {
            actions.append(AskPluginAction(kind: .runWith("in:" + hit.name.filter { !$0.isWhitespace } + " "),
                                           title: L("ask.quick.action.searchIn"), symbol: "magnifyingglass",
                                           shortcut: nil))
        }
        return AskPluginItem(id: hit.path, title: hit.name, subtitle: place + " · " + AskQuickResultsView.relative(hit.modified),
                             icon: .fileIcon(url), actions: actions)
    }

    static func notice(_ text: String, symbol: String) -> AskPluginItem {
        AskPluginItem(id: "notice." + text, title: text, icon: .symbol(symbol), valid: false)
    }

    /// "Desktop, Documents and Downloads": the guarded folders by their Finder names.
    static func folderNames(_ paths: [String]) -> String {
        paths.map { AskFileLabels.folder($0) }.joined(separator: L("ask.plugin.files.separator"))
    }
}
