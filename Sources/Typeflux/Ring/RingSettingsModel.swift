import Foundation

/// State of Settings → Ring. Every change is saved at once.
@MainActor
final class RingSettingsModel: ObservableObject {
    static let undoLimit = 20

    @Published private(set) var configuration: RingConfiguration
    /// What the undo bar describes; nil once it is dismissed or undone.
    @Published private(set) var lastChange: String?
    private var undoStack: [RingUndoStep] = []
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
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func reload() {
        let stored = settingsStore.ringConfiguration
        if stored != configuration {
            configuration = stored
        }
    }

    var actions: [RingAction] {
        configuration.actions
    }

    func setHoverSoundEnabled(_ enabled: Bool) {
        update { $0.hoverSoundEnabled = enabled }
    }

    func setStyle(_ style: RingStyle) {
        update { $0.style = style }
    }

    func setCenterTitle(_ title: String) {
        update { $0.centerTitle = String(title.prefix(RingConfiguration.centerTitleLimit)) }
    }

    // MARK: - Slices

    /// Puts `action` at `index` (clamped). Ignored when the ring is full or the id is already used.
    @discardableResult
    func insert(_ action: RingAction, at index: Int) -> Bool {
        guard configuration.canAddAction, !actions.contains(where: { $0.id == action.id }) else { return false }
        record(L("ring.undo.added", action.title))
        update { $0.actions.insert(action, at: min(max(index, 0), $0.actions.count)) }
        return true
    }

    /// Changes one slice in place: renaming, a new icon or an edited target. Not recorded for undo.
    func edit(_ id: UUID, _ change: (inout RingAction) -> Void) {
        update { configuration in
            guard let index = configuration.actions.firstIndex(where: { $0.id == id }) else { return }
            change(&configuration.actions[index])
        }
    }

    /// Points a slice at something else and keeps its place. A name or icon the user chose is kept;
    /// one that was still the default follows the new target.
    func replace(_ id: UUID, with item: RingLibraryItem,
                 keywordName: (String, String) -> String? = { _, _ in nil }) {
        guard let current = actions.first(where: { $0.id == id }), current.kind.pickerKey != item.kind.pickerKey
        else { return }
        record(L("ring.undo.replaced", current.title))
        edit(id) { action in
            if action.title == RingActionLibrary.defaultTitle(for: action.kind, keywordName: keywordName) {
                action.title = item.title
            }
            if action.symbol == RingActionLibrary.defaultSymbol(for: action.kind) || item.type == .app {
                action.symbol = item.symbol
            }
            action.kind = item.kind
        }
    }

    func delete(_ id: UUID) {
        guard let action = actions.first(where: { $0.id == id }) else { return }
        record(L("ring.undo.deleted", action.title))
        update { $0.actions.removeAll { $0.id == id } }
    }

    /// Copies a slice into the next place and returns the copy's id.
    @discardableResult
    func duplicate(_ id: UUID) -> UUID? {
        guard configuration.canAddAction, let index = actions.firstIndex(where: { $0.id == id }) else { return nil }
        var copy = actions[index]
        copy.id = UUID()
        record(L("ring.undo.duplicated", copy.title))
        update { $0.actions.insert(copy, at: index + 1) }
        return copy.id
    }

    /// Moves `id` by `offset` slices around the ring (−1 is counter-clockwise), wrapping past the top.
    func move(_ id: UUID, by offset: Int) {
        let count = actions.count
        guard count > 1, let index = actions.firstIndex(where: { $0.id == id }) else { return }
        move(id, to: ((index + offset) % count + count) % count)
    }

    /// Moves `id` to `destination`, the index it has afterwards.
    func move(_ id: UUID, to destination: Int) {
        guard let index = actions.firstIndex(where: { $0.id == id }), !actions.isEmpty else { return }
        let target = min(max(destination, 0), actions.count - 1)
        guard target != index else { return }
        record(L("ring.undo.moved", actions[index].title))
        update { configuration in
            let action = configuration.actions.remove(at: index)
            configuration.actions.insert(action, at: target)
        }
    }

    func resetActions() {
        guard actions != RingConfiguration.defaultActions() else { return }
        record(L("ring.undo.reset"))
        update { $0.actions = RingConfiguration.defaultActions() }
    }

    // MARK: - Undo

    var canUndo: Bool {
        !undoStack.isEmpty
    }

    /// Restores the slices from before the last recorded change.
    func undo() {
        guard let step = undoStack.popLast() else { return }
        update { $0.actions = step.actions }
        lastChange = nil
    }

    /// Hides the undo bar; the step can still be undone.
    func dismissLastChange() {
        lastChange = nil
    }

    private func record(_ message: String) {
        undoStack.append(RingUndoStep(message: message, actions: actions))
        if undoStack.count > Self.undoLimit {
            undoStack.removeFirst(undoStack.count - Self.undoLimit)
        }
        lastChange = message
    }

    private func update(_ change: (inout RingConfiguration) -> Void) {
        var next = configuration
        change(&next)
        guard next != configuration else { return }
        configuration = next
        settingsStore.ringConfiguration = next
    }
}

/// The slices before a change that can be undone.
private struct RingUndoStep {
    let message: String
    let actions: [RingAction]
}
