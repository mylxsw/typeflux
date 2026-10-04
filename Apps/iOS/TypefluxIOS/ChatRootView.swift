import SwiftUI
import TypefluxChat

struct ChatRootView: View {
    @Bindable var store: ChatStore
    @Bindable var preferences: ChatPreferences
    @State private var compactColumn: NavigationSplitViewColumn = .sidebar
    @State private var showSettings = false
    @State private var search = ""
    @State private var collapsed: Set<ChatHistorySection> = []

    var body: some View {
        NavigationSplitView(preferredCompactColumn: $compactColumn) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    if store.isSynthetic {
                        Label("Synthetic preview · No network", systemImage: "testtube.2")
                            .font(.caption2).foregroundStyle(.secondary).padding(.bottom, 8)
                    }
                    ForEach(ChatHistorySection.allCases) { section in
                        let items = ChatPresentation.history(store.conversations, matching: search, section: section)
                        if !items.isEmpty {
                            sectionHeader(section)
                            if !collapsed.contains(section) {
                                ForEach(items) { item in historyRow(item) }
                            }
                        }
                    }
                    if store.hasMore {
                        Button("Load more") { Task { await store.loadMore() } }
                            .font(.caption).frame(maxWidth: .infinity, minHeight: 44)
                            .disabled(store.isLoading).accessibilityIdentifier("chat.loadMore")
                    }
                    if let error = store.errorMessage {
                        Text(NSLocalizedString(error, comment: "Chat error"))
                            .font(.caption).foregroundStyle(.red).padding(8)
                    }
                }.padding(.horizontal, 12).padding(.vertical, 8)
            }
            .background(ChatTheme.background)
            .safeAreaInset(edge: .top, spacing: 0) { searchField }
            .safeAreaInset(edge: .bottom, spacing: 0) { accountFooter }
            .overlay {
                if store.conversations.isEmpty, !store.isLoading {
                    ContentUnavailableView("Start a conversation", systemImage: "bubble.left.and.bubble.right",
                                           description: Text(
                                               "Ask a question or continue a conversation from your Mac."
                                           ))
                                           .allowsHitTesting(false)
                } else if !search.isEmpty,
                          !store.conversations.contains(where: { ChatPresentation.matches($0, query: search) }) {
                    ContentUnavailableView.search(text: search).allowsHitTesting(false)
                }
            }
            .refreshable { await store.refreshHome() }
            .navigationTitle("Ask anything")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: newConversation) { Image(systemName: "square.and.pencil") }
                        .accessibilityLabel("New conversation").accessibilityIdentifier("chat.new")
                }
            }
            .sheet(isPresented: $showSettings) {
                ChatSettingsView(store: store, preferences: preferences)
            }
        } detail: {
            ChatDetailView(store: store, onNewConversation: newConversation)
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search conversations", text: $search)
                .font(.subheadline).accessibilityIdentifier("chat.search")
            if !search.isEmpty {
                Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .foregroundStyle(.secondary).accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 12).frame(minHeight: 44)
        .background(ChatTheme.controlSurface.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 16).padding(.bottom, 10).background(ChatTheme.background)
    }

    private var accountFooter: some View {
        HStack {
            Text(store.email).font(.caption.weight(.medium)).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            Button { showSettings = true } label: {
                Image(systemName: "gearshape").foregroundStyle(.secondary).frame(width: 44, height: 44)
            }.accessibilityLabel("Settings").accessibilityIdentifier("chat.account")
        }
        .padding(.horizontal, 18).padding(.top, 4)
        .background(ChatTheme.background)
        .overlay(alignment: .top) { Divider().padding(.horizontal, 18) }
    }

    private func sectionHeader(_ section: ChatHistorySection) -> some View {
        Button {
            if collapsed.contains(section) {
                collapsed.remove(section)
            } else {
                collapsed.insert(section)
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: collapsed.contains(section) ? "chevron.right" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                Text(NSLocalizedString(section.title, comment: "History section")).font(.caption)
                Spacer()
            }.foregroundStyle(.secondary).padding(.horizontal, 8).frame(minHeight: 38)
        }.buttonStyle(.plain).accessibilityIdentifier("chat.history.\(section.title)")
    }

    private func historyRow(_ item: ChatConversationSummary) -> some View {
        Button {
            compactColumn = .detail
            Task { await store.select(item.id) }
        } label: {
            HStack(spacing: 9) {
                if store.selectedID == item.id, store.isRunning {
                    Circle().fill(ChatTheme.accent).frame(width: 5, height: 5)
                        .accessibilityLabel("Running")
                }
                Text(item.title.isEmpty ? NSLocalizedString("New conversation", comment: "") : item.title)
                    .font(.subheadline.weight(store.selectedID == item.id ? .semibold : .regular))
                    .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                Text(item.updatedAt, format: ChatPresentation.historySection(for: item.updatedAt) == .earlier
                    ? .dateTime.month(.twoDigits).day(.twoDigits) : .dateTime.hour().minute())
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .foregroundStyle(.primary).padding(.horizontal, 12).frame(minHeight: 50)
            .background(store.selectedID == item.id ? ChatTheme.accentSoft : .clear,
                        in: RoundedRectangle(cornerRadius: 12))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain).accessibilityIdentifier("chat.history.\(item.id)")
    }

    private func newConversation() {
        store.newConversation()
        compactColumn = .detail
    }
}
