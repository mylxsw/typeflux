import SwiftUI

@MainActor
struct ModuleHealthSettingsView: View {
    @ObservedObject var model: ModuleHealthSettingsModel

    var body: some View {
        TFFormSection(title: L("settings.services.title"), footnote: L("settings.services.hint")) {
            if model.entries.isEmpty {
                TFFootnote(text: L("settings.services.observationFailed"))
            }
            ForEach(Array(model.entries.enumerated()), id: \.element.id) { index, entry in
                if index > 0 { TFDivider.form }
                TFFormRow(title: L("settings.services.\(entry.id.rawValue)"),
                          detail: model.responseKey(entry.id).map { L($0) },
                          badge: L(model.statusKey(entry.id)),
                          badgeTint: model.health[entry.id]?.state == .ready ? TFColors.success : TFColors.textSecondary) {
                    TFButton(title: L("settings.services.recover"), systemImage: "arrow.clockwise",
                             isLoading: model.requests.contains(entry.id) || model.health[entry.id]?.state == .starting) {
                        model.recover(entry.id)
                    }
                    .disabled(!model.canRecover(entry.id))
                    .accessibilityIdentifier("settings.services.\(entry.id.rawValue).recover")
                }
            }
        }
        .accessibilityIdentifier("settings.services.section")
        .onAppear { model.startObserving() }
        .onDisappear { model.stopObserving() }
    }
}
