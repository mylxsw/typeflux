import SwiftUI

struct ModelCatalogView: View {
    let providerName: String
    let models: [RegisteredModel]
    let existingIDs: Set<String>
    @Binding var selected: Set<String>
    let onCancel: () -> Void
    let onAdd: () -> Void
    @State private var search = ""

    private var addedCount: Int {
        selected.subtracting(existingIDs).count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(providerName + " · " + L("models.load")).font(.system(size: 16, weight: .semibold))
                Spacer()
                Button(L("ask.models.cancel"), action: onCancel).keyboardShortcut(.cancelAction)
                Button(L("models.add") + " \(addedCount)", action: onAdd)
                    .buttonStyle(ModelActionStyle(primary: true))
                    .disabled(addedCount == 0).keyboardShortcut(.defaultAction)
            }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(StudioTheme.textSecondary)
                TextField(L("models.search"), text: $search).textFieldStyle(.plain)
            }.font(.system(size: 13)).padding(.horizontal, 10).frame(height: 30)
                .background(
                    ModelVisualStyle.control,
                    in: RoundedRectangle(cornerRadius: ModelVisualStyle.controlCornerRadius, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: ModelVisualStyle.controlCornerRadius, style: .continuous)
                        .strokeBorder(ModelVisualStyle.border)
                )
            ModelSurface {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(models
                            .filter { search.isEmpty || $0.id.localizedCaseInsensitiveContains(search) }) { model in
                                row(model)
                                ModelRowDivider(leading: 14)
                            }
                        if models.isEmpty {
                            Text(L("models.emptyCatalog")).font(.system(size: 13))
                                .foregroundStyle(StudioTheme.textTertiary).padding(20)
                        }
                    }
                }
            }
        }.padding(20).frame(width: 580, height: 470).background(ModelVisualStyle.canvas)
            .buttonStyle(ModelActionStyle())
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
            })) { Text(model.id).font(.system(size: 13, design: .monospaced)) }
                .toggleStyle(ModelCheckboxStyle())
                .disabled(model.exclusionReason != nil && !existingIDs.contains(model.id))
            Spacer(minLength: 4)
            if existingIDs.contains(model.id) {
                Text(L("models.alreadyAdded")).font(.system(size: 11)).foregroundStyle(StudioTheme.textSecondary)
            } else if let reason = model.exclusionReason {
                Text(reason).font(.system(size: 11)).foregroundStyle(StudioTheme.textSecondary)
            }
        }.padding(.horizontal, 14).frame(height: 44)
    }
}
