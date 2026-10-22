import PhotosUI
import SwiftUI
import TypefluxChat

struct ChatDetailView: View {
    @Bindable var store: ChatStore
    var onOpenSidebar: () -> Void = {}
    var onNewConversation: () -> Void = {}
    var onBuyCredits: () -> Void = {}
    @State private var reportedMessage: ChatMessage?
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var showPhotoPicker = false
    @State private var showCamera = false
    @State private var isLoadingPhoto = false
    @FocusState private var editorFocused: Bool

    private var isEmpty: Bool {
        store.example == nil && store.conversation?.messages.isEmpty != false && !store.isRunning && !store
            .isLoadingConversation
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView {
                    // Bottom-anchored lazy height estimation can loop when a rich
                    // reply enters the viewport. Lay out the loaded snapshot exactly.
                    VStack(alignment: .leading, spacing: 14) {
                        if let example = store.example, !store.isAuthenticated {
                            VStack(alignment: .leading, spacing: 20) {
                                Label("Local example · No credits used", systemImage: "sparkles").font(.caption)
                                    .foregroundStyle(ChatTheme.accent)
                                // Same bubble as a sent message: it hugs the text on the trailing side.
                                Text(example.question).foregroundStyle(ChatTheme.bubbleText)
                                    .padding(.horizontal, 15).padding(.vertical, 10)
                                    .background(ChatTheme.bubble,
                                                in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                                    .padding(.leading, 48)
                                    .frame(maxWidth: .infinity, alignment: .trailing)
                                ChatMarkdownView(text: example.answer)
                                Text(
                                    "This is a preset example. Your own message will start a new conversation after sign-in."
                                )
                                .font(.footnote).foregroundStyle(.secondary)
                            }.accessibilityIdentifier("guest.example")
                        } else if store.isLoadingConversation, store.conversation == nil {
                            ProgressView("Loading conversation…").frame(maxWidth: .infinity).padding(.vertical, 50)
                        } else if isEmpty {
                            // Leave the limited keyboard/landscape viewport for composing.
                            if !editorFocused, geometry.size.height > 450 {
                                emptyState.frame(minHeight: max(380, geometry.size.height - 260))
                            }
                        } else if let conversation = store.conversation {
                            ChatTranscriptView(
                                conversation: conversation,
                                allowsQuote: !store.isSending,
                                regenerableMessageID: store.regenerableMessageID,
                                quote: { text in
                                    store.draft = ChatPresentation.quote(text, into: store.draft)
                                    editorFocused = true
                                },
                                regenerate: { id in Task { await store.regenerate(messageID: id) } },
                                // Private answers never reach Typeflux, so there is nothing to report to it.
                                report: store.sendsLocally ? nil : { reportedMessage = $0 },
                                modelLabel: { store.modelLabel(for: $0) }
                            )
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.horizontal, 22).padding(.top, 8).padding(.bottom, 12)
                    .frame(maxWidth: 760).frame(maxWidth: .infinity)
                }
                .scrollDismissesKeyboard(.interactively)
                .contentShape(Rectangle())
                .simultaneousGesture(TapGesture().onEnded { editorFocused = false })
                .defaultScrollAnchor(isEmpty ? .top : .bottom)
                .refreshable { await store.reloadConversation() }
                .onChange(of: store.conversation?.messages.last?.id) { _, _ in
                    if !isEmpty {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
                .safeAreaInset(edge: .top, spacing: 0) {
                    VStack(spacing: 0) {
                        topBar
                        ChatConnectivityBanner(store: store).padding(.horizontal, 16).padding(.bottom, 8)
                    }
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    VStack(spacing: 0) {
                        if isEmpty, !editorFocused, geometry.size.height > 450, !store.needsCredits {
                            suggestions.padding(.bottom, 12)
                        }
                        if store.needsCredits {
                            ChatCreditPauseCard(store: store, onBuy: onBuyCredits)
                        }
                        if let conversation = store.conversation, conversation.isHostedElsewhere {
                            // A Mac runs it: the phone reads the history but never continues it.
                            ChatHostedElsewhereCard(conversation: conversation) {
                                editorFocused = false
                                onNewConversation()
                            }
                        } else {
                            ChatComposer(store: store, editorFocused: $editorFocused,
                                         isLoadingPhoto: isLoadingPhoto, isEmpty: isEmpty,
                                         availableHeight: geometry.size.height,
                                         onPickPhoto: { showPhotoPicker = true },
                                         onTakePhoto: { showCamera = true })
                        }
                    }
                }
            }
        }
        .background { ChatAmbientBackground() }
        .toolbar(.hidden, for: .navigationBar)
        .sheet(item: $reportedMessage) { ChatReportView(store: store, message: $0) }
        .photosPicker(isPresented: $showPhotoPicker, selection: $selectedPhoto, matching: .images)
        .fullScreenCover(isPresented: $showCamera) {
            ChatCameraPicker { data in Task { await attach(data) } }.ignoresSafeArea()
        }
        .task(id: selectedPhoto) { await loadPhoto() }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: 10) {
            barButton("sidebar.left", label: "Open sidebar", identifier: "chat.sidebar.open") {
                editorFocused = false
                onOpenSidebar()
            }
            if !store.isAuthenticated, store.library.models.isEmpty {
                Label("Guest mode", systemImage: "person.crop.circle").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { store.showsLogin = true } label: {
                    Text("Sign in").frame(minWidth: 44, minHeight: 44)
                }.accessibilityIdentifier("guest.login")
            }
            if store.isAuthenticated || !store.library.models.isEmpty {
                if let conversation = store.conversation, !conversation.messages.isEmpty || store.isRunning {
                    titlePill(conversation)
                } else {
                    Spacer()
                }
                if store.isTemporary, store.conversation?.messages.isEmpty == false {
                    barButton("tray.and.arrow.down", label: "Keep conversation", identifier: "chat.temporary.keep",
                              tint: ChatTheme.temporary) {
                        Task { await store.keepTemporary() }
                    }
                    .disabled(store.isBusy)
                } else if isEmpty, store.canStartTemporary {
                    barButton(store.startsTemporary ? "hourglass.circle.fill" : "hourglass",
                              label: store.startsTemporary ? "Temporary chat on" : "Temporary chat",
                              identifier: "chat.temporary",
                              tint: store.startsTemporary ? ChatTheme.temporary : ChatTheme.secondary) {
                        store.toggleTemporary()
                    }
                }
                barButton("square.and.pencil", label: "New conversation", identifier: "chat.detail.new",
                          tint: isEmpty ? ChatTheme.tertiary : ChatTheme.accent) {
                    editorFocused = false
                    onNewConversation()
                }
                .disabled(isEmpty && store.draft.isEmpty && store.imageDataURL == nil)
            }
        }
        .padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 10)
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded { editorFocused = false })
        .background {
            // Content scrolls under the bar and fades out instead of colliding with the title.
            LinearGradient(stops: [.init(color: ChatTheme.background, location: 0.55),
                                   .init(color: ChatTheme.background.opacity(0), location: 1)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea(edges: .top)
                .opacity(isEmpty ? 0 : 1)
        }
    }

    private func barButton(_ symbol: String, label: LocalizedStringKey, identifier: String,
                           tint: Color = .primary, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(label, systemImage: symbol).labelStyle(.iconOnly)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(tint).frame(width: 44, height: 44)
                .chatGlassCircle()
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label)).accessibilityIdentifier(identifier)
    }

    private func titlePill(_ conversation: ChatConversation) -> some View {
        VStack(spacing: 1) {
            HStack(spacing: 4) {
                if store.isTemporary {
                    Image(systemName: "hourglass").font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(ChatTheme.temporary)
                        .accessibilityLabel(NSLocalizedString("Temporary chat", comment: ""))
                }
                if store.conversationStorage == .local {
                    Image(systemName: "lock.fill").font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(ChatTheme.purple)
                        .accessibilityLabel(NSLocalizedString("Private conversation", comment: ""))
                }
                Text(conversation.title.isEmpty ? NSLocalizedString("New conversation", comment: "")
                    : conversation.title)
                    .font(.system(size: 14.5, weight: .semibold)).lineLimit(1)
            }
            if let run = conversation.run {
                HStack(spacing: 5) {
                    Circle().fill(runColor(run)).frame(width: 6, height: 6)
                    Text(ChatPresentation.runStatusLine(run, steps: ChatTranscript.stepCount(conversation)))
                        .font(.system(size: 11)).foregroundStyle(ChatTheme.secondary)
                        .accessibilityIdentifier("chat.header.status")
                }
            }
        }
        .padding(.horizontal, 16).frame(maxWidth: .infinity, minHeight: 44)
        .chatGlass(corner: 22)
        .accessibilityElement(children: .contain)
    }

    private func runColor(_ run: ChatRun) -> Color {
        switch run.status {
        case "failed": .red
        case "cancelled": ChatTheme.secondary
        case "completed": ChatTheme.success
        default: run.requiresDesktop || run.isPausedForCredits ? .orange : ChatTheme.accent
        }
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)
            ChatOrb(size: 96).padding(.bottom, 22)
            Text(store.startsTemporary ? "Temporary chat" : store.sendsLocally ? "Ask privately" : "What's on your mind?")
                .font(.system(size: 25, weight: .semibold))
                .multilineTextAlignment(.center)
            Text(store.startsTemporary ? "It won't appear in history and is deleted when you leave."
                : store.sendsLocally ? "Answered by your own model and kept only on this iPhone."
                : "Look at photos, translate, read the web")
                .font(.system(size: 14.5)).foregroundStyle(ChatTheme.secondary).multilineTextAlignment(.center)
                .padding(.top, 8).padding(.horizontal, 24)
                .accessibilityIdentifier("chat.empty.subtitle")
            Spacer(minLength: 24)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.empty")
    }

    private var suggestions: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                if !store.canChooseModel {
                    ForEach(ChatExample.allCases) { example in
                        Button { store.example = example; editorFocused = false } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                Image(systemName: "sparkles").foregroundStyle(ChatTheme.accent)
                                Text(example.title).font(.subheadline.bold())
                                Text("Local example · No credits used").font(.caption2).foregroundStyle(.secondary)
                            }.padding(14).frame(width: 190, alignment: .leading).chatCard(corner: 18)
                        }.buttonStyle(.plain).accessibilityIdentifier("guest.example." + example.id)
                    }
                } else {
                    suggestion("Explain this photo", caption: "Take one or pick a screenshot", symbol: "photo",
                               identifier: "chat.suggestion.photo") { showPhotoPicker = true }
                        .disabled(store.selectedModel?.vision != true || store.isSending)
                    suggestion("Translate some text", caption: "Keep its formatting", symbol: "character.bubble",
                               identifier: "chat.suggestion.translate") {
                        store.draft = NSLocalizedString("Translate the following text:\n", comment: "Draft prompt")
                        editorFocused = true
                    }
                    suggestion("Summarize a webpage", caption: "Paste a link", symbol: "globe",
                               identifier: "chat.suggestion.web") {
                        store.draft = NSLocalizedString("Read and summarize this webpage:\n", comment: "Draft prompt")
                        editorFocused = true
                    }
                }
            }
            .padding(.horizontal, 20)
        }
        .scrollClipDisabled()
    }

    private func suggestion(_ title: LocalizedStringKey, caption: LocalizedStringKey, symbol: String,
                            identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                Image(systemName: symbol).font(.system(size: 14, weight: .medium))
                    .foregroundStyle(ChatTheme.accent).frame(width: 30, height: 30)
                    .background(ChatTheme.accentSoft, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                Text(title).font(.system(size: 14.5, weight: .semibold)).foregroundStyle(.primary)
                    .lineLimit(1).padding(.top, 12)
                Text(caption).font(.system(size: 12.5)).foregroundStyle(ChatTheme.secondary).lineLimit(1)
                    .padding(.top, 3)
            }
            .padding(.horizontal, 14).padding(.vertical, 13)
            .frame(width: 168, alignment: .leading)
            .chatCard(corner: 20)
            .shadow(color: .black.opacity(0.035), radius: 6, y: 2)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }

    // MARK: Photos

    private func loadPhoto() async {
        guard let selectedPhoto else { return }
        isLoadingPhoto = true
        defer { isLoadingPhoto = false }
        let context = store.attachmentContext
        do {
            guard let data = try await selectedPhoto.loadTransferable(type: Data.self) else { return }
            try Task.checkCancellation()
            let encoded = try ImageAttachment.dataURL(data)
            guard context == store.attachmentContext else { return }
            store.imageDataURL = encoded
        } catch is CancellationError {
            // Navigation and account changes cancel attachment loading.
        } catch {
            if context == store.attachmentContext {
                store.errorMessage = ChatStore.userMessage(for: error)
            }
        }
        self.selectedPhoto = nil
    }

    private func attach(_ data: Data) async {
        let context = store.attachmentContext
        isLoadingPhoto = true
        defer { isLoadingPhoto = false }
        do {
            let encoded = try ImageAttachment.dataURL(data)
            if context == store.attachmentContext {
                store.imageDataURL = encoded
            }
        } catch {
            store.errorMessage = ChatStore.userMessage(for: error)
        }
    }
}

/// Takes the composer's place for a conversation a Mac runs: what it is, where it runs,
/// and a way to start a new chat here instead.
struct ChatHostedElsewhereCard: View {
    let conversation: ChatConversation
    var onNewChat: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: conversation.isWork ? "terminal" : "desktopcomputer")
                    .font(.system(size: 17)).foregroundStyle(ChatTheme.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(conversation.isWork ? "Work runs on your Mac" : "This conversation runs on your Mac")
                        .font(.system(size: 15, weight: .semibold))
                    Text(ChatPresentation.hostLine(conversation.hostDeviceName)
                        + " · " + NSLocalizedString("Read-only on this iPhone", comment: ""))
                        .font(.system(size: 13)).foregroundStyle(ChatTheme.secondary)
                }
                Spacer(minLength: 0)
            }
            Button(action: onNewChat) {
                Text("New chat").font(.system(size: 15, weight: .semibold)).frame(maxWidth: .infinity, minHeight: 40)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("chat.hosted.newChat")
        }
        .padding(14)
        .background(ChatTheme.fill, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding(.horizontal, 12).padding(.bottom, 10)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.hosted")
    }
}
