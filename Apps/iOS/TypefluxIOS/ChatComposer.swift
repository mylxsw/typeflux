import SwiftUI
import TypefluxChat
import UIKit

/// The Mac composer's two rows on a phone: text on top; attach, the model and
/// reasoning chip, dictation and send below. It floats as one glass card.
struct ChatComposer: View {
    @Bindable var store: ChatStore
    var editorFocused: FocusState<Bool>.Binding
    var isLoadingPhoto: Bool
    var isEmpty: Bool
    var availableHeight: CGFloat
    var onPickPhoto: () -> Void
    var onTakePhoto: () -> Void
    @State private var dictation = ChatDictation()
    @State private var dictationBase = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            notices
            if let data = store.imageDataURL {
                attachment(data).padding(.horizontal, 6).padding(.bottom, 10)
            }
            TextField(LocalizedStringKey(isEmpty ? "Message Typeflux" : "Ask a follow-up"),
                      text: $store.draft, axis: .vertical)
                .font(.system(size: 16)).lineLimit(1 ... 7)
                .padding(.horizontal, 8).padding(.bottom, 10)
                .frame(minHeight: 30, alignment: .topLeading)
                .focused(editorFocused)
                .accessibilityIdentifier("chat.composer").disabled(store.isSending)
            controls
        }
        .padding(.horizontal, 10).padding(.top, 13).padding(.bottom, 10)
        .chatGlass(corner: 26)
        .padding(.horizontal, 12).padding(.bottom, 6)
        .frame(maxWidth: 780).frame(maxWidth: .infinity)
        .onChange(of: store.attachmentContext) { _, _ in dictation.stop() }
        .onChange(of: dictation.transcript) { _, text in
            guard dictation.state == .listening, !text.isEmpty else { return }
            let separator = dictationBase.isEmpty || dictationBase.hasSuffix(" ")
                || dictationBase.hasSuffix("\n") ? "" : " "
            store.draft = dictationBase + separator + text
        }
        .onDisappear { dictation.stop() }
    }

    @ViewBuilder private var notices: some View {
        if let info = store.infoMessage {
            HStack {
                Label(NSLocalizedString(info, comment: "Account notice"), systemImage: "checkmark.circle")
                Spacer()
                Button { store.infoMessage = nil } label: { Image(systemName: "xmark") }
                    .accessibilityLabel("Dismiss")
            }.font(.footnote).foregroundStyle(ChatTheme.accent).padding(8)
        }
        if let validation = store.composerValidation {
            Text(NSLocalizedString(validation, comment: "Composer validation"))
                .font(.footnote).foregroundStyle(.orange)
                .padding(.horizontal, 8).padding(.bottom, 8)
                .accessibilityIdentifier("chat.composer.validation")
        }
        if let error = store.errorMessage ?? dictation.errorMessage {
            HStack(alignment: .top, spacing: 4) {
                Text(NSLocalizedString(error, comment: "Chat error")).font(.footnote).foregroundStyle(.red)
                    .accessibilityIdentifier("chat.composer.error")
                Spacer(minLength: 4)
                if dictation.errorMessage != nil {
                    Link("Open Settings", destination: URL(string: UIApplication.openSettingsURLString)!)
                        .font(.footnote)
                }
                if store.errorMessage != nil {
                    Button { Task { await store.reloadConversation() } } label: {
                        Image(systemName: "arrow.clockwise").font(.footnote)
                            .frame(width: 32, height: 32)
                    }
                    .accessibilityLabel("Refresh conversation")
                }
            }
            .padding(.leading, 8).padding(.bottom, 6)
        }
    }

    private func attachment(_ data: String) -> some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let photo = ImageAttachment.decode(data) {
                    Image(uiImage: photo).resizable().scaledToFill()
                } else {
                    ChatTheme.fill
                }
            }
            .frame(width: 54, height: 54)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .accessibilityLabel("Photo attached")
            .accessibilityIdentifier("chat.photo.preview")
            Button { store.imageDataURL = nil } label: {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 18, height: 18).background(.black.opacity(0.55), in: Circle())
                    .padding(4).frame(width: 44, height: 44, alignment: .topTrailing)
                    .contentShape(Rectangle())
            }
            .offset(x: 13, y: -13)
            .accessibilityLabel("Remove photo").accessibilityIdentifier("chat.photo.remove")
        }
    }

    private var controls: some View {
        HStack(spacing: 2) {
            attachMenu
            ChatModelPicker(store: store, maximumHeight: max(100, availableHeight - 170))
            Spacer(minLength: 4)
            if !store.isRunning {
                micButton
            }
            sendButton
        }
    }

    private var attachDisabled: Bool {
        store.isSending || store
            .isRunning || isLoadingPhoto || (store.isAuthenticated && store.selectedModel?.vision != true)
    }

    private var attachMenu: some View {
        Menu {
            Button(action: onPickPhoto) { Label("Photo Library", systemImage: "photo.on.rectangle") }
                .accessibilityIdentifier("chat.attach.library")
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button(action: onTakePhoto) { Label("Take Photo", systemImage: "camera") }
            }
        } label: {
            Image(systemName: "plus").font(.system(size: 18, weight: .regular))
                .foregroundStyle(attachDisabled ? ChatTheme.tertiary : ChatTheme.secondary)
                .frame(width: 40, height: 44).contentShape(Rectangle())
        }
        .disabled(attachDisabled)
        .accessibilityLabel("Attach photo").accessibilityIdentifier("chat.attach")
    }

    private var micButton: some View {
        let listening = dictation.state != .idle
        return Button {
            if listening {
                dictation.stop()
            } else {
                dictationBase = store.draft
                Task { await dictation.start() }
            }
        } label: {
            Image(systemName: listening ? "waveform" : "mic")
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(listening ? Color.white : ChatTheme.secondary)
                .symbolEffect(.variableColor.iterative, isActive: listening)
                .frame(width: 34, height: 34)
                .background(listening ? Color.red : .clear, in: Circle())
                .frame(width: 40, height: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(store.isSending)
        .accessibilityLabel(listening ? LocalizedStringKey("Stop dictation") : LocalizedStringKey("Dictate"))
        .accessibilityIdentifier("chat.dictate")
    }

    @ViewBuilder private var sendButton: some View {
        if store.isRunning {
            Button { Task { await store.cancelRun() } } label: {
                RoundedRectangle(cornerRadius: 2.5).frame(width: 10, height: 10)
                    .foregroundStyle(ChatTheme.background)
                    .frame(width: 34, height: 34).background(Color.primary, in: Circle())
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Stop response").accessibilityIdentifier("chat.stop")
        } else {
            Button {
                dictation.stop()
                editorFocused.wrappedValue = false
                Task { await store.send() }
            } label: {
                Group {
                    if store.isSending || isLoadingPhoto {
                        ProgressView().controlSize(.small).tint(ChatTheme.secondary)
                    } else {
                        Image(systemName: "arrow.up").font(.system(size: 15, weight: .semibold))
                    }
                }
                .foregroundStyle(store.canAttemptSend ? Color.white : ChatTheme.tertiary)
                .frame(width: 34, height: 34)
                .background(store.canAttemptSend ? ChatTheme.accent : ChatTheme.strongFill, in: Circle())
                .shadow(color: store.canAttemptSend ? ChatTheme.accent.opacity(0.35) : .clear, radius: 6, y: 3)
                .frame(width: 40, height: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!store.canAttemptSend || isLoadingPhoto)
            .accessibilityLabel("Send message").accessibilityIdentifier("chat.send")
        }
    }
}

/// Takes one photo with the camera and hands back JPEG data.
struct ChatCameraPicker: UIViewControllerRepresentable {
    var onCapture: (Data) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_: UIImagePickerController, context _: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onCapture: onCapture, dismiss: { dismiss() })
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onCapture: (Data) -> Void
        let dismiss: () -> Void

        init(onCapture: @escaping (Data) -> Void, dismiss: @escaping () -> Void) {
            self.onCapture = onCapture
            self.dismiss = dismiss
        }

        func imagePickerController(_: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage, let data = image.jpegData(compressionQuality: 0.9) {
                onCapture(data)
            }
            dismiss()
        }

        func imagePickerControllerDidCancel(_: UIImagePickerController) {
            dismiss()
        }
    }
}
