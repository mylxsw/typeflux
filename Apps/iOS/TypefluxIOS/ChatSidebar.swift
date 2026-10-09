import SwiftUI
import TypefluxChat

/// The Mac sidebar on a phone: title and compose, search, Today / Yesterday /
/// Earlier, and the account footer with plan and settings.
struct ChatSidebar: View {
    @Bindable var store: ChatStore
    var onSelect: (String) -> Void
    var onNewConversation: () -> Void
    var onSettings: () -> Void
    @State private var search = ""
    @State private var pendingDelete: ChatConversationSummary?
    @FocusState private var searchFocused: Bool

    private var isSearching: Bool {
        !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            searchField.padding(.horizontal, 4).padding(.top, 10).padding(.bottom, 4)
            List {
                if !store.isAuthenticated {
                    guestRow(symbol: "person.crop.circle.badge.plus", tint: ChatTheme.accentText,
                             title: Text("Sign in to sync your conversations")) { store.showsLogin = true }
                    Section {
                        ForEach(ChatExample.allCases) { example in
                            guestRow(symbol: "sparkles", tint: .primary, title: Text(verbatim: example.title)) {
                                store.example = example; onSelect("example:" + example.id)
                            }
                        }
                    } header: {
                        Text("Examples").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(ChatTheme.tertiary)
                            .textCase(nil)
                    }
                }
                if store.isSynthetic {
                    Label("Synthetic preview · No network", systemImage: "testtube.2")
                        .font(.caption2).foregroundStyle(.secondary)
                        .listRowBackground(Color.clear).listRowSeparator(.hidden)
                }
                ForEach(ChatHistorySection.allCases) { section in
                    let items = ChatPresentation.history(store.conversations, matching: search, section: section)
                    if !items.isEmpty {
                        Section {
                            ForEach(items) { item in row(item) }
                        } header: {
                            Text(NSLocalizedString(section.title, comment: "History section"))
                                .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(ChatTheme.tertiary)
                                .textCase(nil)
                                .accessibilityIdentifier("chat.history.\(section.title)")
                        }
                    }
                }
                if store.hasMore, !isSearching {
                    Button("Load more") { Task { await store.loadMore() } }
                        .font(.footnote).frame(maxWidth: .infinity, minHeight: 44)
                        .disabled(store.isLoading).accessibilityIdentifier("chat.loadMore")
                        .listRowBackground(Color.clear).listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 40)
            .refreshable { await store.refreshHome() }
            .overlay { emptyOverlay }
            footer
        }
        .padding(.top, 18).padding(.horizontal, 8).padding(.bottom, 10)
        // A nearly opaque panel: the conversation behind must not show through the list.
        .background {
            ChatTheme.background.ignoresSafeArea()
                .shadow(color: .black.opacity(0.18), radius: 16, x: 6)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.sidebar")
        .confirmationDialog(Text("Delete this conversation?"), isPresented: Binding(
            get: { pendingDelete != nil }, set: {
                if !$0 {
                    pendingDelete = nil
                }
            }
        ), titleVisibility: .visible, presenting: pendingDelete) { item in
            Button("Delete", role: .destructive) {
                Task { await store.deleteConversation(item.id) }
            }
            .accessibilityIdentifier("chat.history.confirmDelete")
        } message: { _ in
            Text("It is removed from every device signed in to this account.")
        }
    }

    private var header: some View {
        HStack {
            Text("Ask anything").font(.system(size: 22, weight: .bold))
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Button(action: onNewConversation) {
                Label("New conversation", systemImage: "square.and.pencil")
                    .labelStyle(.iconOnly).font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(ChatTheme.accent).frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("New conversation")).accessibilityIdentifier("chat.new")
        }
        .padding(.leading, 12).padding(.trailing, 2)
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").font(.system(size: 14)).foregroundStyle(ChatTheme.tertiary)
            TextField("Search conversations", text: $search)
                .font(.system(size: 15)).accessibilityIdentifier("chat.search")
                .focused($searchFocused).submitLabel(.search)
                .onSubmit { searchFocused = false }
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            if !search.isEmpty {
                Button { search = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(ChatTheme.tertiary)
                        .frame(width: 36, height: 38)
                }
                .accessibilityLabel("Clear search").accessibilityIdentifier("chat.search.clear")
            }
        }
        .padding(.leading, 11).frame(height: 38)
        .background(ChatTheme.fill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func row(_ item: ChatConversationSummary) -> some View {
        let selected = store.selectedID == item.id
        return Button { onSelect(item.id) } label: {
            HStack(spacing: 8) {
                if selected, store.isRunning {
                    Circle().fill(ChatTheme.accent).frame(width: 6, height: 6)
                        .accessibilityLabel(Text("Running"))
                }
                Text(item.title.isEmpty ? NSLocalizedString("New conversation", comment: "") : item.title)
                    .font(.system(size: 15, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? ChatTheme.accentText : Color.primary)
                    .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                Text(ChatPresentation.historyTime(item.updatedAt))
                    .font(.system(size: 12)).monospacedDigit().foregroundStyle(ChatTheme.tertiary)
            }
            .padding(.horizontal, 12).frame(minHeight: 40)
            .background(selected ? ChatTheme.accentSoft : .clear,
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 1, leading: 4, bottom: 1, trailing: 4))
        .listRowBackground(Color.clear).listRowSeparator(.hidden)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) { pendingDelete = item } label: { Label("Delete", systemImage: "trash") }
                .accessibilityIdentifier("chat.history.delete.\(item.id)")
        }
        .accessibilityIdentifier("chat.history.\(item.id)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// Guest entries share the history rows' shape instead of default list cells.
    private func guestRow(symbol: String, tint: Color, title: Text,
                          action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 14)).foregroundStyle(tint == .primary
                    ? ChatTheme.accent : tint).frame(width: 20)
                title.font(.system(size: 15, weight: tint == .primary ? .regular : .semibold))
                    .foregroundStyle(tint).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).frame(minHeight: 40).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 1, leading: 4, bottom: 1, trailing: 4))
        .listRowBackground(Color.clear).listRowSeparator(.hidden)
    }

    @ViewBuilder private var emptyOverlay: some View {
        if store.isAuthenticated, store.conversations.isEmpty, !store.isLoading {
            ContentUnavailableView("Start a conversation", systemImage: "bubble.left.and.bubble.right",
                                   description: Text("Ask a question or continue a conversation from your Mac."))
                .allowsHitTesting(false)
        } else if isSearching, !store.conversations.contains(where: { ChatPresentation.matches($0, query: search) }) {
            ContentUnavailableView.search(text: search).allowsHitTesting(false)
        }
    }

    private var footer: some View {
        Button(action: onSettings) {
            HStack(spacing: 10) {
                if store.isAuthenticated {
                    ChatAvatar(initials: store.initials, size: 32)
                } else {
                    Image(systemName: "person.crop.circle.fill").font(.system(size: 30))
                        .foregroundStyle(ChatTheme.tertiary).frame(width: 32, height: 32).accessibilityHidden(true)
                }
                Text(store.isAuthenticated ? store.displayName : NSLocalizedString("Guest mode", comment: ""))
                    .font(.system(
                        size: 14.5,
                        weight: .semibold
                    ))
                    .foregroundStyle(.primary).lineLimit(1).truncationMode(.middle)
                if let plan = store.planLabel {
                    ChatPlanBadge(label: plan, paid: store.creditUsage?.paid == true)
                }
                Spacer(minLength: 4)
                Image(systemName: "gearshape").font(.system(size: 17)).foregroundStyle(ChatTheme.secondary)
            }
            .padding(.horizontal, 10).frame(minHeight: 52).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .top) { Rectangle().fill(ChatTheme.border).frame(height: 0.5) }
        .accessibilityLabel(Text("Settings")).accessibilityValue(store.email)
        .accessibilityIdentifier("chat.account")
    }
}

/// Initials on the same blue-to-violet gradient as the Mac account card.
struct ChatAvatar: View {
    var initials: String
    var size: CGFloat

    var body: some View {
        Text(initials)
            .font(.system(size: size * 0.38, weight: .bold)).foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(LinearGradient(colors: [Color(red: 0.55, green: 0.36, blue: 0.96), ChatTheme.accent],
                                       startPoint: .topLeading, endPoint: .bottomTrailing), in: Circle())
            .accessibilityHidden(true)
    }
}

struct ChatPlanBadge: View {
    var label: String
    var paid: Bool

    var body: some View {
        Text(label)
            .font(.system(size: 10.5, weight: .bold))
            .foregroundStyle(paid ? ChatTheme.accentText : ChatTheme.secondary)
            .padding(.horizontal, 6).padding(.vertical, 1.5)
            .background(paid ? ChatTheme.accentSoft : ChatTheme.fill,
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .accessibilityIdentifier("account.plan")
    }
}
