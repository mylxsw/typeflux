import SwiftUI

/// A native lookup form keeps creation separate from filtering the saved library.
struct AskWordBookLookupView: View {
    @ObservedObject var model: AskWordBookViewModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    var body: some View {
        TypefluxSheet(title: L("ask.wordBook.firstLookup"), cancelTitle: L("common.cancel"),
                      confirmTitle: L("ask.wordBook.lookup.open"),
                      isConfirmEnabled: !model.lookupText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        && model.lookingUp == nil,
                      cancel: { dismiss() }, confirm: lookUp, content: {
            VStack(alignment: .leading, spacing: 12) {
                TextField(L("ask.wordBook.lookup.placeholder"), text: $model.lookupText)
                    .textFieldStyle(.roundedBorder).focused($focused).onSubmit(lookUp)
                    .accessibilityIdentifier("ask.wordBook.lookup")
                TypefluxButton(model.directionTitle, action: model.cycleTarget)
                    .accessibilityLabel(L("ask.wordBook.lookup.direction"))
                    .help(L("ask.wordBook.lookup.direction"))
                if let preview = model.preview {
                    switch preview {
                    case let .kept(meanings): Text(L("ask.wordBook.lookup.kept") + " · " + meanings)
                    case let .device(translation): Text(L("ask.plugin.source.device") + " · " + translation)
                    }
                }
            }
            .font(.body).frame(width: 360)
        })
        .onAppear { focused = true }
        .task(id: model.lookupText) {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await model.refreshPreview()
        }
    }

    private func lookUp() {
        guard !model.lookupText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              model.lookingUp == nil else { return }
        let text = model.lookupText
        dismiss()
        Task { await model.lookUp(text) }
    }
}
