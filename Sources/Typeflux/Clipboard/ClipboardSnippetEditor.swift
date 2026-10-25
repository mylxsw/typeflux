import SwiftUI

/// Uses the clipboard's existing panel, without opening a separate management window.
struct ClipboardSnippetEditor: View {
    @ObservedObject var model: ClipboardPanelModel
    @FocusState private var nameFocused: Bool
    @State private var showsAlias = false

    private func field(_ key: WritableKeyPath<ClipboardSnippetDraft, String>) -> Binding<String> {
        Binding(get: { model.snippetDraft?[keyPath: key] ?? "" }, set: {
            model.snippetDraft?[keyPath: key] = $0
            model.snippetError = nil
        })
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.opacity(0.3)
                    .contentShape(Rectangle())
                    .onTapGesture {} // Keep clicks outside the editor from reaching the clipboard list.
                VStack(alignment: .leading, spacing: 0) {
                    header.padding(20)
                    Divider().overlay(TFColors.border)
                    ScrollView {
                        form(contentHeight: min(220, max(100, geometry.size.height - (showsAlias ? 450 : 370))))
                            .padding(20)
                    }
                    Divider().overlay(TFColors.border)
                    footer.padding(.horizontal, 20).padding(.vertical, 14)
                }
                .frame(width: min(480, max(0, geometry.size.width - 32)))
                .frame(maxHeight: max(0, geometry.size.height - 32))
                .modifier(AskInWindowGlass(corner: TFMetrics.sheetCornerRadius,
                                           opaqueFill: ModelVisualStyle.canvas, elevation: .popover))
                .padding(16)
            }
        }
        .foregroundStyle(TFColors.textPrimary)
        .tfControlSize(.regular)
        .onAppear {
            nameFocused = true
            showsAlias = model.snippetDraft?.alias.isEmpty == false
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            TFIconTile(systemImage: "text.badge.plus", style: .neutral)
            Text(L(model.snippetDraft?.entry.snippet == nil
                    ? "clipboard.action.saveSnippet" : "clipboard.action.editSnippet"))
                .font(.system(size: 14, weight: .semibold))
            Spacer(minLength: 0)
        }
    }

    private func form(contentHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                TFSectionHeader(title: L("clipboard.snippet.name"))
                TextField(L("clipboard.snippet.name"), text: field(\.name))
                    .textFieldStyle(TFTextFieldStyle())
                    .focused($nameFocused)
                    .accessibilityIdentifier("snippet.name")
            }
            VStack(alignment: .leading, spacing: 6) {
                TFSectionHeader(title: L("clipboard.snippet.content"))
                TFTextArea(label: L("clipboard.snippet.content"), text: field(\.text), height: contentHeight)
                    .accessibilityIdentifier("snippet.content")
            }
            VStack(alignment: .leading, spacing: 6) {
                TFSectionHeader(title: L("clipboard.snippet.alias"), isExpanded: $showsAlias,
                                identifier: "snippet.alias.disclosure")
                if showsAlias {
                    TextField(L("clipboard.snippet.alias"), text: field(\.alias))
                        .textFieldStyle(TFTextFieldStyle())
                        .accessibilityIdentifier("snippet.alias")
                    TFFieldMessage(text: L("clipboard.snippet.aliasHint"), tone: .hint)
                }
            }
            TFFootnote(text: L("clipboard.snippet.retentionHint"))
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let error = model.snippetError {
                TFFieldMessage(text: error).accessibilityIdentifier("snippet.error")
            }
            HStack(spacing: TFMetrics.toolbarSpacing) {
                Spacer()
                TFButton(title: L("clipboard.edit.cancel"), action: model.cancelSnippetEdit)
                    .accessibilityIdentifier("snippet.cancel")
                TFButton(title: L("clipboard.snippet.save"), kind: .primary, action: model.commitSnippet)
                    .help("⌘↩")
                    .accessibilityIdentifier("snippet.save")
            }
        }
    }
}
