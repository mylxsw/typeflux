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
    var usesNativeSelection = false
    var onSelect: () -> Void
    var onRename: (String) async throws -> Void = { _ in }
    var onDelete: () -> Void
    @State private var hovering = false
    @State private var editingTitle: String?
    @State private var savingTitle: String?
    @State private var renameError: String?
    @State private var editSession = UUID()
    @Environment(\.interfaceStyle) private var style
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.typefluxAccessibilityOptions) private var accessibility

    var body: some View {
        Group {
            if let editingTitle {
                contents(editorTitle: editingTitle)
            } else if usesNativeSelection {
                contents(editorTitle: nil)
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
            if busy {
                AskRunToneDot(tone: .running, tint: selected && !usesNativeSelection
                    ? TypefluxSpotlightRow.labelColor(selected: true) : nil)
            }
            if stored {
                Image(systemName: "lock").font(.footnote).fontWeight(.medium)
                    .foregroundStyle(labelColor())
                    .help(L("ask.storage.local"))
                    .accessibilityLabel(L("ask.storage.local"))
            }
            if let editorTitle {
                AskHistoryTitleEditor(title: editorTitle, selected: selected, onFinish: finishRename)
                    .id(editSession)
                    .padding(.horizontal, 4)
                    .frame(height: 24)
                    .background(TypefluxColor.controlBackground.color,
                                in: RoundedRectangle(cornerRadius: TypefluxRadius.textField.value(for: style)))
                    .overlay(RoundedRectangle(cornerRadius: TypefluxRadius.textField.value(for: style))
                        .strokeBorder(TypefluxColor.accent.color.opacity(0.7), lineWidth: 1))
                if let renameError {
                    Image(systemName: "exclamationmark.circle")
                        .font(.subheadline)
                        .foregroundStyle(TypefluxColor.warning.color)
                        .help(renameError)
                        .accessibilityLabel(renameError)
                }
            } else {
                titleLabel
                Spacer(minLength: 4)
            }
            if savingTitle != nil {
                ProgressView().controlSize(.mini)
            } else if editorTitle == nil, !busy {
                Text(AskPresentation.historyTimeLabel(updatedAt))
                    .font(.subheadline)
                    .foregroundStyle(labelColor(secondary: true))
                    .monospacedDigit()
            }
        }
        .padding(.leading, usesNativeSelection ? 10 : (style.usesGlass ? 12 : 10))
        .padding(.trailing, 10)
        .frame(height: style.ask.sidebarRowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Native List owns its selected fill and active/inactive label treatment.
        .background {
            let shape = RoundedRectangle(cornerRadius: style.ask.sidebarRowCorner, style: .continuous)
            ZStack {
                if hovering, !selected, !usesNativeSelection {
                    shape.fill(TypefluxColor.label.color.opacity(0.06)).transition(.opacity)
                }
                if selected, !usesNativeSelection {
                    shape.fill(TypefluxColor.selection.color)
                        .overlay {
                            if contrast == .increased || accessibility.increasedContrast {
                                shape.strokeBorder(TypefluxColor.label.color, lineWidth: 1)
                            }
                        }
                }
            }
            .animation(.easeOut(duration: 0.15), value: hovering)
        }
        .contentShape(RoundedRectangle(cornerRadius: style.ask.sidebarRowCorner, style: .continuous))
    }

    private var titleLabel: some View {
        Text(savingTitle ?? title)
            .font(.body).fontWeight(selected ? .semibold : .regular).lineLimit(1)
            .foregroundStyle(labelColor())
    }

    private func labelColor(secondary: Bool = false) -> AnyShapeStyle {
        if usesNativeSelection { return secondary ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary) }
        return AnyShapeStyle(TypefluxSpotlightRow.labelColor(selected: selected, secondary: secondary))
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
