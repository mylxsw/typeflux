import SwiftUI

/// Uses the clipboard's existing panel, without opening a separate management window.
struct ClipboardSnippetEditor: View {
    @ObservedObject var model: ClipboardPanelModel
    @FocusState private var nameFocused: Bool
    @State private var showsAlias = false
    @Environment(\.interfaceStyle) private var style

    private func field(_ key: WritableKeyPath<ClipboardSnippetDraft, String>) -> Binding<String> {
        Binding(get: { model.snippetDraft?[keyPath: key] ?? "" }, set: { model.snippetDraft?[keyPath: key] = $0 })
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.3)
            TypefluxSheet(title: L(model.snippetDraft?.entry.snippet == nil
                                      ? "clipboard.action.saveSnippet" : "clipboard.action.editSnippet"),
                          cancelTitle: L("clipboard.edit.cancel"), confirmTitle: L("clipboard.snippet.save"),
                          confirmIdentifier: "snippet.save",
                          confirmShortcut: KeyboardShortcut(.return, modifiers: .command),
                          cancel: model.cancelSnippetEdit,
                          confirm: model.commitSnippet) {
                VStack(alignment: .leading, spacing: 12) {
                    if let error = model.snippetError {
                        Text(error).font(.subheadline).foregroundStyle(.red).accessibilityIdentifier("snippet.error")
                    }
                    Text(L("clipboard.snippet.name")).font(.subheadline)
                    TextField(L("clipboard.snippet.name"), text: field(\.name))
                        .textFieldStyle(.roundedBorder).focused($nameFocused).accessibilityIdentifier("snippet.name")
                    Text(L("clipboard.snippet.content")).font(.subheadline)
                    TextEditor(text: field(\.text))
                        .font(.body).scrollContentBackground(.hidden)
                        .padding(6).frame(height: 135)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(
                            cornerRadius: TypefluxRadius.textField.value(for: style)))
                        .accessibilityIdentifier("snippet.content")
                    DisclosureGroup(L("clipboard.snippet.alias"), isExpanded: $showsAlias) {
                        VStack(alignment: .leading, spacing: 6) {
                            TextField(L("clipboard.snippet.alias"), text: field(\.alias))
                                .textFieldStyle(.roundedBorder).accessibilityIdentifier("snippet.alias")
                            Text(L("clipboard.snippet.aliasHint")).font(.footnote)
                                .foregroundStyle(TypefluxColor.secondaryLabel.color)
                        }.padding(.top, 6)
                    }.font(.subheadline)
                    Text(L("clipboard.snippet.retentionHint"))
                        .font(.subheadline).foregroundStyle(TypefluxColor.secondaryLabel.color)
                }
            }
            .frame(width: 430)
        }
        .onAppear {
            nameFocused = true
            showsAlias = model.snippetDraft?.alias.isEmpty == false
        }
    }
}
