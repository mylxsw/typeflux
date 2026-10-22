import Foundation
import SwiftUI

/// A history row keeps its timestamp visible on hover. Deletion is available
/// from the conversation header and the row's context menu.
struct AskHistoryRow: View {
    let title: String
    let updatedAt: Date
    let selected: Bool
    let busy: Bool
    /// Kept on this Mac while the list mixes it with Cloud conversations: a small
    /// neutral lock tells it apart without colouring the row.
    var local = false
    /// Work on this Mac rather than a chat; a small neutral glyph leads the title.
    var work = false
    /// Another device runs it (read-only here); its name is the glyph's help.
    var host: String? = nil
    let selectionSpace: Namespace.ID
    var onSelect: () -> Void
    var onRename: (String) async throws -> Void = { _ in }
    var onOpenWorkspace: () -> Void = {}
    var onDelete: () -> Void
    @State private var hovering = false
    @State private var editingTitle: String?
    @State private var savingTitle: String?
    @State private var renameError: String?
    @State private var editSession = UUID()
    @Environment(\.interfaceStyle) private var style
    @Environment(\.colorScheme) private var colorScheme

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
            Button(L("ask.workspace.openFolder"), action: onOpenWorkspace)
            Button(L("ask.title.rename"), action: beginRename).disabled(busy || savingTitle != nil)
            Button(L("ask.delete"), role: .destructive, action: onDelete).disabled(busy || savingTitle != nil)
        }
    }

    private func contents(editorTitle: String?) -> some View {
        HStack(spacing: 8) {
            // A conversation still working shows a breathing accent dot.
            if busy { AskRunToneDot(tone: .running) }
            if let host, !busy {
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(StudioTheme.textTertiary)
                    .help(L("ask.host.runsOn", host))
                    .accessibilityLabel(L("ask.host.runsOn", host))
                    .accessibilityIdentifier("ask.history.hostMark")
            } else if work, !busy {
                Image(systemName: AskConversationKind.work.symbol)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(StudioTheme.textTertiary)
                    .accessibilityLabel(L(AskConversationKind.work.titleKey))
                    .accessibilityIdentifier("ask.history.workMark")
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
                    .foregroundStyle(Self.titleColor(hovering: hovering))
                    .lineLimit(1)
                Spacer(minLength: 4)
            }
            if local, editorTitle == nil {
                Image(systemName: AskStorageKind.local.symbol)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(StudioTheme.textTertiary)
                    .accessibilityLabel(L(AskStorageKind.local.titleKey))
                    .accessibilityIdentifier("ask.history.localMark")
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
        // White selection rises gently above the quiet light sidebar. Dark
        // glass lifts it with a neutral wash while the title keeps its normal color;
        // classic keeps its source-list selection.
        .background {
            let shape = RoundedRectangle(cornerRadius: style.ask.sidebarRowCorner, style: .continuous)
            ZStack {
                if hovering, !selected { shape.fill(AskTheme.hoverFill).transition(.opacity) }
                if selected {
                    if colorScheme == .light {
                        shape.fill(.white)
                            .overlay(shape.strokeBorder(AskTheme.librarySeparator, lineWidth: 0.5))
                            .shadow(color: .black.opacity(0.08), radius: 1, y: 1)
                            .matchedGeometryEffect(id: "ask.history.selection", in: selectionSpace)
                    } else if style.usesGlass {
                        shape.fill(AskTheme.pressFill)
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

    /// Selection is conveyed by the background and font weight, not the title color.
    static func titleColor(hovering: Bool) -> Color {
        hovering ? StudioTheme.textPrimary : StudioTheme.textSecondary
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
