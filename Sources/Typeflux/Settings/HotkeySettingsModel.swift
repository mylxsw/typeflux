import Combine
import Foundation

/// State for Settings → Shortcuts: every global shortcut in one list. Built-in shortcuts are
/// saved through `StudioViewModel` (it keeps the older shortcut cards in step); feature and
/// keyword shortcuts are saved here.
@MainActor
final class HotkeySettingsModel: ObservableObject {
    @Published private(set) var rows: [HotkeyRow] = []
    @Published private(set) var options: [KeywordHotkeyOption] = []

    let settingsStore: SettingsStore
    private let workflows: AskWorkflowStore
    private var observers: [NSObjectProtocol] = []
    private var workflowSubscription: AnyCancellable?

    init(settingsStore: SettingsStore, workflows: AskWorkflowStore) {
        self.settingsStore = settingsStore
        self.workflows = workflows
        reload()
        for name in [Notification.Name.hotkeySettingsDidChange, .askLauncherSearchSettingsDidChange] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: settingsStore,
                                                                    queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.reload() }
                })
        }
        workflowSubscription = workflows.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.reload()
        }
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func reload() {
        let entries = AskKeywordListPresentation.workflowEntries(workflows.workflows) { [workflows] in
            workflows.isEnabled($0)
        }
        options = HotkeySettingsPresentation.options(
            keywords: settingsStore.effectiveAskLauncherKeywords(reserving: workflows.workflows), workflows: entries
        )
        rows = HotkeySettingsPresentation.rows(settingsStore: settingsStore, keywords: options.map(\.keyword))
    }

    func row(for target: HotkeyTarget) -> HotkeyRow? {
        rows.first { $0.target == target }
    }

    func keywordHotkey(_ id: UUID) -> KeywordHotkey? {
        settingsStore.keywordHotkeys.first { $0.id == id }
    }

    func check(_ binding: HotkeyBinding, for target: HotkeyTarget) -> HotkeyConflictChecker.Result {
        HotkeyConflictChecker.check(binding, for: target, among: settingsStore.hotkeyAssignments)
    }

    func message(for problem: HotkeyConflictChecker.Problem) -> String {
        HotkeyConflictMessages.describe(problem, in: settingsStore)
    }

    // MARK: - Feature shortcuts

    /// Saves a feature shortcut, or returns why it cannot be saved.
    @discardableResult
    func setHotkey(_ binding: HotkeyBinding, for action: AppHotkeyAction) -> String? {
        let result = check(binding, for: .action(action))
        if let problem = result.problem {
            return message(for: problem)
        }
        settingsStore.setHotkey(binding, for: action)
        return nil
    }

    func unsetHotkey(for action: AppHotkeyAction) {
        settingsStore.setHotkey(nil, for: action)
    }

    // MARK: - Keyword shortcuts

    /// Saves `hotkey` (new or edited). `takingFrom` is a keyword shortcut whose keys the user
    /// chose to move here; it keeps its row without keys.
    func save(_ hotkey: KeywordHotkey, takingFrom other: UUID? = nil) {
        var hotkeys = settingsStore.keywordHotkeys
        if let other, other != hotkey.id, let index = hotkeys.firstIndex(where: { $0.id == other }) {
            hotkeys[index].binding = nil
        }
        if let index = hotkeys.firstIndex(where: { $0.id == hotkey.id }) {
            hotkeys[index] = hotkey
        } else {
            hotkeys.append(hotkey)
        }
        settingsStore.keywordHotkeys = hotkeys
    }

    /// Re-records a keyword shortcut's keys from its row; returns why they cannot be used.
    @discardableResult
    func setBinding(_ binding: HotkeyBinding, forKeywordHotkey id: UUID) -> String? {
        guard var hotkey = keywordHotkey(id) else { return nil }
        let result = check(binding, for: .keyword(id))
        if let problem = result.problem {
            return message(for: problem)
        }
        hotkey.binding = binding
        save(hotkey)
        return nil
    }

    func setEnabled(_ enabled: Bool, forKeywordHotkey id: UUID) {
        guard var hotkey = keywordHotkey(id) else { return }
        hotkey.enabled = enabled
        save(hotkey)
    }

    func unsetBinding(forKeywordHotkey id: UUID) {
        guard var hotkey = keywordHotkey(id) else { return }
        hotkey.binding = nil
        save(hotkey)
    }

    func delete(_ id: UUID) {
        settingsStore.keywordHotkeys.removeAll { $0.id == id }
    }

    /// A copy of the shortcut without keys, so the user records new ones.
    func duplicate(_ id: UUID) -> KeywordHotkey? {
        guard var copy = keywordHotkey(id) else { return nil }
        copy.id = UUID()
        copy.binding = nil
        return copy
    }
}
