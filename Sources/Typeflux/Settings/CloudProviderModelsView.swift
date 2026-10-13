import SwiftUI

/// Cloud membership and capabilities are owned by the server, not local provider settings.
struct CloudProviderModelsView: View {
    @ObservedObject var library: AskModelLibrary
    var onBack: (() -> Void)?
    var backTitle: String?
    @ObservedObject private var auth = AuthState.shared

    private var models: [RegisteredModel] {
        library.providers.first(where: \.isCloud)?.configurationModels ?? []
    }

    var body: some View {
        TypefluxForm {
            ModelDetailHeader(
                title: "Typeflux Cloud",
                icon: .typefluxCloud,
                connected: auth.isLoggedIn,
                backTitle: backTitle, onBack: onBack
            )
            .padding(.bottom, 22)
            Section {
                HStack(alignment: .top, spacing: 14) {
                    ModelIconTile {
                        Image(systemName: "cloud").font(.body).foregroundStyle(TypefluxColor.secondaryLabel.color)
                    }
                    Text(L(auth.isLoggedIn ? "models.cloud.managed" : "models.login"))
                        .font(.body).foregroundStyle(TypefluxColor.secondaryLabel.color)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 8)
                }
                .padding(.horizontal, 18).padding(.vertical, 14)
            }
            HStack(spacing: 8) {
                SettingsListSectionLabel(title: L("models.cloud.available"), count: models.count)
                Spacer()
                if library.loading { ProgressView().controlSize(.small) }
                Button {
                    Task { await library.refresh(token: auth.accessToken) }
                } label: {
                    Label(L("models.cloud.refresh"), systemImage: "arrow.clockwise")
                }.disabled(library.loading || auth.accessToken == nil)
            }
            .padding(.top, 26).padding(.bottom, 8)
            List(models) { model in modelRow(model) }
                .listStyle(.inset).frame(height: min(360, CGFloat(models.count) * 56 + 32))
            if models.isEmpty, !library.loading {
                Text(L("models.cloud.empty")).foregroundStyle(.secondary)
            }
            Text(L("models.cloud.priceExplanation")).font(.body).foregroundStyle(TypefluxColor.tertiaryLabel.color)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4).padding(.top, 10)
            if let error = library.catalogError {
                Text(error).foregroundStyle(TypefluxColor.danger.color).font(.body).padding(.top, 8)
            }
        }
        .buttonStyle(.bordered)
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
        HStack(spacing: 10) {
            ModelIcon(model: model, provider: library.providers.first(where: \.isCloud))
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(model.name).font(.body)
                        .foregroundStyle(TypefluxColor.label.color)
                    if let label = model.pricing?.label {
                        ModelUsageBadge(text: label)
                    }
                }
                if let context = model.contextWindowTokens, let output = model.maxOutputTokens {
                    Text(String(format: L("models.cloud.parameters"), context, output))
                        .font(.body).foregroundStyle(TypefluxColor.tertiaryLabel.color)
                }
            }
            Spacer(minLength: 8)
            ForEach(ModelSettingsPresentation.usageKeys(
                reference: model.reference,
                rewriteReference: library.rewriteReference,
                defaultReference: library.defaultReference
            ), id: \.self) { key in
                ModelUsageBadge(text: L(key), accent: true)
            }
            if model.vision == true {
                Text(L("ask.models.badge.vision")).font(.body).foregroundStyle(TypefluxColor.secondaryLabel.color)
                    .lineLimit(1).fixedSize()
                    .help(L("ask.models.supportsImages"))
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
    }
}
