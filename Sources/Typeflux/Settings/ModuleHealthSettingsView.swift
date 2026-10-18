import SwiftUI

@MainActor
struct ModuleHealthSettingsView: View {
    @ObservedObject var model: ModuleHealthSettingsModel
    @State private var showsDiagnostics = false

    private var summaryTitle: String {
        switch model.summaryKey {
        case "settings.services.summaryUnavailable": L(model.summaryKey, model.unavailableCount)
        case "settings.services.summaryRecovering": L(model.summaryKey, model.affectedFeatureCount)
        default: L(model.summaryKey)
        }
    }

    private var summaryDetail: String {
        switch model.summaryKey {
        case "settings.services.summaryUnavailable": L("settings.services.summaryUnavailableDetail")
        case "settings.services.summaryRecovering": L("settings.services.recoveringDetail")
        case "settings.services.summaryUnknown": L("settings.services.summaryUnknownDetail")
        default: L("settings.services.summaryHealthyDetail")
        }
    }

    private var summarySymbol: String {
        switch model.summaryKey {
        case "settings.services.summaryUnavailable": "exclamationmark.circle"
        case "settings.services.summaryRecovering": "arrow.clockwise.circle"
        case "settings.services.summaryUnknown": "questionmark.circle"
        default: "checkmark.circle"
        }
    }

    var body: some View {
        TFFormSection(title: L("settings.services.title"),
                      footnote: model.affectedEntries.contains { model.canOfferRetry($0.id) }
                          ? L("settings.services.hint") : nil) {
            TFFormRow(title: summaryTitle, valueText: summaryDetail,
                      systemImage: summarySymbol,
                      imageTint: model.summaryKey == "settings.services.summaryHealthy"
                          ? TFColors.success : TFColors.warning) {
                EmptyView()
            }

            ForEach(model.affectedEntries, id: \.id) { entry in
                TFDivider.form
                TFFormRow(title: L(model.featureKey(entry.id)),
                          valueText: model.responseKey(entry.id).map { L($0) } ?? L(model.detailKey(entry.id)),
                          badge: L(model.statusKey(entry.id)), badgeTint: TFColors.warning) {
                    if model.canOfferRetry(entry.id) {
                        TFButton(title: L("settings.services.retry"), systemImage: "arrow.clockwise",
                                 isLoading: model.requests.contains(entry.id)) {
                            model.recover(entry.id)
                        }
                        .accessibilityIdentifier("settings.services.\(entry.id.rawValue).recover")
                    }
                }
            }

            if !model.observationFailed.isEmpty {
                TFDivider.form
                TFFormRow(title: L("settings.services.summaryUnknown"),
                          valueText: L("settings.services.summaryUnknownDetail")) { EmptyView() }
            }

            if !model.entries.isEmpty {
                TFDivider.form
                TFDisclosureRow(title: L("settings.services.diagnostics"), isExpanded: $showsDiagnostics)
                    .accessibilityIdentifier("settings.services.diagnostics")
                if showsDiagnostics {
                    ForEach(model.entries, id: \.id) { entry in
                        TFDivider.form
                        TFFormRow(title: L("settings.services.\(entry.id.rawValue)"),
                                  valueText: model.responseKey(entry.id).map { L($0) },
                                  badge: L(model.statusKey(entry.id)),
                                  badgeTint: !model.observationFailed.contains(entry.id) && model.health[entry.id]?.state == .ready
                                      ? TFColors.success : TFColors.textSecondary) {
                            EmptyView()
                        }
                    }
                }
            }
        }
        .accessibilityIdentifier("settings.services.section")
        .onAppear { model.startObserving() }
        .onDisappear { model.stopObserving() }
    }
}
