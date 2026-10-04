import PhotosUI
import SwiftUI
import TypefluxChat

struct ChatDetailView: View {
    @Bindable var store: ChatStore
    var onNewConversation: () -> Void = {}
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var showPhotoPicker = false
    @State private var isLoadingPhoto = false
    @FocusState private var editorFocused: Bool

    private var isEmpty: Bool {
        store.conversation?.messages.isEmpty != false && !store.isRunning && !store.isLoadingConversation
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        if store.isLoadingConversation, store.conversation == nil {
                            ProgressView("Loading conversation…").frame(maxWidth: .infinity).padding(.vertical, 50)
                        } else if isEmpty {
                            emptyState.frame(minHeight: max(380, geometry.size.height - 156))
                        } else if let conversation = store.conversation {
                            ChatTranscriptView(conversation: conversation) { text in
                                store.draft = ChatPresentation.quote(text, into: store.draft)
                                editorFocused = true
                            }
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }.padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 12)
                        .frame(maxWidth: 800).frame(maxWidth: .infinity)
                }
                .scrollDismissesKeyboard(.interactively)
                .defaultScrollAnchor(.bottom)
                .refreshable { await store.reloadConversation() }
                .onChange(of: store.conversation?.messages.last?.id) { _, _ in
                    if !isEmpty {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
                .safeAreaInset(edge: .bottom, spacing: 0) { composer(availableHeight: geometry.size.height) }
            }
        }
        .background(ChatTheme.background)
        .navigationTitle(store.conversation?.title ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                if let conversation = store.conversation {
                    VStack(spacing: 2) {
                        Text(conversation.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                        if let run = conversation.run {
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(runColor(run))
                                    .frame(width: 5, height: 5)
                                Text(NSLocalizedString(ChatPresentation.runTitle(run), comment: "Run state"))
                                    .accessibilityIdentifier("chat.header.status")
                                    .font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: onNewConversation) { Image(systemName: "square.and.pencil") }
                    .accessibilityLabel("New conversation").accessibilityIdentifier("chat.detail.new")
            }
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $selectedPhoto, matching: .images)
        .task(id: selectedPhoto) { await loadPhoto() }
    }

    private func runColor(_ run: ChatRun) -> Color {
        switch run.status {
        case "failed": .red
        case "cancelled": ChatTheme.secondary
        case "completed": .green
        default: run.requiresDesktop ? .orange : ChatTheme.accent
        }
    }

    private var emptyState: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)
            ChatOrb().padding(.bottom, 26)
            Text("What's on your mind?").font(.system(size: 26, weight: .bold)).multilineTextAlignment(.center)
            Text("Ask questions, explore images, read the web.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .padding(.top, 10)
            Spacer(minLength: 32)
            VStack(spacing: 8) {
                suggestion("Explain this image", caption: "Upload a photo or screenshot", symbol: "photo") {
                    showPhotoPicker = true
                }.disabled(store.selectedModel?.vision != true || store.isSending)
                suggestion(
                    "Translate some text",
                    caption: "Paste text, keep its formatting",
                    symbol: "character.bubble"
                ) {
                    store.draft = NSLocalizedString("Translate the following text:\n", comment: "Draft prompt")
                    editorFocused = true
                }
                suggestion("Read and summarize a webpage", caption: "Paste a link", symbol: "globe") {
                    store.draft = NSLocalizedString("Read and summarize this webpage:\n", comment: "Draft prompt")
                    editorFocused = true
                }
            }.padding(.bottom, 28)
        }.frame(maxWidth: 560).frame(maxWidth: .infinity)
    }

    private func suggestion(_ title: String, caption: String, symbol: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 14))
                    .foregroundStyle(ChatTheme.accent).frame(width: 28, height: 28)
                    .background(ChatTheme.accentSoft, in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 3) {
                    Text(NSLocalizedString(title, comment: "Suggestion")).font(.subheadline.weight(.medium))
                    Text(NSLocalizedString(caption, comment: "Suggestion description"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }.padding(12).frame(minHeight: 58).chatGlass(corner: 16)
        }.buttonStyle(.plain)
    }

    private func composer(availableHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let validation = store.composerValidation {
                Text(NSLocalizedString(validation, comment: "Composer validation"))
                    .font(.caption).foregroundStyle(.orange).padding(.horizontal, 8)
            }
            if let error = store.errorMessage {
                HStack(alignment: .top) {
                    Text(NSLocalizedString(error, comment: "Chat error")).font(.caption).foregroundStyle(.red)
                    Spacer(minLength: 4)
                    Button { Task { await store.reloadConversation() } } label: { Image(systemName: "arrow.clockwise") }
                        .frame(width: 44, height: 44).accessibilityLabel("Refresh conversation")
                }.padding(.horizontal, 8)
            }
            if let data = store.imageDataURL {
                HStack(spacing: 6) {
                    if let photo = ImageAttachment.decode(data) {
                        Image(uiImage: photo).resizable().scaledToFill().frame(width: 24, height: 24)
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                    }
                    Text("Photo attached").font(.caption).foregroundStyle(.secondary)
                    Button { store.imageDataURL = nil } label: {
                        Image(systemName: "xmark").font(.caption).frame(width: 44, height: 44)
                    }.accessibilityLabel("Remove photo")
                }.padding(.leading, 8).padding(.trailing, 3)
                    .background(ChatTheme.controlSurface.opacity(0.5), in: Capsule())
                    .padding(.horizontal, 6)
            }
            TextField(
                LocalizedStringKey(isEmpty ? "Message Typeflux" : "Ask a follow-up"),
                text: $store.draft,
                axis: .vertical
            )
            .font(.body).lineLimit(1 ... 7).padding(.horizontal, 10).padding(.top, 5)
            .frame(minHeight: 34, alignment: .topLeading).focused($editorFocused)
            .accessibilityIdentifier("chat.composer").disabled(store.isSending)
            composerActions(availableHeight: availableHeight)
        }.padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 6)
            .chatGlass(corner: 28)
            .padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 8)
            .frame(maxWidth: 780).frame(maxWidth: .infinity)
    }

    private func composerActions(availableHeight: CGFloat) -> some View {
        HStack(spacing: 0) {
            Button { showPhotoPicker = true } label: {
                Image(systemName: "plus").font(.system(size: 18)).frame(width: 44, height: 44)
                    .foregroundStyle(.secondary)
            }
            .disabled(store.isSending || store.isRunning || isLoadingPhoto || store.selectedModel?.vision != true)
            .accessibilityLabel("Attach photo").accessibilityIdentifier("chat.attach")
            ChatModelPicker(store: store, maximumHeight: max(100, availableHeight - 110))
            Spacer(minLength: 4)
            if store.isRunning {
                Button { Task { await store.cancelRun() } } label: {
                    Image(systemName: "stop.fill").font(.system(size: 11))
                        .frame(width: 34, height: 34)
                        .background(ChatTheme.controlSurface, in: Circle())
                        .overlay(Circle().strokeBorder(ChatTheme.border, lineWidth: 0.5))
                        .frame(width: 44, height: 44)
                }.foregroundStyle(.primary).accessibilityLabel("Stop response")
            } else {
                Button {
                    editorFocused = false
                    Task { await store.send() }
                } label: {
                    Group {
                        if store.isSending || isLoadingPhoto {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.up").font(.system(size: 16, weight: .semibold))
                        }
                    }
                    .foregroundStyle(store.canSend ? Color.white : ChatTheme.secondary)
                    .frame(width: 34, height: 34)
                    .background(store.canSend ? ChatTheme.accent : ChatTheme.controlSurface, in: Circle())
                    .frame(width: 44, height: 44)
                }.disabled(!store.canSend || isLoadingPhoto)
                    .accessibilityLabel("Send message").accessibilityIdentifier("chat.send")
            }
        }
    }

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
}
