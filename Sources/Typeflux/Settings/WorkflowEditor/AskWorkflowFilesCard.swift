import SwiftUI

/// The Keywords step's Files card (§2.3): every file of the workflow, entries marked
/// with the keywords that start them, the others with the files that use them.
struct AskWorkflowFilesCard: View {
    @ObservedObject var model: AskWorkflowEditorModel

    var body: some View {
        AskWorkflowFormSection(title: L("ask.workflow.editor.files.title"), hint: nil) {
            VStack(alignment: .leading, spacing: 10) {
                hint
                VStack(alignment: .leading, spacing: 0) {
                    let rows = model.fileRows
                    ForEach(Array(rows.enumerated()), id: \.element.path) { index, row in
                        if index > 0 {
                            Rectangle().fill(ModelVisualStyle.divider).frame(height: 1)
                        }
                        fileRow(row)
                    }
                    if rows.isEmpty {
                        Text(L("ask.workflow.editor.files.none")).font(.system(size: 12))
                            .foregroundStyle(StudioTheme.textTertiary).padding(14)
                    }
                }
                .background(ModelVisualStyle.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(ModelVisualStyle.border))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }

    /// "Entries are marked [Entry]. Other files can be used from an entry: Python `import helper`…"
    private var hint: some View {
        VStack(alignment: .leading, spacing: 4) {
            AgentFlowLayout(spacing: 4) {
                Text(L("ask.workflow.editor.files.hintEntry"))
                AskWorkflowEntryBadge(text: L("ask.workflow.editor.files.entry"))
                Text(L("ask.workflow.editor.files.hintUse"))
                AskWorkflowChip(text: "import helper")
                Text("Node")
                AskWorkflowChip(text: "require('./helper')")
                Text("zsh")
                AskWorkflowChip(text: "source ./lib.sh")
            }
            Text(L("ask.workflow.editor.files.hintDirectory"))
        }
        .font(.system(size: 12)).foregroundStyle(StudioTheme.textTertiary)
        .padding(.horizontal, 4)
    }

    private func fileRow(_ row: AskWorkflowFileReferences.Row) -> some View {
        HStack(spacing: 8) {
            Text(row.path).font(.system(size: 12.5, design: .monospaced)).foregroundStyle(AskTheme.accent)
                .lineLimit(1)
            if row.isEntry {
                AskWorkflowEntryBadge(text: ([L("ask.workflow.editor.files.entry")] + row.keywords)
                    .joined(separator: " · "))
            }
            Text(Self.note(for: row)).font(.system(size: 12)).foregroundStyle(StudioTheme.textTertiary)
                .lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 8)
            Button(L("ask.workflow.editor.files.open")) { model.openFile(row.path) }
                .buttonStyle(.plain).font(.system(size: 12, weight: .medium))
                .foregroundStyle(StudioTheme.textPrimary)
                .accessibilityIdentifier("ask.workflow.editor.files.open." + row.path)
        }
        .padding(.horizontal, 14).frame(height: 40)
    }

    /// "Default entry", "Used by main.py, table.py (import rates)", or what a README is.
    static func note(for row: AskWorkflowFileReferences.Row) -> String {
        if row.isDefault {
            return L("ask.workflow.editor.files.default")
        }
        if !row.references.isEmpty {
            let users = row.references.map(\.from)
            let statements = Array(Set(row.references.map(\.statement))).sorted()
            return L(
                "ask.workflow.editor.files.usedBy",
                users.joined(separator: L("ask.workflow.editor.files.separator")),
                statements.joined(separator: ", ")
            )
        }
        if row.path.lowercased().hasSuffix(".md") {
            return L("ask.workflow.editor.files.readme")
        }
        return ""
    }
}

/// "Entry" or "Entry · fx" in the accent color, for entry scripts.
struct AskWorkflowEntryBadge: View {
    var text: String

    var body: some View {
        Text(text).font(.system(size: 11, weight: .semibold)).foregroundStyle(AskTheme.accent)
            .padding(.horizontal, 6).frame(height: 19)
            .background(AskTheme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}
