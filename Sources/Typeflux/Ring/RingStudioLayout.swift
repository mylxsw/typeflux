import Foundation

/// Where the library puts what is picked.
enum RingLibraryTarget: Hashable {
    /// A new slice at this index.
    case insert(index: Int)
    /// A new target for an existing slice, which keeps its place.
    case replace(UUID)
}

/// What the panel beside the ring shows.
enum RingInspectorState: Equatable {
    case overview
    case library(RingLibraryTarget)
    case edit(UUID)

    /// The state to show for `actions`: an empty ring always opens the library, and a slice
    /// that no longer exists falls back to the overview.
    func resolved(for actions: [RingAction]) -> RingInspectorState {
        if actions.isEmpty {
            return .library(.insert(index: 0))
        }
        switch self {
        case .overview:
            return self
        case let .edit(id):
            return actions.contains { $0.id == id } ? self : .overview
        case let .library(.replace(id)):
            return actions.contains { $0.id == id } ? self : .overview
        case let .library(.insert(index)):
            guard actions.count < RingConfiguration.maxActions else { return .overview }
            return .library(.insert(index: min(max(index, 0), actions.count)))
        }
    }

    var selectedID: UUID? {
        switch self {
        case let .edit(id), let .library(.replace(id)): id
        default: nil
        }
    }
}

/// One slice as drawn in the studio.
struct RingStudioSlot: Identifiable, Equatable {
    enum Role: Equatable {
        case action
        /// The gap opened by ⊕ before anything is picked.
        case placeholder
        /// What the gap, or the slice being replaced, would become.
        case preview
    }

    static let placeholderID = UUID(uuidString: "52494E47-0000-4000-8000-0000000000FF") ?? UUID()

    let action: RingAction
    let role: Role

    var id: UUID {
        action.id
    }
}

/// The ring the studio draws for a state. Pure, so insertion, preview and dragging are tested directly.
enum RingStudioLayout {
    struct Drag: Equatable {
        let id: UUID
        var destination: Int
    }

    static func slots(actions: [RingAction], state: RingInspectorState, preview: RingLibraryItem?,
                      drag: Drag? = nil) -> [RingStudioSlot] {
        var slots = actions.map { RingStudioSlot(action: $0, role: .action) }
        if let drag, let from = slots.firstIndex(where: { $0.id == drag.id }) {
            let slot = slots.remove(at: from)
            slots.insert(slot, at: min(max(drag.destination, 0), slots.count))
        }
        switch state {
        case let .library(.insert(index)):
            let gap = preview.map {
                RingStudioSlot(action: $0.action(id: RingStudioSlot.placeholderID), role: .preview)
            }
                ?? RingStudioSlot(action: RingAction(id: RingStudioSlot.placeholderID, kind: .feature(.dictation),
                                                     title: L("ring.studio.newAction"), symbol: "plus"),
                                  role: .placeholder)
            slots.insert(gap, at: min(max(index, 0), slots.count))
        case let .library(.replace(id)):
            if let preview, let index = slots.firstIndex(where: { $0.id == id }) {
                var action = preview.action(id: id)
                if preview.type != .app {
                    action.symbol = preview.symbol
                }
                slots[index] = RingStudioSlot(action: action, role: .preview)
            }
        default:
            break
        }
        return slots
    }

    /// The slice drawn as selected: the one being edited, replaced or dragged, or the gap.
    static func selectedIndex(in slots: [RingStudioSlot], state: RingInspectorState, drag: Drag?) -> Int? {
        if let drag {
            return slots.firstIndex { $0.id == drag.id }
        }
        if case .library(.insert) = state {
            return slots.firstIndex { $0.role != .action }
        }
        guard let id = state.selectedID else { return nil }
        return slots.firstIndex { $0.id == id }
    }

    /// The indexes ⊕ can insert at: one between each pair of neighbours, none when full.
    static func insertionIndexes(count: Int) -> [Int] {
        guard count > 0, count < RingConfiguration.maxActions else { return [] }
        return Array(1 ... count)
    }
}
