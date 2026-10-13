import SwiftUI

/// Overview and History offer the same route and context actions for a record.
struct HistorySettingsNavigationRow: View {
    let record: HistoryPresentationRecord
    @ObservedObject var viewModel: StudioViewModel
    let open: () -> Void

    var body: some View {
        TypefluxNavigationRow(record.previewText,
                              systemImage: record.hasFailure ? "exclamationmark" : "waveform",
                              color: record.hasFailure ? TypefluxColor.danger.color : TypefluxColor.accent.color,
                              detail: record.timestampText, action: open)
            .lineLimit(2)
            .accessibilityIdentifier("history.open.\(record.id)")
            .contextMenu { HistorySettingsActions(record: record, viewModel: viewModel) }
    }
}
