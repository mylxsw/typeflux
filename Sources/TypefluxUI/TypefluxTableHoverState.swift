import Foundation

/// Cell membership prevents a late exit event from hiding another hovered cell in the same row.
struct TypefluxTableHoverState {
    private var cells: [UUID: AnyHashable] = [:]

    mutating func update(cell: UUID, row: AnyHashable, hovering: Bool) {
        if hovering { cells[cell] = row } else { cells.removeValue(forKey: cell) }
    }

    mutating func updateRow(cell: UUID, row: AnyHashable) {
        if cells[cell] != nil { cells[cell] = row }
    }

    func isHovered(_ row: AnyHashable) -> Bool { cells.values.contains(row) }
}
