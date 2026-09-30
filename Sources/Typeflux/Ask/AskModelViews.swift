import SwiftUI

struct AskModelMenu: View {
    @ObservedObject var library: AskModelLibrary
    @Binding var reference: String
    var disabled = false
    var scenario = "ask"
    var showsDefaultAction = true
    var hasImage = false
    var fieldStyle = false
    /// Composer footer styling: the model is the least frequent control down
    /// there, so it loses its border and only fills under the pointer. Settings
    /// keeps the bordered field it was designed with.
    var compact = false
    @ObservedObject private var auth = AuthState.shared
    @State private var expanded = false
    @State private var hovering = false

    private var currentReason: String? {
        guard let (provider, model) = library.registry.resolve(reference) else { return L("ask.models.unavailable") }
        return library.selectionReason(model, provider: provider, hasImage: hasImage, loggedIn: auth.isLoggedIn, scenario: scenario)
    }

    private var corner: CGFloat { compact ? 8 : (fieldStyle ? 8 : 16) }
    private var fill: Color {
        guard compact else { return ModelVisualStyle.input }
        return hovering || expanded ? AskTheme.controlSurface : .clear
    }
    private var stroke: Color { compact ? .clear : ModelVisualStyle.border }

    var body: some View {
        Button { expanded.toggle() } label: {
            HStack(spacing: compact ? 6 : 8) {
                Text(library.name(for: reference, scenario: scenario)).lineLimit(1).truncationMode(.middle)
                if fieldStyle {
                    Spacer(minLength: 4)
                }
                if currentReason != nil {
                    Image(systemName: "exclamationmark.circle")
                }
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .medium))
                    .foregroundStyle(StudioTheme.textSecondary)
            }
            .font(.system(size: compact ? 12.5 : 13, weight: .medium))
            .padding(.horizontal, compact ? 9 : 11)
            .frame(width: fieldStyle ? 240 : nil, height: compact ? 28 : 32)
            .background(fill, in: RoundedRectangle(cornerRadius: corner, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: corner, style: .continuous).strokeBorder(stroke))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(disabled)
        .onHover { hovering = $0 }
        .help(currentReason ?? L("ask.models.conversationOnly"))
        .popover(isPresented: $expanded, arrowEdge: .bottom) {
            AskModelChoices(library: library, reference: $reference, scenario: scenario, showsDefaultAction: showsDefaultAction,
                            hasImage: hasImage, loggedIn: auth.isLoggedIn) { expanded = false }
        }
        .onChange(of: expanded) { isExpanded in
            if isExpanded && library.automaticallyLoadsCatalog {
                Task { await library.refresh(token: auth.accessToken) }
            }
        }
        .task(id: auth.accessToken) {
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
    var scenario = "ask"
    var showsDefaultAction = true
    var hasImage = false
    var loggedIn: Bool
    var dismiss: () -> Void = {}
    var preferredProviderID: String?
    var showsUnavailableSelection = true
    var recoveryProviders: [RegisteredProvider]?

    var body: some View {
        let available = recoveryProviders ?? library.selectableProviders(loggedIn: loggedIn, hasImage: hasImage, scenario: scenario)
        let choices = available.filter { $0.id == preferredProviderID } + available.filter { $0.id != preferredProviderID }
        let selectionAvailable = choices.contains { $0.models.contains { $0.reference == reference } }
        return VStack(alignment: .leading, spacing: 0) {
            Group {
                if recoveryProviders != nil, choices.reduce(0, { $0 + $1.models.count }) <= 4 {
                    modelList(choices, selectionAvailable: selectionAvailable)
                } else {
                    ScrollView { modelList(choices, selectionAvailable: selectionAvailable) }
                        .frame(height: recoveryProviders == nil ? nil : 280)
                        .frame(maxHeight: 320)
                }
            }
            if showsDefaultAction {
                Divider()
                Button {
                    library.defaultReference = reference
                    dismiss()
                } label: {
                    Label(L("ask.models.makeDefault"), systemImage: "gearshape")
                        .font(.system(size: 13)).frame(maxWidth: .infinity, alignment: .leading).padding(16)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(!selectionAvailable)
            }
        }.frame(width: 360).background(ModelVisualStyle.input)
    }

    private func modelList(_ choices: [RegisteredProvider], selectionAvailable: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if choices.isEmpty {
                Text(L("models.noAvailable")).font(.caption).foregroundStyle(.secondary).padding(10)
            } else if showsUnavailableSelection && !selectionAvailable {
                Text(L("ask.models.unavailable")).font(.caption).foregroundStyle(.secondary).padding(10)
            }
            ForEach(choices) { provider in
                Text(provider.name).font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(StudioTheme.textSecondary)
                    .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 2)
                ForEach(provider.models) { model in
                    choice(model)
                }
            }
        }.padding(8)
    }

    private func choice(_ model: RegisteredModel) -> some View {
        let selected = reference == model.reference
        return Button { reference = model.reference; dismiss() } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(recoveryProviders == nil ? model.displayName : model.name).font(.system(
                        size: 13,
                        weight: selected ? .semibold : .regular,
                        design: .monospaced
                    ))
                    .lineLimit(recoveryProviders == nil ? nil : 2)
                    .truncationMode(.middle)
                    if recoveryProviders == nil, let context = model.contextWindowTokens, let output = model.maxOutputTokens {
                        Text(String(format: L("models.cloud.parameters"), context, output))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                if recoveryProviders != nil, let price = model.pricing?.label {
                    Text(price).font(.system(size: 11, weight: .medium)).fixedSize()
                        .foregroundStyle(StudioTheme.textSecondary)
                        .help(L("models.cloud.priceExplanation"))
                }
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
        }.buttonStyle(.plain)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .help(model.displayName + " — " + (model.pricing == nil ? L("models.cloud.priceUnknown") : L("models.cloud.priceExplanation")))
    }
}
