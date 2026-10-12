import SwiftUI

/// Uses the clipboard's existing panel, without opening a separate management window.
struct ClipboardSnippetEditor: View {
    @ObservedObject var model: ClipboardPanelModel
    @FocusState private var nameFocused: Bool
    @State private var showsAlias = false

    private func field(_ key: WritableKeyPath<ClipboardSnippetDraft, String>) -> Binding<String> {
        Binding(get: { model.snippetDraft?[keyPath: key] ?? "" }, set: { model.snippetDraft?[keyPath: key] = $0 })
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.3)
            VStack(alignment: .leading, spacing: 12) {
                Text(L(model.snippetDraft?.entry
                        .snippet == nil ? "clipboard.action.saveSnippet" : "clipboard.action.editSnippet"))
                    .font(.system(size: 14, weight: .semibold))
                if let error = model.snippetError {
                    Text(error).font(.system(size: 11)).foregroundStyle(.red).accessibilityIdentifier("snippet.error")
                }
                Text(L("clipboard.snippet.name")).font(.system(size: 11))
                TextField(L("clipboard.snippet.name"), text: field(\.name))
                    .textFieldStyle(.roundedBorder).focused($nameFocused).accessibilityIdentifier("snippet.name")
                Text(L("clipboard.snippet.content")).font(.system(size: 11))
                TextEditor(text: field(\.text))
                    .font(.system(size: 13)).scrollContentBackground(.hidden)
                    .padding(6).frame(height: 135)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                    .accessibilityIdentifier("snippet.content")
                DisclosureGroup(L("clipboard.snippet.alias"), isExpanded: $showsAlias) {
                    VStack(alignment: .leading, spacing: 6) {
                        TextField(L("clipboard.snippet.alias"), text: field(\.alias))
                            .textFieldStyle(.roundedBorder).accessibilityIdentifier("snippet.alias")
                        Text(L("clipboard.snippet.aliasHint")).font(.system(size: 10))
                            .foregroundStyle(StudioTheme.textSecondary)
                    }.padding(.top, 6)
                }.font(.system(size: 11))
                Text(L("clipboard.snippet.retentionHint"))
                    .font(.system(size: 11)).foregroundStyle(StudioTheme.textSecondary)
                HStack {
                    Spacer()
                    Button(L("clipboard.edit.cancel"), action: model.cancelSnippetEdit)
                    Button(L("clipboard.snippet.save"), action: model.commitSnippet).buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("snippet.save")
                }
            }
            .padding(18).frame(width: 430)
            .background(AskTheme.launcherSurface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.12)))
            .shadow(color: .black.opacity(0.25), radius: 16, y: 6)
        }
        .onAppear {
            nameFocused = true
            showsAlias = model.snippetDraft?.alias.isEmpty == false
        }
    }
}
