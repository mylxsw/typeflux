import SwiftUI

/// Cloud membership and capabilities are owned by the server, not local provider settings.
struct CloudProviderModelsView: View {
    @ObservedObject var library: AskModelLibrary
    var onBack: (() -> Void)?
    @ObservedObject private var auth = AuthState.shared

    private var models: [RegisteredModel] {
        library.providers.first(where: \.isCloud)?.configurationModels ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: TFMetrics.sectionSpacing) {
            ModelDetailHeader(
                title: "Typeflux Cloud",
                icon: .typefluxCloud,
                connected: auth.isLoggedIn,
                onBack: onBack
            )
            TFNotice(text: L(auth.isLoggedIn ? "models.cloud.managed" : "models.login"))
            TFFormSection(title: L("models.cloud.available"), count: models.count,
                          footnote: L("models.cloud.priceExplanation")) {
                if library.loading { TFSpinner() }
                TFButton(title: L("models.cloud.refresh"), systemImage: "arrow.clockwise") {
                    Task { await library.refresh(token: auth.accessToken) }
                }
                .disabled(library.loading || auth.accessToken == nil)
            } content: {
                ForEach(Array(models.enumerated()), id: \.element.id) { index, model in
                    if index > 0 { TFDivider.formWithIcon }
                    modelRow(model)
                }
                if models.isEmpty, !library.loading {
                    TFCardNote(text: L("models.cloud.empty"))
                }
            }
            if let error = library.catalogError {
                TFNotice(text: error, tone: .danger)
            }
        }
        .task(id: auth.accessToken) {
            if library.automaticallyLoadsCatalog { await library.refresh(token: auth.accessToken) }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if library.automaticallyLoadsCatalog {
                Task { await library.refresh(token: auth.accessToken) }
            }
        }
    }

    private func modelRow(_ model: RegisteredModel) -> some View {
        HStack(spacing: 12) {
            TFLogoTile { ModelIcon(model: model, provider: library.providers.first(where: \.isCloud)) }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(model.name).font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(TFColors.textPrimary)
                    if let label = model.pricing?.label {
                        TFTag(text: label)
                    }
                }
                if let context = model.contextWindowTokens, let output = model.maxOutputTokens {
                    Text(String(format: L("models.cloud.parameters"), context, output))
                        .font(.system(size: 11.5)).foregroundStyle(TFColors.textTertiary)
                }
            }
            Spacer(minLength: 8)
            ModelUsageTags(reference: model.reference, library: library)
            if model.vision == true {
                TFTag(text: L("ask.models.badge.vision")).help(L("ask.models.supportsImages"))
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }
}

/// The scenes a model is chosen for ("Rewrite", "Default"), as accent tags.
struct ModelUsageTags: View {
    let reference: String
    @ObservedObject var library: AskModelLibrary

    var body: some View {
        ForEach(ModelSettingsPresentation.usageKeys(reference: reference, rewriteReference: library.rewriteReference,
                                                    defaultReference: library.defaultReference), id: \.self) { key in
            TFTag(text: L(key), tint: TFColors.accent)
        }
    }
}
