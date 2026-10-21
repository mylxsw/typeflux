import Foundation

/// State of Settings → Ring. Every change is saved at once.
@MainActor
final class RingSettingsModel: ObservableObject {
    @Published private(set) var configuration: RingConfiguration
    let settingsStore: SettingsStore
    private var observer: NSObjectProtocol?

    init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
        configuration = settingsStore.ringConfiguration
        observer = NotificationCenter.default.addObserver(forName: .ringSettingsDidChange, object: settingsStore,
                                                          queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func reload() {
        let stored = settingsStore.ringConfiguration
        if stored != configuration { configuration = stored }
    }

    var actions: [RingAction] {
        configuration.actions
    }

    func setStyle(_ style: RingStyle) {
        update { $0.style = style }
    }

    func setCenterTitle(_ title: String) {
        update { $0.centerTitle = String(title.prefix(RingConfiguration.centerTitleLimit)) }
    }

    /// Adds a new action or replaces the one with the same id. New actions past the limit are ignored.
    func save(_ action: RingAction) {
        update { configuration in
            if let index = configuration.actions.firstIndex(where: { $0.id == action.id }) {
                configuration.actions[index] = action
            } else if configuration.canAddAction {
                configuration.actions.append(action)
            }
        }
    }

    func delete(_ id: UUID) {
        update { $0.actions.removeAll { $0.id == id } }
    }

    func duplicate(_ id: UUID) {
        update { configuration in
            guard configuration.canAddAction, let index = configuration.actions.firstIndex(where: { $0.id == id })
            else { return }
            var copy = configuration.actions[index]
            copy.id = UUID()
            configuration.actions.insert(copy, at: index + 1)
        }
    }

    /// Moves `id` by `offset` slices (−1 is counter-clockwise), staying inside the ring.
    func move(_ id: UUID, by offset: Int) {
        guard let index = actions.firstIndex(where: { $0.id == id }) else { return }
        move(id, to: index + offset)
    }

    /// Moves `id` to `destination`, the index it has afterwards.
    func move(_ id: UUID, to destination: Int) {
        update { configuration in
            guard let index = configuration.actions.firstIndex(where: { $0.id == id }) else { return }
            let target = min(max(destination, 0), configuration.actions.count - 1)
            guard target != index else { return }
            let action = configuration.actions.remove(at: index)
            configuration.actions.insert(action, at: target)
        }
    }

    func resetActions() {
        update { $0.actions = RingConfiguration.defaultActions() }
    }

    private func update(_ change: (inout RingConfiguration) -> Void) {
        var next = configuration
        change(&next)
        guard next != configuration else { return }
        configuration = next
        settingsStore.ringConfiguration = next
    }
}

/// The action being edited in the sheet. Pure, so the editor's rules are tested directly.
struct RingActionDraft: Identifiable, Equatable {
    let id: UUID
    let isNew: Bool
    private(set) var type: RingActionType
    /// The chosen target for list-based types (feature, keyword, app, keys, system).
    private(set) var target: RingActionKind?
    /// Typed target for shortcut, URL and folder.
    private(set) var text = ""
    /// Typing a name keeps it; clearing it lets the next choice suggest one again.
    var title: String {
        didSet { titleEdited = !title.isEmpty }
    }

    var symbol: String
    private var titleEdited: Bool

    static func new() -> RingActionDraft {
        RingActionDraft(id: UUID(), isNew: true, type: .feature, target: nil, title: "",
                        symbol: RingActionType.feature.symbol, titleEdited: false)
    }

    init(editing action: RingAction) {
        self.init(id: action.id, isNew: false, type: action.kind.type, target: nil, title: action.title,
                  symbol: action.symbol, titleEdited: true)
        switch action.kind {
        case let .shortcut(name): text = name
        case let .url(url): text = url
        case let .folder(path): text = path
        default: target = action.kind
        }
    }

    private init(id: UUID, isNew: Bool, type: RingActionType, target: RingActionKind?, title: String,
                 symbol: String, titleEdited: Bool) {
        self.id = id
        self.isNew = isNew
        self.type = type
        self.target = target
        self.title = title
        self.symbol = symbol
        self.titleEdited = titleEdited
    }

    var usesTextTarget: Bool {
        [.shortcut, .url, .folder].contains(type)
    }

    mutating func setType(_ type: RingActionType) {
        guard type != self.type else { return }
        self.type = type
        target = nil
        text = ""
        symbol = type.symbol
        if !titleEdited { clearSuggestedTitle() }
    }

    /// Chooses a feature, keyword, app, key combination or system action and suggests its title.
    mutating func choose(_ kind: RingActionKind, title suggested: String, symbol: String? = nil) {
        guard kind.type == type else { return }
        target = kind
        if let symbol { self.symbol = symbol }
        suggest(suggested)
    }

    mutating func setText(_ text: String) {
        self.text = text
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch type {
        case .shortcut: suggest(trimmed)
        case .url: suggest(RingSettingsPresentation.title(forURL: trimmed) ?? "")
        case .folder: suggest((RingSettingsPresentation.expandedFolderPath(trimmed) as NSString).lastPathComponent)
        default: break
        }
    }

    /// A URL that was typed but is not a web page.
    var hasInvalidURL: Bool {
        type == .url && !text.trimmingCharacters(in: .whitespaces).isEmpty
            && RingSettingsPresentation.webURL(text) == nil
    }

    var kind: RingActionKind? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch type {
        case .shortcut: return trimmed.isEmpty ? nil : .shortcut(name: trimmed)
        case .url: return RingSettingsPresentation.webURL(trimmed) == nil ? nil : .url(trimmed)
        case .folder: return trimmed.isEmpty ? nil : .folder(path: trimmed)
        default: return target
        }
    }

    var canSave: Bool {
        kind != nil && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var action: RingAction? {
        guard canSave, let kind else { return nil }
        return RingAction(id: id, kind: kind, title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                          symbol: symbol)
    }

    private mutating func suggest(_ suggested: String) {
        guard !titleEdited else { return }
        title = suggested
        titleEdited = false
    }

    private mutating func clearSuggestedTitle() {
        title = ""
        titleEdited = false
    }
}
