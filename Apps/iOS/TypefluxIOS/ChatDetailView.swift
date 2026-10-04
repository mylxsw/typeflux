import PhotosUI
import SwiftUI
import TypefluxChat

struct ChatDetailView: View {
    @Bindable var store: ChatStore
    var onOpenSidebar: () -> Void = {}
    var onNewConversation: () -> Void = {}
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var showPhotoPicker = false
    @State private var showCamera = false
    @State private var isLoadingPhoto = false
    @FocusState private var editorFocused: Bool

    private var isEmpty: Bool {
        store.conversation?.messages.isEmpty != false && !store.isRunning && !store.isLoadingConversation
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView {
                    // Bottom-anchored lazy height estimation can loop when a rich
                    // reply enters the viewport. Lay out the loaded snapshot exactly.
                    VStack(alignment: .leading, spacing: 14) {
                        if store.isLoadingConversation, store.conversation == nil {
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
                                regenerate: { id in Task { await store.regenerate(messageID: id) } }
                            )
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.horizontal, 22).padding(.top, 8).padding(.bottom, 12)
                    .frame(maxWidth: 760).frame(maxWidth: .infinity)
                }
                .scrollDismissesKeyboard(.interactively)
                .defaultScrollAnchor(isEmpty ? .top : .bottom)
                .refreshable { await store.reloadConversation() }
                .onChange(of: store.conversation?.messages.last?.id) { _, _ in
                    if !isEmpty {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
                .safeAreaInset(edge: .top, spacing: 0) { topBar }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    VStack(spacing: 0) {
                        if isEmpty, !editorFocused, geometry.size.height > 450 {
                            suggestions.padding(.bottom, 12)
                        }
                        ChatComposer(store: store, editorFocused: $editorFocused,
                                     isLoadingPhoto: isLoadingPhoto, isEmpty: isEmpty,
                                     availableHeight: geometry.size.height,
                                     onPickPhoto: { showPhotoPicker = true },
                                     onTakePhoto: { showCamera = true })
                    }
                }
            }
        }
        .background { ChatAmbientBackground() }
        .toolbar(.hidden, for: .navigationBar)
        .photosPicker(isPresented: $showPhotoPicker, selection: $selectedPhoto, matching: .images)
        .fullScreenCover(isPresented: $showCamera) {
            ChatCameraPicker { data in Task { await attach(data) } }.ignoresSafeArea()
        }
        .task(id: selectedPhoto) { await loadPhoto() }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: 10) {
            barButton("sidebar.left", label: "Open sidebar", identifier: "chat.sidebar.open", action: onOpenSidebar)
            if let conversation = store.conversation, !conversation.messages.isEmpty || store.isRunning {
                titlePill(conversation)
            } else {
                Spacer()
            }
            barButton("square.and.pencil", label: "New conversation", identifier: "chat.detail.new",
                      tint: isEmpty ? ChatTheme.tertiary : ChatTheme.accent, action: onNewConversation)
                .disabled(isEmpty && store.draft.isEmpty && store.imageDataURL == nil)
        }
        .padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 10)
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
            Image(systemName: symbol).font(.system(size: 17, weight: .medium))
                .foregroundStyle(tint).frame(width: 44, height: 44)
                .chatGlassCircle()
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label).accessibilityIdentifier(identifier)
    }

    private func titlePill(_ conversation: ChatConversation) -> some View {
        VStack(spacing: 1) {
            Text(conversation.title.isEmpty ? NSLocalizedString("New conversation", comment: "") : conversation.title)
                .font(.system(size: 14.5, weight: .semibold)).lineLimit(1)
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
        default: run.requiresDesktop ? .orange : ChatTheme.accent
        }
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)
            ChatOrb(size: 96).padding(.bottom, 22)
            Text("What's on your mind?").font(.system(size: 25, weight: .semibold))
                .multilineTextAlignment(.center)
            Text("Look at photos, translate, read the web")
                .font(.system(size: 14.5)).foregroundStyle(ChatTheme.secondary).multilineTextAlignment(.center)
                .padding(.top, 8)
            Spacer(minLength: 24)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.empty")
    }

    private var suggestions: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
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
                store.errorMessage = error.localizedDescription
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
            store.errorMessage = error.localizedDescription
        }
    }
}
