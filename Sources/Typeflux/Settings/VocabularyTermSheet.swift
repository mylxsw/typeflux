import SwiftUI

struct VocabularyTermSheet: View {
    @Binding var term: String
    let isEditing: Bool
    let onCancel: () -> Void
    let onSave: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        TypefluxSheet(title: L(isEditing ? "vocabulary.sheet.editTitle" : "vocabulary.sheet.title"),
                      cancelTitle: L("common.cancel"),
                      confirmTitle: L(isEditing ? "common.save" : "vocabulary.action.addWord"),
                      isConfirmEnabled: !term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      cancel: onCancel, confirm: onSave) {
            Text(L(isEditing ? "vocabulary.sheet.editSubtitle" : "vocabulary.sheet.subtitle"))
                .font(.subheadline).foregroundStyle(.secondary)
            TypefluxTextField(L("vocabulary.sheet.placeholder"), text: $term)
                .focused($isFocused)
                .accessibilityIdentifier("vocabulary.sheet.term")
        }
        .frame(width: 480)
        .onAppear { isFocused = true }
    }
}
