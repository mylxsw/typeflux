import SwiftUI

struct AddModelEndpointView: View {
    @ObservedObject var library: AskModelLibrary
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var endpoint = "https://"
    @State private var key = ""
    @State private var model = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(L("models.addEndpoint")).font(.system(size: 17, weight: .semibold))
                Text(L("ask.models.compatible")).font(.system(size: 12))
                    .foregroundStyle(StudioTheme.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
            TextField(L("ask.models.name"), text: $name)
            TextField(L("ask.models.url"), text: $endpoint)
            SecureField("API Key", text: $key)
            TextField(L("ask.models.modelID"), text: $model)
            if let error {
                Text(error).foregroundStyle(.red).font(.caption)
            }
            HStack {
                Spacer()
                Button(L("ask.models.cancel")) { dismiss() }
                Button(L("ask.models.save")) {
                    do {
                        try library.save(.init(name: name, baseURL: endpoint, model: model), key: key)
                        dismiss()
                    } catch { self.error = error.localizedDescription }
                }.keyboardShortcut(.defaultAction)
            }
        }.textFieldStyle(.roundedBorder).padding(24).frame(width: 480)
    }
}
