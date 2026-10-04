import SwiftUI
import TypefluxChat

struct ChatRootView: View {
    @Bindable var store: ChatStore
    @State private var compactColumn: NavigationSplitViewColumn = .sidebar
    @State private var showSignOut = false

    var body: some View {
        NavigationSplitView(preferredCompactColumn: $compactColumn) {
            List {
                if store.isSynthetic {
                    Label("Synthetic preview · No network", systemImage: "testtube.2")
                        .font(.caption).foregroundStyle(.orange)
                }
                Section {
                    ForEach(store.conversations) { item in
                        Button {
                            compactColumn = .detail
                            Task { await store.select(item.id) }
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(item.title.isEmpty ? "New conversation" : item.title)
                                    .font(.body.weight(.medium)).foregroundStyle(.primary).lineLimit(2)
                                Text(item.updatedAt, style: .date).font(.caption).foregroundStyle(.secondary)
                            }.padding(.vertical, 5)
                        }
                    }
                    if store.hasMore {
                        Button("Load more") { Task { await store.loadMore() } }.disabled(store.isLoading)
                    }
                }
                if let error = store.errorMessage {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
            .overlay {
                if store.conversations.isEmpty, !store.isLoading {
                    ContentUnavailableView("Start a conversation", systemImage: "bubble.left.and.bubble.right",
                                           description: Text(
                                               "Ask a question or continue a conversation from your Mac."
                                           ))
                }
            }
            .refreshable { await store.refreshHome() }
            .navigationTitle("Typeflux")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showSignOut = true } label: { Image(systemName: "person.crop.circle") }
                        .accessibilityLabel("Account")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        store.newConversation()
                        compactColumn = .detail
                    } label: { Image(systemName: "square.and.pencil") }
                        .accessibilityLabel("New conversation").accessibilityIdentifier("chat.new")
                }
            }
            .confirmationDialog(store.email, isPresented: $showSignOut, titleVisibility: .visible) {
                Button("Sign out", role: .destructive) { Task { await store.signOut() } }
            }
        } detail: {
            ChatDetailView(store: store)
        }
    }
}
