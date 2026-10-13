import SwiftUI

/// Sheet for registering a model endpoint and its wire protocol.
struct AddModelEndpointView: View {
    @ObservedObject var library: AskModelLibrary
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var endpoint = "https://"
    @State private var key = ""
    @State private var model = ""
    @State private var apiStyle = LLMRemoteAPIStyle.openAICompatible
    @State private var showsKey = false
    @State private var error: String?

    private var canSave: Bool {
        ModelSettingsPresentation.canAddEndpoint(name: name, baseURL: endpoint, model: model)
    }

    var body: some View {
        TypefluxSheet(title: L("models.addEndpoint"), cancelTitle: L("ask.models.cancel"),
                      confirmTitle: L("ask.models.save"), isConfirmEnabled: canSave,
                      cancel: { dismiss() }, confirm: save, content: {
            Text(L("models.protocolHint")).font(.subheadline).foregroundStyle(.secondary)
            TypefluxForm {
                Section {
                    ModelFormRow(title: L("ask.models.name")) { TypefluxTextField(L("ask.models.name"), text: $name) }
                    ModelFormRow(title: L("models.protocol")) {
                        TypefluxPopup(L("models.protocol"), selection: $apiStyle, borderless: true) {
                            ForEach(LLMRemoteAPIStyle.customChoices, id: \.self) { style in
                                Text(style.displayName).tag(style)
                            }
                        }
                    }
                    ModelFormRow(title: L("ask.models.url")) {
                        TypefluxTextField(L("ask.models.url"), text: $endpoint, prompt: "https://api.example.com/v1")
                    }
                    ModelFormRow(title: "API Key") {
                        HStack {
                            if showsKey {
                                TypefluxTextField("API Key", text: $key)
                            } else {
                                TypefluxSecureField("API Key", text: $key)
                            }
                            TypefluxIconButton(L(showsKey ? "models.hideKey" : "models.showKey"),
                                               systemImage: showsKey ? "eye.slash" : "eye") { showsKey.toggle() }
                        }
                    }
                    ModelFormRow(title: L("ask.models.modelID")) {
                        TypefluxTextField(L("ask.models.modelID"), text: $model, prompt: "gpt-5-sol")
                    }
                }
                if let error {
                    Text(error).foregroundStyle(TypefluxColor.danger.color)
                }
            }.frame(height: 320)
        }).frame(width: 560)
    }

    private func save() {
        guard canSave else { return }
        do {
            // Pasted values often carry stray whitespace that would fail URL validation.
            let trim: (String) -> String = { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            try library.save(
                .init(name: trim(name), baseURL: trim(endpoint), model: trim(model), apiStyle: apiStyle),
                key: trim(key)
            )
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
