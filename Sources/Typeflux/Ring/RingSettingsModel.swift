import Foundation

/// Which actions Settings → Ring edits: the global ones or one app's.
enum RingSettingsScope: Hashable {
    case global
    case app(UUID)
}

/// State of Settings → Ring. Every change is saved at once. Slice changes apply to the actions
/// of the current scope.
@MainActor
final class RingSettingsModel: ObservableObject {
    static let undoLimit = 20

    @Published private(set) var configuration: RingConfiguration
    @Published private(set) var scope = RingSettingsScope.global
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
        if case .app = scope, profile == nil {
            scope = .global
        }
    }

    /// The actions of the current scope.
    var actions: [RingAction] {
        profile?.actions ?? configuration.actions
    }

    var canAddAction: Bool {
        actions.count < RingConfiguration.maxActions
    }

    /// The profile being edited, or nil for the global actions.
    var profile: RingAppProfile? {
        guard case let .app(id) = scope else { return nil }
        return configuration.appProfiles.first { $0.id == id }
    }

    func select(_ scope: RingSettingsScope) {
        if case let .app(id) = scope, !configuration.appProfiles.contains(where: { $0.id == id }) {
            self.scope = .global
        } else {
            self.scope = scope
        }
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
        guard canAddAction, !actions.contains(where: { $0.id == action.id }) else { return false }
        record(L("ring.undo.added", action.title))
        updateActions { $0.insert(action, at: min(max(index, 0), $0.count)) }
        return true
    }

    /// Changes one slice in place: renaming, a new icon or an edited target. Not recorded for undo.
    func edit(_ id: UUID, _ change: (inout RingAction) -> Void) {
        updateActions { actions in
            guard let index = actions.firstIndex(where: { $0.id == id }) else { return }
            change(&actions[index])
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
        updateActions { $0.removeAll { $0.id == id } }
    }

    /// Copies a slice into the next place and returns the copy's id.
    @discardableResult
    func duplicate(_ id: UUID) -> UUID? {
        guard canAddAction, let index = actions.firstIndex(where: { $0.id == id }) else { return nil }
        var copy = actions[index]
        copy.id = UUID()
        record(L("ring.undo.duplicated", copy.title))
        updateActions { $0.insert(copy, at: index + 1) }
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
        updateActions { actions in
            let action = actions.remove(at: index)
            actions.insert(action, at: target)
        }
    }

    /// Restores the default global actions. App profiles have no defaults.
    func resetActions() {
        guard scope == .global, actions != RingConfiguration.defaultActions() else { return }
        record(L("ring.undo.reset"))
        update { $0.actions = RingConfiguration.defaultActions() }
    }

    // MARK: - App profiles

    /// Adds a switched-on profile, optionally seeded with presets. An app that already has one
    /// is selected instead. Returns the profile's id.
    @discardableResult
    func addProfile(bundleIdentifier: String, appName: String, usePreset: Bool = false) -> UUID {
        if let existing = configuration.appProfiles.first(where: { $0.bundleIdentifier == bundleIdentifier }) {
            scope = .app(existing.id)
            return existing.id
        }
        let profile = RingAppProfile(bundleIdentifier: bundleIdentifier, appName: appName,
                                     actions: usePreset ? RingAppShortcutCatalog.defaultActions(
                                         for: bundleIdentifier, appName: appName
                                     ) : [])
        record(L("ring.undo.addedApp", appName))
        update { $0.appProfiles.append(profile) }
        scope = .app(profile.id)
        return profile.id
    }

    /// Fill available slots with this app's presets, preserving all custom actions and ordering.
    func addAppPresets() {
        guard let profile, canAddAction else { return }
        let items = RingAppShortcutCatalog.items(for: profile.bundleIdentifier, appName: profile.appName)
            .filter { !RingActionLibrary.contains($0, in: actions) }
            .prefix(RingConfiguration.maxActions - actions.count)
        guard !items.isEmpty else { return }
        record(L("ring.presets.added"))
        updateActions { $0.append(contentsOf: items.map { $0.action() }) }
    }

    /// Removes a profile; its app gets the global actions again. Back to the global scope.
    func removeProfile(_ id: UUID) {
        guard let profile = configuration.appProfiles.first(where: { $0.id == id }) else { return }
        record(L("ring.undo.removedApp", profile.appName))
        update { $0.appProfiles.removeAll { $0.id == id } }
        if scope == .app(id) {
            scope = .global
        }
    }

    /// Switching a profile off keeps its actions. The switch itself is the way back, so no undo.
    func setProfileEnabled(_ id: UUID, _ enabled: Bool) {
        update { configuration in
            guard let index = configuration.appProfiles.firstIndex(where: { $0.id == id }) else { return }
            configuration.appProfiles[index].isEnabled = enabled
        }
    }

    /// Replaces a profile's actions with copies of the global ones. Copies get new ids, so a
    /// selection on the ring always names one action.
    func copyGlobalActions(into id: UUID) {
        guard configuration.appProfiles.contains(where: { $0.id == id }), !configuration.actions.isEmpty else { return }
        record(L("ring.undo.copiedGlobal", configuration.actions.count))
        update { configuration in
            guard let index = configuration.appProfiles.firstIndex(where: { $0.id == id }) else { return }
            configuration.appProfiles[index].actions = configuration.actions.map { action in
                var copy = action
                copy.id = UUID()
                return copy
            }
        }
    }

    // MARK: - Undo

    var canUndo: Bool {
        !undoStack.isEmpty
    }

    /// Restores the actions and app profiles from before the last recorded change, and shows the
    /// scope where it happened.
    func undo() {
        guard let step = undoStack.popLast() else { return }
        update { configuration in
            // The on/off switch is not an undoable change; keep where each profile stands now.
            let enabled = Dictionary(configuration.appProfiles.map { ($0.id, $0.isEnabled) },
                                     uniquingKeysWith: { first, _ in first })
            configuration.actions = step.actions
            configuration.appProfiles = step.appProfiles.map { profile in
                var restored = profile
                restored.isEnabled = enabled[profile.id] ?? profile.isEnabled
                return restored
            }
        }
        select(step.scope)
        lastChange = nil
    }

    /// Hides the undo bar; the step can still be undone.
    func dismissLastChange() {
        lastChange = nil
    }

    private func record(_ message: String) {
        undoStack.append(RingUndoStep(message: message, actions: configuration.actions,
                                      appProfiles: configuration.appProfiles, scope: scope))
        if undoStack.count > Self.undoLimit {
            undoStack.removeFirst(undoStack.count - Self.undoLimit)
        }
        lastChange = message
    }

    /// Changes the actions of the current scope.
    private func updateActions(_ change: (inout [RingAction]) -> Void) {
        let scope = scope
        update { configuration in
            if case let .app(id) = scope {
                guard let index = configuration.appProfiles.firstIndex(where: { $0.id == id }) else { return }
                change(&configuration.appProfiles[index].actions)
            } else {
                change(&configuration.actions)
            }
        }
    }

    private func update(_ change: (inout RingConfiguration) -> Void) {
        var next = configuration
        change(&next)
        guard next != configuration else { return }
        configuration = next
        settingsStore.ringConfiguration = next
    }
}

/// Everything a change that can be undone may touch, from before the change.
private struct RingUndoStep {
    let message: String
    let actions: [RingAction]
    let appProfiles: [RingAppProfile]
    let scope: RingSettingsScope
}
