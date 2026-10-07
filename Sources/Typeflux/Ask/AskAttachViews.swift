import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The composer's "+" control: pick files and images, a folder, or the image
/// on the clipboard. Pasting and dropping reach the same place without it.
struct AskAttachButton: View {
    @ObservedObject var model: AskConversationModel
    var launcher: Bool
    var disabled = false
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
        .accessibilityIdentifier("ask.attach")
        .askMenu(isPresented: $expanded, glass: true) {
            AskAttachChoices(clipboardHasImage: AskAttachmentSource.canRead(from: .general),
                             sourceToRestore: sourceToRestore, selectionLinesToRestore: selectionLinesToRestore,
                             restoreEnabled: !model.capturing,
                             restore: { kind in
                                 expanded = false
                                 model.restoreCapturedContent(kind, launcher: launcher)
                             }, choose: { choice in
                expanded = false
                switch choice {
                case .files: model.pickAttachments(folders: false, launcher: launcher)
                case .folder: model.pickAttachments(folders: true, launcher: launcher)
                case .clipboard: model.addAttachments(AskAttachmentSource.read(from: .general), launcher: launcher)
                }
            })
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

    private var draft: AskDraft { launcher ? model.launcherDraft : model.draft }

    private var sourceToRestore: String? {
        guard draft.sourceOff == true, let source = draft.source, !source.isEmpty else { return nil }
        return AskContextChips.sourceParts(source).app
    }

    private var selectionLinesToRestore: Int? {
        guard draft.selectionOff == true, let selection = draft.selection, !selection.isEmpty else { return nil }
        return AskPresentation.lineCount(selection)
    }
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

struct AskAttachChoices: View {
    enum Choice { case files, folder, clipboard }

    var clipboardHasImage: Bool
    var sourceToRestore: String?
    var selectionLinesToRestore: Int?
    var restoreEnabled = true
    var restore: (AskCapturedContentKind) -> Void = { _ in }
    var choose: (Choice) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            AskPopoverHeader(title: L("ask.attach.title"))
            row("ask.attach.files", "ask.attach.files.caption", "paperclip", .files)
            row("ask.attach.folder", "ask.attach.folder.caption", "folder", .folder)
            row("ask.attach.clipboard", "ask.attach.clipboard.caption", "doc.on.clipboard", .clipboard,
                enabled: clipboardHasImage)
            if sourceToRestore != nil || selectionLinesToRestore != nil {
                Divider().padding(.vertical, 5)
                if let sourceToRestore {
                    restoreRow(L("ask.context.restore.source", sourceToRestore), "app", .source)
                }
                if let selectionLinesToRestore {
                    restoreRow(L("ask.context.restore.selection", selectionLinesToRestore),
                               "text.alignleft", .selection)
                }
            }
        }
        .padding(.vertical, 6)
        .frame(width: 280)
    }

    private func restoreRow(_ title: String, _ symbol: String, _ kind: AskCapturedContentKind) -> some View {
        AskPopoverRow(title: title, selected: false, enabled: restoreEnabled, action: { restore(kind) }, accessory: {
            Image(systemName: symbol).font(.system(size: 12, weight: .medium))
        })
        .accessibilityIdentifier(kind == .source ? "ask.context.restore.source" : "ask.context.restore.selection")
    }

    private func row(_ title: String, _ caption: String, _ symbol: String,
                     _ choice: Choice, enabled: Bool = true) -> some View {
        AskPopoverRow(title: L(title), caption: L(caption), selected: false,
                      enabled: enabled, action: { choose(choice) }, accessory: {
            Image(systemName: symbol).font(.system(size: 12, weight: .medium))
        })
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
