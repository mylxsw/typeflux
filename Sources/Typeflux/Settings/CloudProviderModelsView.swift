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
        VStack(alignment: .leading, spacing: 0) {
            ModelDetailHeader(
                title: "Typeflux Cloud",
                subtitle: L("settings.models.domain.llm"),
                icon: .typefluxCloud,
                connected: auth.isLoggedIn,
                onBack: onBack
            )
            .padding(.bottom, 22)
            ModelSurface {
                HStack(alignment: .top, spacing: 14) {
                    ModelIconTile {
                        Image(systemName: "cloud").font(.system(size: 15)).foregroundStyle(StudioTheme.textSecondary)
                    }
                    Text(L(auth.isLoggedIn ? "models.cloud.managed" : "models.login"))
                        .font(.system(size: 13)).foregroundStyle(StudioTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 8)
                }
                .padding(.horizontal, 18).padding(.vertical, 14)
            }
            HStack(spacing: 8) {
                ModelSectionLabel(title: L("models.cloud.available"), detail: "\(models.count)")
                Spacer()
                if library.loading { ProgressView().controlSize(.small) }
                Button {
                    Task { await library.refresh(token: auth.accessToken) }
                } label: {
                    Label(L("models.cloud.refresh"), systemImage: "arrow.clockwise")
                }.disabled(library.loading || auth.accessToken == nil)
            }
            .padding(.top, 26).padding(.bottom, 8)
            ModelSurface {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(models.enumerated()), id: \.element.id) { index, model in
                        if index > 0 {
                            ModelRowDivider()
                        }
                        modelRow(model)
                    }
                    if models.isEmpty && !library.loading {
                        Text(L("models.cloud.empty")).font(.system(size: 13))
                            .foregroundStyle(StudioTheme.textTertiary)
                            .frame(maxWidth: .infinity).padding(.vertical, 24)
                    }
                }
            }
            Text(L("models.cloud.priceExplanation")).font(.system(size: 12)).foregroundStyle(StudioTheme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4).padding(.top, 10)
            if let error = library.catalogError {
                Text(error).foregroundStyle(StudioTheme.danger).font(.system(size: 12)).padding(.top, 8)
            }
        }
        .buttonStyle(ModelActionStyle())
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
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(model.name).font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(StudioTheme.textPrimary)
                    if let label = model.pricing?.label {
                        ModelUsageBadge(text: label)
                    }
                }
                if let context = model.contextWindowTokens, let output = model.maxOutputTokens {
                    Text(String(format: L("models.cloud.parameters"), context, output))
                        .font(.system(size: 11.5)).foregroundStyle(StudioTheme.textTertiary)
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
                Image(systemName: "photo").font(.system(size: 12)).foregroundStyle(StudioTheme.textSecondary)
                    .help(L("models.visionYes"))
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
    }
}
