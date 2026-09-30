import SwiftUI

/// Cloud membership and capabilities are owned by the server, not local provider settings.
struct CloudProviderModelsView: View {
    @ObservedObject var library: AskModelLibrary
    var onBack: (() -> Void)?
    @ObservedObject private var auth = AuthState.shared

    private var models: [RegisteredModel] {
        library.providers.first(where: \.isCloud)?.models ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                if let onBack {
                    Button(action: onBack) {
                        Label("Typeflux Cloud", systemImage: "chevron.left")
                            .font(.system(size: 23, weight: .bold))
                    }.buttonStyle(.plain).accessibilityLabel(L("models.back"))
                } else {
                    Text("Typeflux Cloud").font(.system(size: 23, weight: .bold))
                }
                Spacer()
            }
            Text(L("models.cloud.managed")).foregroundStyle(StudioTheme.textSecondary)
            ModelSurface {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text(L("models.cloud.available")).font(.system(size: 13, weight: .semibold))
                        Text("\(models.count)").foregroundStyle(StudioTheme.textSecondary)
                        Spacer()
                        if library.loading { ProgressView().controlSize(.small) }
                        Button(L("models.cloud.refresh")) {
                            Task { await library.refresh(token: auth.accessToken) }
                        }.disabled(library.loading || auth.accessToken == nil)
                    }.padding(18)
                    ForEach(models) { model in
                        Divider()
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(model.id == "default" && model.pricing != nil
                                     ? L("models.cloud.systemDefault") + " · " + model.displayName : model.displayName)
                                    .font(.system(size: 14, weight: .medium))
                                if let context = model.contextWindowTokens, let output = model.maxOutputTokens {
                                    Text(String(format: L("models.cloud.parameters"), context, output))
                                        .font(.caption).foregroundStyle(StudioTheme.textSecondary)
                                }
                                if model.vision == true {
                                    Text(L("models.visionYes")).font(.caption).foregroundStyle(StudioTheme.textSecondary)
                                }
                            }
                            Spacer()
                            if library.defaultReference == model.reference {
                                ModelUsageBadge(text: L("models.askDefault"))
                            } else {
                                Button(L("ask.models.makeDefault")) { library.defaultReference = model.reference }
                                    .disabled(model.exclusionReason != nil || model.scenarios?.contains("ask") == false)
                            }
                        }.padding(18)
                    }
                    if models.isEmpty && !library.loading {
                        Text(L("models.cloud.empty")).foregroundStyle(StudioTheme.textSecondary).padding(18)
                    }
                }
            }
            if auth.accessToken == nil {
                Text(L("models.login")).foregroundStyle(StudioTheme.textSecondary)
            }
            if let error = library.catalogError {
                Text(error).foregroundStyle(.red).font(.callout)
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
}
