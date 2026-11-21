import AppKit
import SwiftUI

/// What one answer's "files changed this round" block lists: the files the round added or
/// modified, and the artifacts it kept. Workspace groups share one disclosure.
struct AskFileChangeList: Equatable {
    struct Artifact: Equatable, Identifiable {
        let ref: AskArtifactRef
        let name: String
        var id: String {
            ref.id
        }
    }

    var main: [AskWorkspaceFileChange] = []
    var process: [AskWorkspaceFileChange] = []
    var artifacts: [Artifact] = []

    init(changes: [AskWorkspaceFileChange], artifacts: [Artifact] = []) {
        main = changes.filter { !$0.isProcess }
        process = changes.filter(\.isProcess)
        self.artifacts = artifacts
    }

    var isEmpty: Bool {
        main.isEmpty && process.isEmpty && artifacts.isEmpty
    }

    /// Artifacts are new copies, so they count as added.
    var added: Int {
        (main + process).count(where: { $0.kind == .added }) + artifacts.count
    }

    var modified: Int {
        (main + process).count(where: { $0.kind == .modified })
    }

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
    @State var isExpanded = true
    @Environment(\.askInspectTranscript) private var inspectTranscript

    private var files: [AskWorkspaceFileChange] {
        list.main + list.process
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if isExpanded {
                Divider()
                ForEach(Array(files.prefix(5))) { change in
                    AskFileChangeRow(change: change, actions: actions)
                }
                ForEach(Array(list.artifacts.prefix(max(0, 5 - files.count)))) { artifact in
                    AskArtifactChangeRow(artifact: artifact, actions: actions)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ask.fileChanges")
    }

    static func countText(added: Int, modified: Int) -> String {
        [added > 0 ? L("ask.fileChanges.added", added) : nil,
         modified > 0 ? L("ask.fileChanges.modified", modified) : nil]
            .compactMap(\.self).joined(separator: " · ")
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button {
                inspectTranscript()
                isExpanded.toggle()
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    Text(L("ask.fileChanges.title"))
                        .fontWeight(.semibold)
                        .foregroundStyle(StudioTheme.textPrimary)
                    Text(verbatim: (files.count + list.artifacts.count).formatted())
                        .monospacedDigit()
                    Spacer(minLength: 0)
                }
                .frame(minHeight: 30)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L("ask.fileChanges.title") + ", " + Self.countText(added: list.added, modified: list.modified))
            .accessibilityValue(isExpanded ? L("ask.fileChanges.expanded") : L("ask.fileChanges.collapsed"))
            .accessibilityIdentifier("ask.fileChanges.toggle")
            Button(action: actions.showFiles) {
                HStack(spacing: 4) {
                    Text(L("ask.fileChanges.showAll"))
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                }
                .font(.system(size: 11.5))
                .frame(minHeight: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("ask.fileChanges.showAll")
        }
        .foregroundStyle(StudioTheme.textSecondary)
        .font(.system(size: 12.5))
        .lineLimit(1)
        .frame(minHeight: 30)
    }
}

private struct AskFileChangeLabel: View {
    let added: Bool
    let name: String
    var directory = ""

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: added ? "plus" : "pencil")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(added ? StudioTheme.success : AskTheme.accentText)
                    .frame(width: 14)
                    .accessibilityHidden(true)
                ZStack(alignment: .leading) {
                    // Reserve the same localized status column for every filename.
                    Text(L(added ? "ask.fileChanges.tag.modified" : "ask.fileChanges.tag.added")).hidden()
                    Text(L(added ? "ask.fileChanges.tag.added" : "ask.fileChanges.tag.modified"))
                }
                .font(.system(size: 11.5))
            }
            .fixedSize()
            Text(verbatim: name)
                .fontWeight(.medium)
                .layoutPriority(1)
            if !directory.isEmpty {
                Text(verbatim: directory)
                    .foregroundStyle(StudioTheme.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 12))
        .foregroundStyle(StudioTheme.textPrimary)
        .lineLimit(1)
        .truncationMode(.middle)
        .frame(minHeight: 32)
        .contentShape(Rectangle())
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
        let name = AskWorkspaceFile.displayName(change.path)
        let directory = change.path.lastIndex(of: "/").map { String(change.path[...$0]) } ?? ""
        HStack(spacing: 4) {
            Button { actions.openFile(change.path) } label: {
                AskFileChangeLabel(added: change.kind == .added, name: name, directory: directory)
            }
            .buttonStyle(.plain)
            .accessibilityReferenceAction(url.flatMap(reference))
            .onDrag { AskWorkspaceFileDrag.provider(url) }
            if let url {
                if hovering {
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
                }
                AskFileMoreButton(items: AskFileOpenMenuItems(file: url, showsShortcuts: false,
                                                              onReference: reference(url)))
                    .accessibilityIdentifier("ask.fileChanges.more")
            }
        }
        .padding(.leading, 12).padding(.trailing, 2)
        .background(hovering ? StudioTheme.textPrimary.opacity(0.05) : .clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu {
            Button(L("ask.sidePanel.open.inPanel")) { actions.openFile(change.path) }
            if let url { AskFileOpenMenuItems(file: url, showsShortcuts: false, onReference: reference(url)) }
        }
        .help(change.path)
        .accessibilityElement(children: .contain)
    }
}

private struct AskArtifactChangeRow: View {
    let artifact: AskFileChangeList.Artifact
    let actions: AskSidePanelActions
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            AskFileChangeLabel(added: true, name: artifact.name)
        }
        .buttonStyle(.plain)
        .padding(.leading, 12).padding(.trailing, 2)
        .background(hovering ? StudioTheme.textPrimary.opacity(0.05) : .clear)
        .onHover { hovering = $0 }
        .help(artifact.name)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: L("ask.sidePanel.open.inPanel"), open)
    }

    private func open() {
        actions.openArtifact(artifact.ref, artifact.name)
    }
}
