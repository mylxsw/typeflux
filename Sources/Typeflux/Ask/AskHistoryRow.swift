import Foundation
import SwiftUI

/// A history row keeps its timestamp visible on hover. Deletion is available
/// from the conversation header and the row's context menu.
struct AskHistoryRow: View {
    let title: String
    let updatedAt: Date
    /// Kept on this Mac; marked only while signed in, when Cloud ones are listed too.
    var stored = false
    let selected: Bool
    let busy: Bool
    let selectionSpace: Namespace.ID
    var onSelect: () -> Void
    var onRename: (String) async throws -> Void = { _ in }
    var onDelete: () -> Void
    @State private var hovering = false
    @State private var editingTitle: String?
    @State private var savingTitle: String?
    @State private var renameError: String?
    @State private var editSession = UUID()
    @Environment(\.interfaceStyle) private var style

    var body: some View {
        Group {
            if let editingTitle {
                contents(editorTitle: editingTitle)
            } else {
                Button(action: onSelect) { contents(editorTitle: nil) }
                    .buttonStyle(AskPressableStyle.subtle)
            }
        }
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityAction(named: Text(L("ask.title.rename"))) { beginRename() }
        .contextMenu {
            Button(L("ask.title.rename"), action: beginRename).disabled(busy || savingTitle != nil)
            Button(L("ask.delete"), role: .destructive, action: onDelete).disabled(busy || savingTitle != nil)
        }
    }

    private func contents(editorTitle: String?) -> some View {
        HStack(spacing: 8) {
            // A conversation still working shows a breathing accent dot.
            if busy { AskRunToneDot(tone: .running) }
            if stored {
                Image(systemName: "lock").font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(AskTheme.privateTint)
                    .help(L("ask.storage.local"))
                    .accessibilityLabel(L("ask.storage.local"))
            }
            if let editorTitle {
                AskHistoryTitleEditor(title: editorTitle, selected: selected, onFinish: finishRename)
                    .id(editSession)
                    .padding(.horizontal, 4)
                    .frame(height: 24)
                    .background(AskTheme.controlSurface, in: RoundedRectangle(cornerRadius: 4))
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(AskTheme.accent.opacity(0.7), lineWidth: 1))
                if let renameError {
                    Image(systemName: "exclamationmark.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(StudioTheme.warning)
                        .help(renameError)
                        .accessibilityLabel(renameError)
                }
            } else {
                Text(savingTitle ?? title)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected || hovering ? StudioTheme.textPrimary : StudioTheme.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
            }
            if savingTitle != nil {
                ProgressView().controlSize(.mini)
            } else if editorTitle == nil, !busy {
                Text(AskPresentation.historyTimeLabel(updatedAt))
                    .font(.system(size: 11))
                    .foregroundStyle(StudioTheme.textTertiary)
                    .monospacedDigit()
            }
        }
        .padding(.leading, style.usesGlass ? 12 : 10)
        .padding(.trailing, 10)
        .frame(height: style.ask.sidebarRowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Selection is an accent-tinted glass pill, concentric with the panel,
        // that slides from the previous row to the new one. Classic marks it
        // with the system's flat grey source-list selection.
        .background {
            let shape = RoundedRectangle(cornerRadius: style.ask.sidebarRowCorner, style: .continuous)
            ZStack {
                if hovering, !selected { shape.fill(AskTheme.hoverFill).transition(.opacity) }
                if selected {
                    if style.usesGlass {
                        let tint = stored ? AskTheme.privateTint : AskTheme.accent
                        shape.fill(tint.opacity(0.18))
                            .overlay(shape.strokeBorder(tint.opacity(0.4), lineWidth: 0.5))
                            .shadow(color: tint.opacity(0.18), radius: 6, y: 2)
                            .matchedGeometryEffect(id: "ask.history.selection", in: selectionSpace)
                    } else {
                        shape.fill(AskClassic.selection)
                            .matchedGeometryEffect(id: "ask.history.selection", in: selectionSpace)
                    }
                }
            }
            .animation(.easeOut(duration: 0.15), value: hovering)
        }
        .contentShape(RoundedRectangle(cornerRadius: style.ask.sidebarRowCorner, style: .continuous))
    }

    private func beginRename() {
        guard !busy, savingTitle == nil, editingTitle == nil else { return }
        renameError = nil
        editSession = UUID()
        editingTitle = title
    }

    private func finishRename(_ draft: String?) {
        editingTitle = nil
        renameError = nil
        guard let draft, !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do {
            let cleaned = try AskConversationTitle.clean(draft)
            guard cleaned != title else { return }
            savingTitle = cleaned
            Task { @MainActor in
                do {
                    try await onRename(cleaned)
                    savingTitle = nil
                } catch {
                    savingTitle = nil
                    renameError = error.localizedDescription
                    editSession = UUID()
                    editingTitle = draft
                }
            }
        } catch {
            renameError = error.localizedDescription
            editSession = UUID()
            editingTitle = draft
        }
    }
}

