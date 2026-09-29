import SwiftUI

struct AskModelMenu: View {
    @ObservedObject var library: AskModelLibrary
    @Binding var reference: String
    var disabled = false
    var showsDefaultAction = true
    var hasImage = false
    @ObservedObject private var auth = AuthState.shared

    private var currentReason: String? {
        guard let (provider, model) = library.registry.resolve(reference) else { return L("ask.models.unavailable") }
        return library.selectionReason(model, provider: provider, hasImage: hasImage, loggedIn: auth.isLoggedIn)
    }

    var body: some View {
        Menu {
            if library.registry.resolve(reference) == nil {
                Text(L("ask.models.unavailable"))
                Divider()
            }
            ForEach(library.sortedProviders(loggedIn: auth.isLoggedIn).filter { !$0.models.isEmpty }) { provider in
                Section(provider.name) {
                    ForEach(provider.models) { model in
                        let reason = library.selectionReason(
                            model,
                            provider: provider,
                            hasImage: hasImage,
                            loggedIn: auth.isLoggedIn
                        )
                        Button { reference = model.reference } label: {
                            let title = model.name + (reason.map { " — " + $0 } ?? "")
                            if reference == model.reference {
                                Label(title, systemImage: "checkmark")
                            } else {
                                Text(title)
                            }
                        }.disabled(reason != nil)
                    }
                }
            }
            if showsDefaultAction {
                Divider()
                Button(L("ask.models.makeDefault")) { library.defaultReference = reference }
                    .disabled(library.registry.resolve(reference) == nil)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: reference.hasPrefix("cloud:") ? "cloud" : "server.rack")
                if currentReason != nil { Image(systemName: "exclamationmark.circle") }
                Text(library.name(for: reference)).lineLimit(1).truncationMode(.middle)
                Image(systemName: "chevron.down").font(.system(size: 9))
            }.font(.system(size: 12, weight: .medium)).frame(maxWidth: 260)
        }
        .menuStyle(.borderlessButton)
        .disabled(disabled)
        .help(currentReason ?? L("ask.models.conversationOnly"))
        .task {
            library.adoptLegacySelectionIfNeeded()
            if library.automaticallyLoadsCatalog {
                await library.refresh(token: auth.accessToken)
                await library.probeOllama()
            }
        }
    }
}
