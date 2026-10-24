import AppKit
import SwiftUI

/// What one answer's "files changed this round" block lists: the files the round added or
/// modified, and the artifacts it kept. Intermediate `work/` files fold under one line.
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

/// The block at the end of an answer: "Files changed this round: added N · modified M". A row
/// opens its file in the side panel; hovering offers the external-open actions.
struct AskFileChangesView: View {
    let list: AskFileChangeList
    let actions: AskSidePanelActions
    @State private var showsProcess = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ForEach(list.main) { change in
                Rectangle().fill(AskTheme.separator).frame(height: 1)
                AskFileChangeRow(change: change, actions: actions)
            }
            ForEach(list.artifacts) { artifact in
                Rectangle().fill(AskTheme.separator).frame(height: 1)
                AskArtifactChangeRow(artifact: artifact, actions: actions)
            }
            if !list.process.isEmpty {
                Rectangle().fill(AskTheme.separator).frame(height: 1)
                processToggle
                if showsProcess {
                    ForEach(list.process) { change in
                        Rectangle().fill(AskTheme.separator).frame(height: 1)
                        AskFileChangeRow(change: change, actions: actions)
                    }
                }
            }
        }
        .background(AskTheme.monoSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(AskTheme.separator))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ask.fileChanges")
    }

    static func countText(added: Int, modified: Int) -> String {
        [added > 0 ? L("ask.fileChanges.added", added) : nil,
         modified > 0 ? L("ask.fileChanges.modified", modified) : nil]
            .compactMap { $0 }.joined(separator: " · ")
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.on.doc").font(.system(size: 11))
            Text(L("ask.fileChanges.title")).foregroundStyle(StudioTheme.textSecondary)
            Text(Self.countText(added: list.added, modified: list.modified))
                .fontWeight(.semibold).foregroundStyle(StudioTheme.textPrimary)
            Spacer(minLength: 6)
            Button(L("ask.fileChanges.showAll"), action: actions.showFiles)
                .buttonStyle(.plain)
                .foregroundStyle(AskTheme.accentText)
                .accessibilityIdentifier("ask.fileChanges.showAll")
        }
        .font(.system(size: 12.5))
        .foregroundStyle(StudioTheme.textTertiary)
        .lineLimit(1)
        .padding(.horizontal, 12)
        .frame(height: 34)
    }

    private var processToggle: some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) { showsProcess.toggle() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right").font(.system(size: 8.5, weight: .bold))
                    .rotationEffect(.degrees(showsProcess ? 90 : 0))
                Text(L("ask.fileChanges.process", list.process.count))
                Spacer(minLength: 0)
            }
            .font(.system(size: 12))
            .foregroundStyle(StudioTheme.textTertiary)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(showsProcess ? .isSelected : [])
        .accessibilityIdentifier("ask.fileChanges.process")
    }
}

/// The added/modified tag; hidden under the pointer, where the actions take its place.
private struct AskFileChangeTag: View {
    let added: Bool

    var body: some View {
        Text(L(added ? "ask.fileChanges.tag.added" : "ask.fileChanges.tag.modified"))
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(added ? StudioTheme.success : StudioTheme.warning)
            .padding(.horizontal, 6)
            .frame(height: 17)
            .background((added ? StudioTheme.success : StudioTheme.warning).opacity(0.13),
                        in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}

private struct AskFileChangeRow: View {
    let change: AskWorkspaceFileChange
    let actions: AskSidePanelActions
    @State private var hovering = false

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
                Button { AskFileExternalActions().openWithDefaultApplication(url) } label: {
                    Image(systemName: "arrow.up.forward.app").font(.system(size: 12))
                        .frame(width: 26, height: 26).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(StudioTheme.textSecondary)
                .help(L("ask.sidePanel.open.default"))
                .accessibilityLabel(L("ask.sidePanel.open.default"))
                Menu {
                    AskFileOpenMenuItems(file: url, showsShortcuts: false)
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
        .background(hovering ? AskTheme.hoverFill : .clear)
        .contentShape(Rectangle())
        .onTapGesture { actions.openFile(change.path) }
        .onHover { hovering = $0 }
        .contextMenu {
            Button(L("ask.sidePanel.open.inPanel")) { actions.openFile(change.path) }
            if let url { AskFileOpenMenuItems(file: url, showsShortcuts: false) }
        }
        .help(change.path)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: L("ask.sidePanel.open.inPanel")) { actions.openFile(change.path) }
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
        .background(hovering ? AskTheme.hoverFill : .clear)
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
