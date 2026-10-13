import SwiftUI

struct HistorySettingsPage: View {
    @ObservedObject var viewModel: StudioViewModel
    @Binding var selectedID: UUID?

    var body: some View {
        Group {
            if let record = viewModel.displayedHistory.first(where: { $0.id == selectedID }) {
                HistorySettingsDetailView(record: record, viewModel: viewModel)
            } else if viewModel.displayedHistory.isEmpty {
                TypefluxEmptyState(L("history.empty"), systemImage: "clock",
                                   description: L("history.empty.description")) {
                    if !viewModel.searchQuery.isEmpty || viewModel.historyFilter != .all {
                        TypefluxButton(L("history.filter.reset")) {
                            viewModel.searchQuery = ""
                            viewModel.historyFilter = .all
                        }
                    }
                }
            } else {
                List {
                    ForEach(viewModel.groupedHistory) { section in
                        Section(section.id) {
                            ForEach(section.records) { record in
                                TypefluxNavigationRow(record.previewText,
                                                      systemImage: record.hasFailure ? "exclamationmark" : "waveform",
                                                      color: record.hasFailure ? TypefluxColor.danger
                                                          .color : .accentColor,
                                                      detail: record.timestampText) {
                                    selectedID = record.id
                                }
                                .lineLimit(2)
                                .accessibilityIdentifier("history.open.\(record.id)")
                                .contextMenu { HistorySettingsActions(record: record, viewModel: viewModel) }
                            }
                        }
                    }
                    if viewModel.isLoadingMoreHistory {
                        ProgressView(L("history.loadingMore"))
                    } else if viewModel.canLoadMoreHistory {
                        TypefluxButton(L("history.action.loadMore")) { viewModel.loadMoreHistoryIfNeeded() }
                            .onAppear { viewModel.loadMoreHistoryIfNeeded() }
                    }
                    Section {
                        Label(L("history.privacy.subtitle"), systemImage: "lock.fill")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                .listStyle(.inset)
                .accessibilityIdentifier("history.list")
            }
        }
        .background(TypefluxColor.contentBackground.color)
    }
}
