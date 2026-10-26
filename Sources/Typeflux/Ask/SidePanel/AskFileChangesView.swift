import AppKit
import SwiftUI

/// What one answer's "files changed this round" block lists: the files the round added or
/// modified, and the artifacts it kept. Workspace groups share one disclosure.
struct AskFileChangeList: Equatable {
    struct Artifact: Equatable, Identifiable {
        let ref: AskArtifactRef
        let name: String
        var id: String { ref.id }
    }

    var main: [AskWorkspaceFileChange] = []
    var process: [AskWorkspaceFileChange] = []
    var artifacts: [Artifact] = []

    init(changes: [AskWorkspaceFileChange], artifacts: [Artifact] = []) {
        main = changes.filter { !$0.isProcess }
        process = changes.filter(\.isProcess)
        self.artifacts = artifacts
    }

    var isEmpty: Bool { main.isEmpty && process.isEmpty && artifacts.isEmpty }
    /// Artifacts are new copies, so they count as added.
    var added: Int { (main + process).filter { $0.kind == .added }.count + artifacts.count }
    var modified: Int { (main + process).filter { $0.kind == .modified }.count }

    /// Non-image artifacts of the answer, named by the step that kept them. Images stay
    /// inline in the answer as pictures.
    static func artifacts(_ outputs: AskRunOutputs) -> [Artifact] {
        outputs.storedArtifacts.filter { !$0.mediaType.hasPrefix("image/") }.map { ref in
            Artifact(ref: ref, name: outputs.storedArtifactNames[ref.id] ?? AskArtifactTab.defaultName(ref))
        }
    }
}

/// A compact disclosure at the end of an answer. All workspace files share one list;
/// directory names alone do not establish whether a file is a deliverable.
struct AskFileChangesView: View {
    let list: AskFileChangeList
    let actions: AskSidePanelActions
    @State var isExpanded = false
    @State private var hovering = false
    @Environment(\.askInspectTranscript) private var inspectTranscript

    private var files: [AskWorkspaceFileChange] { list.main + list.process }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if isExpanded {
                ForEach(Array(files.prefix(5))) { change in
                    AskFileChangeRow(change: change, actions: actions)
                }
                ForEach(Array(list.artifacts.prefix(max(0, 5 - files.count)))) { artifact in
                    AskArtifactChangeRow(artifact: artifact, actions: actions)
                }
                Button(action: actions.showFiles) {
                    HStack(spacing: 6) {
                        Text(L("ask.fileChanges.showAll"))
                        Image(systemName: "arrow.right").font(.system(size: 10))
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(StudioTheme.textSecondary)
                    .padding(.horizontal, 12)
                    .frame(height: 36)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("ask.fileChanges.showAll")
            }
        }
        .background(StudioTheme.rowSurface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ask.fileChanges")
    }

    static func countText(added: Int, modified: Int) -> String {
        [added > 0 ? L("ask.fileChanges.added", added) : nil,
         modified > 0 ? L("ask.fileChanges.modified", modified) : nil]
            .compactMap { $0 }.joined(separator: " · ")
    }

    private var header: some View {
        Button {
            inspectTranscript()
            isExpanded.toggle()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "doc.on.doc").font(.system(size: 12))
                    .foregroundStyle(StudioTheme.textSecondary)
                Text(L("ask.fileChanges.title"))
                    .fontWeight(.medium).foregroundStyle(StudioTheme.textPrimary)
                    .layoutPriority(1)
                Text(Self.countText(added: list.added, modified: list.modified))
                    .foregroundStyle(StudioTheme.textSecondary)
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .medium))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .foregroundStyle(StudioTheme.textSecondary)
            }
            .font(.system(size: 12.5))
            .lineLimit(1)
            .padding(.horizontal, 12)
            .frame(height: 40)
            .contentShape(Rectangle())
            .background(hovering ? StudioTheme.textPrimary.opacity(0.05) : .clear)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityValue(isExpanded ? L("ask.fileChanges.expanded") : L("ask.fileChanges.collapsed"))
        .accessibilityIdentifier("ask.fileChanges.toggle")
    }
}

/// The added/modified tag; hidden under the pointer, where the actions take its place.
private struct AskFileChangeTag: View {
    let added: Bool

    var body: some View {
        Text(L(added ? "ask.fileChanges.tag.added" : "ask.fileChanges.tag.modified"))
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(added ? StudioTheme.success : AskTheme.accentText)
            .padding(.horizontal, 6)
            .frame(height: 17)
            .background((added ? StudioTheme.success : AskTheme.accentText).opacity(0.13),
                        in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}

private struct AskFileChangeRow: View {
    let change: AskWorkspaceFileChange
    let actions: AskSidePanelActions
    @State private var hovering = false

    private func reference(_ url: URL) -> (() -> Void)? {
        actions.referenceFile.map { reference in { reference(url) } }
    }

    var body: some View {
        let url = actions.fileURL(change.path)
        HStack(spacing: 10) {
            AskWorkspaceFileIconView(pathExtension: (change.path as NSString).pathExtension.lowercased(), size: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(change.name).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(StudioTheme.textPrimary)
                Text([change.path, change.summary].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 11.5)).foregroundStyle(StudioTheme.textTertiary)
                    .lineLimit(1).truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if hovering, let url {
                if let onReference = reference(url) {
                    AskFileReferenceButton(action: onReference, size: 26)
                        .accessibilityIdentifier("ask.fileChanges.reference")
                }
                Button { AskFileExternalActions().openWithDefaultApplication(url) } label: {
                    Image(systemName: "arrow.up.forward.app").font(.system(size: 12))
                        .frame(width: 26, height: 26).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(StudioTheme.textSecondary)
                .help(L("ask.sidePanel.open.default"))
                .accessibilityLabel(L("ask.sidePanel.open.default"))
                Menu {
                    AskFileOpenMenuItems(file: url, showsShortcuts: false, onReference: reference(url))
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 12)).frame(width: 26, height: 26)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel(L("ask.sidePanel.open.menu"))
            } else {
                AskFileChangeTag(added: change.kind == .added)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(hovering ? StudioTheme.textPrimary.opacity(0.05) : .clear)
        .contentShape(Rectangle())
        .onTapGesture { actions.openFile(change.path) }
        .onHover { hovering = $0 }
        .contextMenu {
            Button(L("ask.sidePanel.open.inPanel")) { actions.openFile(change.path) }
            if let url { AskFileOpenMenuItems(file: url, showsShortcuts: false, onReference: reference(url)) }
        }
        .onDrag { AskWorkspaceFileDrag.provider(url) }
        .help(change.path)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: L("ask.sidePanel.open.inPanel")) { actions.openFile(change.path) }
        .accessibilityReferenceAction(url.flatMap(reference))
    }
}

private struct AskArtifactChangeRow: View {
    let artifact: AskFileChangeList.Artifact
    let actions: AskSidePanelActions
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "shippingbox").font(.system(size: 15)).foregroundStyle(StudioTheme.textTertiary)
                .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(artifact.name).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(StudioTheme.textPrimary)
                Text(L("ask.artifact.device") + " · " + ByteCountFormatter.string(fromByteCount: artifact.ref.sizeBytes,
                                                                                 countStyle: .file))
                    .font(.system(size: 11.5)).foregroundStyle(StudioTheme.textTertiary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            AskFileChangeTag(added: true)
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(hovering ? StudioTheme.textPrimary.opacity(0.05) : .clear)
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .onHover { hovering = $0 }
        .help(artifact.name)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: L("ask.sidePanel.open.inPanel"), open)
    }

    private func open() { actions.openArtifact(artifact.ref, artifact.name) }
}
