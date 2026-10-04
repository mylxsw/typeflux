import PhotosUI
import SwiftUI
import TypefluxChat

struct ChatDetailView: View {
    @Bindable var store: ChatStore
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var isLoadingPhoto = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    if store.conversation?.messages.isEmpty != false {
                        VStack(alignment: .leading, spacing: 12) {
                            Image(systemName: "sparkles").font(.largeTitle).foregroundStyle(.indigo)
                            Text("What's on your mind?").font(.title.bold())
                            Text("Ask Typeflux to explain, write, or help you think it through.")
                                .foregroundStyle(.secondary)
                        }.padding(.vertical, 40)
                    }
                    ForEach(store.conversation?.messages ?? []) { message in
                        MessageView(message: message)
                    }
                    if let run = store.conversation?.run {
                        if run.isActive {
                            VStack(alignment: .leading, spacing: 10) {
                                Label(
                                    run
                                        .requiresDesktop ? "Waiting for the originating device" :
                                        "Typeflux is thinking…",
                                    systemImage: run.requiresDesktop ? "desktopcomputer" : "sparkles"
                                )
                                .font(.caption).foregroundStyle(.secondary)
                                if let preview = run.preview, !preview.isEmpty {
                                    Text(.init(preview)).textSelection(.enabled)
                                }
                                ForEach(run.pending) { tool in
                                    Label(tool.function.name, systemImage: "wrench.and.screwdriver")
                                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                                }
                            }
                        }
                        if let error = run.error, !error.isEmpty {
                            Text(error).foregroundStyle(.red).font(.callout)
                        }
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }.padding(20).frame(maxWidth: 800).frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: store.conversation?.revision) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
            .safeAreaInset(edge: .bottom, spacing: 0) { composer }
        }
        .navigationTitle(store.conversation?.title ?? "New conversation")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { Task { await store.reloadConversation() } } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(store.conversation == nil).accessibilityLabel("Refresh conversation")
            }
        }
        .task(id: selectedPhoto) {
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

    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let validation = store.composerValidation {
                Text(validation).font(.caption).foregroundStyle(.orange)
            }
            if let error = store.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red).lineLimit(4)
            }
            HStack {
                Menu {
                    Picker("Model", selection: $store.modelRef) {
                        ForEach(store.models) { model in Text(model.mobileDisplayName).tag(model.reference) }
                    }
                } label: {
                    Label(
                        store.models.first(where: { $0.reference == store.modelRef })?
                            .mobileDisplayName ?? "Typeflux Cloud",
                        systemImage: "chevron.down"
                    ).font(.caption.weight(.medium))
                }.disabled(store.isSending || store.isRunning)
                Spacer()
                if store.imageDataURL != nil {
                    Button { store.imageDataURL = nil } label: { Label(
                        "Photo attached",
                        systemImage: "xmark.circle.fill"
                    ) }
                    .font(.caption)
                }
            }
            HStack(alignment: .bottom, spacing: 12) {
                PhotosPicker(selection: $selectedPhoto, matching: .images) {
                    Image(systemName: "plus.circle").font(.title2)
                }
                .disabled(store.isSending || store.isRunning || isLoadingPhoto || store.models
                    .first(where: { $0.reference == store.modelRef })?.vision != true)
                .accessibilityLabel("Attach photo")
                TextField("Message Typeflux", text: $store.draft, axis: .vertical)
                    .lineLimit(1 ... 7).padding(.vertical, 5).accessibilityIdentifier("chat.composer")
                    .disabled(store.isSending)
                if store.isRunning {
                    Button { Task { await store.cancelRun() } } label: {
                        Image(systemName: "stop.circle.fill").font(.title)
                    }.accessibilityLabel("Stop response")
                } else {
                    Button { Task { await store.send() } } label: {
                        if store.isSending || isLoadingPhoto {
                            ProgressView().frame(width: 30, height: 30)
                        } else {
                            Image(systemName: "arrow.up.circle.fill").font(.title)
                        }
                    }.disabled(!store.canSend || isLoadingPhoto)
                        .accessibilityLabel("Send message").accessibilityIdentifier("chat.send")
                }
            }
        }.padding(16).background(.regularMaterial)
    }
}

extension ChatModel {
    var mobileDisplayName: String {
        guard let multiplier = pricing?["multiplier"],
              let value = Decimal(string: multiplier, locale: Locale(identifier: "en_US_POSIX")), value > 0 else {
            return name
        }
        return "\(name) · \(multiplier)× credits"
    }
}

private struct MessageView: View {
    let message: ChatMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(message.role == "user" ? "You" : message.role == "tool" ? "Tool result" : "Typeflux")
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if let image = message.image, let uiImage = ImageAttachment.decode(image) {
                Image(uiImage: uiImage).resizable().scaledToFit().frame(maxHeight: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 12)).accessibilityLabel("Attached photo")
            }
            if message.role == "tool" {
                DisclosureGroup(message.isError == true ? "Tool failed" : "View tool output") {
                    Text(message.text).font(.caption.monospaced()).textSelection(.enabled)
                }
            } else if !message.text.isEmpty {
                Text(.init(message.text)).textSelection(.enabled)
            }
            ForEach(message.toolCalls ?? []) { tool in
                DisclosureGroup(tool.function.name) {
                    Text(tool.function.arguments).font(.caption.monospaced()).textSelection(.enabled)
                }.font(.callout)
            }
        }
        .padding(message.role == "user" ? 14 : 0)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(message.role == "user" ? Color.indigo.opacity(0.08) : .clear,
                    in: RoundedRectangle(cornerRadius: 16))
    }
}
