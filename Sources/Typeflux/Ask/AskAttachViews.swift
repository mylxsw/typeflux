import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The composer's "+" control: add files and images, and switch what rides along
/// with the question (screenshot, memory, selected text) and, before the first
/// message, where the conversation is kept. Pasting and dropping work in the editor.
struct AskAttachButton: View {
    @ObservedObject var model: AskConversationModel
    var launcher: Bool
    var disabled = false
    /// Built by the composer each time the menu draws, so the switches show live state.
    var context: () -> AskAddMenuContext = { AskAddMenuContext() }
    /// The captured screen's decoder, so the menu redraws when its thumbnail is ready.
    var screenshot: AskContextImageModel?
    @State private var expanded = false
    @State private var hovering = false

    var body: some View {
        Button { expanded.toggle() } label: {
            Image(systemName: "plus")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(hovering || expanded ? StudioTheme.textPrimary : StudioTheme.textSecondary)
                .frame(width: AskMetrics.composerControlHeight, height: AskMetrics.composerControlHeight)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .disabled(disabled)
        .help(L("ask.attach.help"))
        .accessibilityLabel(L("ask.attach.title"))
        .accessibilityIdentifier("ask.composer.attach")
        .askMenu(isPresented: $expanded, glass: true) {
            AskLiveComposerAddMenu(model: model, screenshot: screenshot ?? AskContextImageModel(), context: context) {
                expanded = false
                model.pickAttachments(folders: false, launcher: launcher)
            }
        }
        // ⌘U picks files directly, without opening the menu.
        .background {
            // Invisible rather than hidden: a hidden button drops its shortcut.
            Button("") { model.pickAttachments(folders: false, launcher: launcher) }
                .keyboardShortcut("u", modifiers: .command)
                .disabled(disabled)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
    }
}

/// The open panel reads both models in one body so storage and switches update together.
struct AskLiveComposerAddMenu: View {
    @ObservedObject var model: AskConversationModel
    @ObservedObject var screenshot: AskContextImageModel
    var context: () -> AskAddMenuContext
    var pickFiles: () -> Void

    var body: some View { AskComposerAddMenu(context: context(), pickFiles: pickFiles) }
}

/// ⌘/ starts a slash command in the workspace, like typing "/". It has no visible
/// "/" control: its placeholder names the command key instead.
struct AskSlashShortcut: View {
    var disabled = false
    var action: () -> Void

    var body: some View {
        // Invisible rather than hidden: a hidden button drops its shortcut.
        Button("", action: action)
            .keyboardShortcut("/", modifiers: .command)
            .disabled(disabled)
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
    }
}

extension AskAttachmentSource {
    static let dropTypes: [UTType] = [.fileURL, .image]

    /// Reads what a SwiftUI drop delivered: file URLs first, image data otherwise.
    static func load(from providers: [NSItemProvider]) async -> [AskAttachmentSource] {
        var sources: [AskAttachmentSource] = []
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
               let url = await fileURL(from: provider) {
                sources.append(.file(url))
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier),
                      let data = await imageData(from: provider) {
                sources.append(.image(data, name: provider.suggestedName ?? L("ask.attach.pastedImage")))
            }
        }
        return sources
    }

    private static func fileURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                continuation.resume(returning: url?.isFileURL == true ? url : nil)
            }
        }
    }

    private static func imageData(from provider: NSItemProvider) async -> Data? {
        await withCheckedContinuation { continuation in
            _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                continuation.resume(returning: data)
            }
        }
    }
}

extension View {
    /// Accepts dropped files and images as attachments for the composer's draft.
    func askAttachmentDrop(model: AskConversationModel, launcher: Bool, targeted: Binding<Bool>) -> some View {
        onDrop(of: AskAttachmentSource.dropTypes, isTargeted: targeted) { providers in
            Task { @MainActor in
                let sources = await AskAttachmentSource.load(from: providers)
                model.addAttachments(sources, launcher: launcher)
            }
            return true
        }
    }
}

/// Permission controls shared by the launcher and conversation attachment menus.
struct AskFolderPermissionControls: View {
    @ObservedObject var model: AskConversationModel
    let launcher: Bool
    var body: some View {
        let grants = model.temporaryFolderGrants()
        if !launcher, !grants.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(grants) { grant in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(grant.root).lineLimit(2).truncationMode(.middle).help(grant.root)
                                Text(L(grant.lifetime == .task ? "ask.folder.task" : "ask.folder.session"))
                                    .font(.caption)
                                Text(L("ask.folder.source")).font(.caption)
                                if model.hasSettingsFolder(grant.root) {
                                    Text(L("ask.folder.settingsAlso")).font(.caption)
                                }
                                Button(L("ask.folder.revoke")) { model.revokeTemporaryFolder(grant.id) }
                            }
                        }
                    }
                }.frame(height: min(CGFloat(grants.count) * 120, 240))
                Button(L("ask.folder.revokeAll")) { model.revokeTemporaryFolder(nil) }
            }
        }
    }
}
