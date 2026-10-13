import SwiftUI

struct ModelCatalogView: View {
    let providerName: String
    let models: [RegisteredModel]
    let existingIDs: Set<String>
    @Binding var selected: Set<String>
    let onCancel: () -> Void
    let onAdd: () -> Void
    var provider: RegisteredProvider?
    @State private var search = ""

    private var addedCount: Int {
        selected.subtracting(existingIDs).count
    }

    var body: some View {
        TypefluxSheet(title: providerName + " · " + L("models.load"), cancelTitle: L("ask.models.cancel"),
                      confirmTitle: L("models.add") + " \(addedCount)", isConfirmEnabled: addedCount > 0,
                      cancel: onCancel, confirm: onAdd) {
            TypefluxInlineSearch(text: $search, prompt: L("models.search"))
            List {
                ForEach(models.filter { ModelSettingsPresentation.matches(search, terms: [$0.id, $0.name]) }) { model in
                    row(model)
                }
                if models.isEmpty {
                    Text(L("models.emptyCatalog")).foregroundStyle(.secondary)
                }
            }.listStyle(.inset).frame(height: 330)
        }.frame(width: 580)
    }

    private func row(_ model: RegisteredModel) -> some View {
        HStack(spacing: 12) {
            Toggle(isOn: Binding(get: { selected.contains(model.id) }, set: { value in
                guard !existingIDs.contains(model.id) else { return }
                if value {
                    selected.insert(model.id)
                } else {
                    selected.remove(model.id)
                }
            })) {
                HStack(spacing: 8) {
                    ModelIcon(model: model, provider: provider)
                    Text(model.id).font(.body)
                }
            }
            .toggleStyle(.checkbox)
            .disabled(existingIDs.contains(model.id) || model.exclusionReason != nil)
            Spacer(minLength: 4)
            if existingIDs.contains(model.id) {
                Text(L("models.alreadyAdded")).font(.body).foregroundStyle(TypefluxColor.secondaryLabel.color)
            } else if let reason = model.exclusionReason {
                Text(reason).font(.body).foregroundStyle(TypefluxColor.secondaryLabel.color)
            }
        }
    }
}
