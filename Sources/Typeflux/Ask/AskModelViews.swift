import SwiftUI

struct AskModelMenu: View {
    @ObservedObject var library: AskModelLibrary
    @Binding var reference: String
    var disabled = false
    var showsDefaultAction = true
    var hasImage = false
    var fieldStyle = false
    @ObservedObject private var auth = AuthState.shared
    @State private var expanded = false

    private var currentReason: String? {
        guard let (provider, model) = library.registry.resolve(reference) else { return L("ask.models.unavailable") }
        return library.selectionReason(model, provider: provider, hasImage: hasImage, loggedIn: auth.isLoggedIn)
    }

    var body: some View {
        Button { expanded.toggle() } label: {
            HStack(spacing: 8) {
                ModelProviderIcon(provider: library.registry.resolve(reference)?.0.studioProviderID ?? .customLLM,
                                  size: 18)
                Text(library.name(for: reference)).lineLimit(1).truncationMode(.middle)
                if fieldStyle {
                    Spacer(minLength: 4)
                }
                if currentReason != nil {
                    Image(systemName: "exclamationmark.circle")
                }
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .medium))
                    .foregroundStyle(StudioTheme.textSecondary)
            }
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 11).frame(width: fieldStyle ? 240 : nil, height: 32)
            .background(ModelVisualStyle.input, in: RoundedRectangle(cornerRadius: fieldStyle ? 8 : 16))
            .overlay(RoundedRectangle(cornerRadius: fieldStyle ? 8 : 16).strokeBorder(ModelVisualStyle.border))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(disabled)
        .help(currentReason ?? L("ask.models.conversationOnly"))
        .popover(isPresented: $expanded, arrowEdge: .bottom) {
            AskModelChoices(library: library, reference: $reference, showsDefaultAction: showsDefaultAction,
                            hasImage: hasImage, loggedIn: auth.isLoggedIn) { expanded = false }
        }
        .task {
            library.adoptLegacySelectionIfNeeded()
            if library.automaticallyLoadsCatalog {
                await library.refresh(token: auth.accessToken)
                await library.probeOllama()
            }
        }
    }
}

struct AskModelChoices: View {
    @ObservedObject var library: AskModelLibrary
    @Binding var reference: String
    var showsDefaultAction = true
    var hasImage = false
    var loggedIn: Bool
    var dismiss: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    if library.registry.resolve(reference) == nil {
                        Text(L("ask.models.unavailable")).font(.caption).foregroundStyle(.secondary).padding(10)
                    }
                    ForEach(library.sortedProviders(loggedIn: loggedIn).filter { !$0.models.isEmpty }) { provider in
                        Text(provider.name).font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(StudioTheme.textSecondary)
                            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 2)
                        ForEach(provider.models) { model in
                            choice(model, provider: provider)
                        }
                    }
                }.padding(8)
            }.frame(maxHeight: 320)
            if showsDefaultAction {
                Divider()
                Button {
                    library.defaultReference = reference
                    dismiss()
                } label: {
                    Label(L("ask.models.makeDefault"), systemImage: "gearshape")
                        .font(.system(size: 13)).frame(maxWidth: .infinity, alignment: .leading).padding(16)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(library.registry.resolve(reference) == nil)
            }
        }.frame(width: 360).background(ModelVisualStyle.input)
    }

    private func choice(_ model: RegisteredModel, provider: RegisteredProvider) -> some View {
        let reason = library.selectionReason(model, provider: provider, hasImage: hasImage, loggedIn: loggedIn)
        let selected = reference == model.reference
        return Button { reference = model.reference; dismiss() } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.name).font(.system(
                        size: 13,
                        weight: selected ? .semibold : .regular,
                        design: .monospaced
                    ))
                    if let reason {
                        Text(reason).font(.system(size: 11)).foregroundStyle(StudioTheme.textSecondary)
                    }
                }
                Spacer(minLength: 8)
                if selected {
                    Image(systemName: "checkmark").font(.system(size: 12, weight: .semibold))
                }
            }
            .foregroundStyle(selected ? ModelVisualStyle.accent : StudioTheme.textPrimary)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? ModelVisualStyle.accent.opacity(0.15) : .clear,
                        in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
            .opacity(reason == nil ? 1 : 0.5)
        }.buttonStyle(.plain).disabled(reason != nil)
    }
}
