import Foundation

/// What Settings → Ring shows beside the slices and how clicks, drags and keys change it.
/// Kept out of the view so every transition is tested directly.
@MainActor
final class RingStudioController: ObservableObject {
    @Published private var inspector: RingInspectorState = .overview
    /// The library item under the pointer, drawn in the gap or on the slice being replaced.
    @Published var preview: RingLibraryItem?
    @Published var drag: RingStudioLayout.Drag?
    /// Trying the ring shows the overview; nothing runs.
    @Published var isTrying = false {
        didSet {
            if isTrying, oldValue != isTrying {
                show(.overview)
            }
        }
    }

    let model: RingSettingsModel

    init(model: RingSettingsModel) {
        self.model = model
    }

    private var actions: [RingAction] {
        model.actions
    }

    /// The inspector state, corrected for slices that changed elsewhere.
    var state: RingInspectorState {
        inspector.resolved(for: actions)
    }

    // MARK: - Canvas

    var slots: [RingStudioSlot] {
        RingStudioLayout.slots(actions: actions, state: state, preview: preview, drag: drag)
    }

    var selectedIndex: Int? {
        RingStudioLayout.selectedIndex(in: slots, state: state, drag: drag)
    }

    var canvasMode: RingStudioCanvas.Mode {
        switch state {
        case .overview: .overview
        case .edit: .editing
        case .library(.insert): .inserting
        case .library(.replace): .replacing
        }
    }

    /// ⊕ is hidden while a gap is already open.
    var insertionIndexes: [Int] {
        if case .library(.insert) = state {
            return []
        }
        return RingStudioLayout.insertionIndexes(count: actions.count)
    }

    // MARK: - Transitions

    func show(_ next: RingInspectorState) {
        preview = nil
        if case .library = next, isTrying {
            isTrying = false
        }
        inspector = next.resolved(for: actions)
    }

    /// Closes the library: back to the slice being replaced, otherwise to the overview.
    func cancelLibrary() {
        if case let .library(.replace(id)) = state {
            show(.edit(id))
        } else {
            show(.overview)
        }
    }

    /// A click on the canvas outside every slice.
    func clickBackground() {
        if case .library = state {
            cancelLibrary()
        } else {
            show(.overview)
        }
    }

    func pick(_ item: RingLibraryItem, keywordName: (String, String) -> String? = { _, _ in nil }) {
        switch state {
        case let .library(.insert(index)):
            let action = item.action()
            if model.insert(action, at: index) {
                show(.edit(action.id))
            }
        case let .library(.replace(id)):
            model.replace(id, with: item, keywordName: keywordName)
            show(.edit(id))
        default:
            break
        }
    }

    /// A target typed or recorded in the inspector. The name follows it while it is the default.
    func retarget(_ id: UUID, to kind: RingActionKind, keywordName: (String, String) -> String? = { _, _ in nil }) {
        model.edit(id) { action in
            if action.title == RingActionLibrary.defaultTitle(for: action.kind, keywordName: keywordName) {
                action.title = RingActionLibrary.defaultTitle(for: kind, keywordName: keywordName)
            }
            action.kind = kind
        }
    }

    func move(_ id: UUID, to index: Int) {
        model.move(id, to: index)
        show(.edit(id))
    }

    func duplicate(_ id: UUID) {
        if let copy = model.duplicate(id) {
            show(.edit(copy))
        }
    }

    func delete(_ id: UUID) {
        model.delete(id)
        show(.overview)
    }

    func resetActions() {
        model.resetActions()
        show(.overview)
    }

    func undo() {
        model.undo()
        inspector = inspector.resolved(for: actions)
    }

    /// Keys pressed while the ring has focus.
    func handle(_ key: RingStudioKey) {
        let selected = state.selectedID.flatMap { id in actions.firstIndex { $0.id == id } }
        let selectedID = selected.map { actions[$0].id }
        switch key {
        case .previous, .next:
            step(from: selected, by: key == .next ? 1 : -1)
        case .movePrevious, .moveNext:
            withSelection(selectedID) { model.move($0, by: key == .moveNext ? 1 : -1) }
        case .delete:
            withSelection(selectedID, delete)
        case .edit:
            withSelection(selectedID) { show(.edit($0)) }
        case .insert:
            show(.library(.insert(index: selected.map { $0 + 1 } ?? actions.count)))
        case .escape:
            escape()
        case let .select(index):
            step(to: index)
        }
    }

    /// Keys that act on the selected slice do nothing without one.
    private func withSelection(_ id: UUID?, _ body: (UUID) -> Void) {
        if let id {
            body(id)
        }
    }

    private func escape() {
        if isTrying {
            isTrying = false
        } else {
            clickBackground()
        }
    }

    private func step(to index: Int) {
        guard actions.indices.contains(index) else { return }
        show(.edit(actions[index].id))
    }

    /// Selects the neighbour of `selected`, or the first or last slice when nothing is selected.
    private func step(from selected: Int?, by offset: Int) {
        let count = actions.count
        guard count > 0 else { return }
        let index = selected.map { ($0 + offset + count) % count } ?? (offset > 0 ? 0 : count - 1)
        show(.edit(actions[index].id))
    }
}
