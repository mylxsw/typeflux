import SwiftUI

/// Each settings window owns the same selection used by its rows, detail and Back control.
@MainActor
final class HistorySettingsNavigation: ObservableObject {
    @Published var selectedID: UUID?

    init(selectedID: UUID? = nil) { self.selectedID = selectedID }

    func open(_ id: UUID) { selectedID = id }
    func showList() { selectedID = nil }
}
