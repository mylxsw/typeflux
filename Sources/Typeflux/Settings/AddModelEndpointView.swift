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
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                ModelIconTile(size: 38) {
                    ModelProviderIcon(provider: .customLLM, size: 22)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("models.addEndpoint")).font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(StudioTheme.textPrimary)
                    Text(L("models.protocolHint")).font(.system(size: 12.5))
                        .foregroundStyle(StudioTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.bottom, 18)

            ModelSurface {
                VStack(alignment: .leading, spacing: 0) {
                    formRow(L("ask.models.name")) {
                        TextField(L("ask.models.name"), text: $name)
                            .textFieldStyle(ModelFieldStyle(monospaced: false))
                    }
                    ModelRowDivider()
                    formRow(L("models.protocol")) {
                        SettingsMenuPicker(title: L("models.protocol"),
                                           options: LLMRemoteAPIStyle.customChoices.map { (
                                               label: $0.displayName,
                                               value: $0
                                           ) },
                                           selection: $apiStyle)
                    }
                    ModelRowDivider()
                    formRow(L("ask.models.url")) {
                        TextField("https://api.example.com/v1", text: $endpoint)
                            .textFieldStyle(ModelFieldStyle())
                    }
                    ModelRowDivider()
                    formRow("API Key") { keyField }
                    ModelRowDivider()
                    formRow(L("ask.models.modelID")) {
                        TextField("gpt-5-sol", text: $model)
                            .textFieldStyle(ModelFieldStyle())
                    }
                }
            }

            if let error {
                Text(error).font(.system(size: 12)).foregroundStyle(StudioTheme.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4).padding(.top, 10)
            }

            HStack(spacing: 8) {
                Spacer()
                Button(L("ask.models.cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(L("ask.models.save"), action: save)
                    .buttonStyle(ModelActionStyle(primary: true))
                    .disabled(!canSave)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 20)
        }
        .buttonStyle(ModelActionStyle())
        .padding(24)
        .frame(width: 520)
        .background(ModelVisualStyle.canvas)
    }

    private var keyField: some View {
        Group {
            if showsKey {
                TextField("sk-…", text: $key)
            } else {
                SecureField("sk-…", text: $key)
            }
        }
        .textFieldStyle(ModelFieldStyle(trailingAccessoryWidth: 24))
        .overlay(alignment: .trailing) {
            Button { showsKey.toggle() } label: {
                Image(systemName: showsKey ? "eye.slash" : "eye")
                    .font(.system(size: 12)).foregroundStyle(StudioTheme.textSecondary)
                    .frame(width: 26, height: 26).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, 3)
            .help(L(showsKey ? "models.hideKey" : "models.showKey"))
            .accessibilityLabel(L(showsKey ? "models.hideKey" : "models.showKey"))
        }
    }

    private func formRow(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: 16) {
            Text(title).font(.system(size: 13)).foregroundStyle(StudioTheme.textSecondary)
                .frame(width: 80, alignment: .leading)
            content()
        }
        .padding(.horizontal, 18).padding(.vertical, 10)
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
