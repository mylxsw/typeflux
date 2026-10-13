import SwiftUI

struct HistorySettingsPage: View {
    @ObservedObject var viewModel: StudioViewModel
    @ObservedObject var navigation: HistorySettingsNavigation

    var body: some View {
        Group {
            if let record = viewModel.displayedHistory.first(where: { $0.id == navigation.selectedID }) {
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
                                HistorySettingsNavigationRow(record: record, viewModel: viewModel) {
                                    navigation.open(record.id)
                                }
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
