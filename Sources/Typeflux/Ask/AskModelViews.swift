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
    /// Narrow workspace cards reserve room for send and voice controls.
    var condensed = false
    /// Composer footers hide the chevron; settings retain their field indicator.
    var showsChevron = true
    /// Whether Cloud models can run here; Ask passes false in local mode. Defaults to the sign-in state.
    var cloudAvailable: Bool? = nil
    /// Composer only: a "Manage models…" row that opens settings.
    var onManage: (() -> Void)?
    /// Composer only: the reasoning level, shown after the model name and chosen on the
    /// chip's card. Settings choose a model alone.
    var effort: Binding<AskReasoningEffort>? = nil
    @ObservedObject private var auth = AuthState.shared
    @State private var expanded = false
    @State private var hovering = false

    private var loggedIn: Bool { cloudAvailable ?? auth.isLoggedIn }

    private var effortLevels: [AskReasoningEffort] {
        AskReasoningEffort.levels(for: library.registry.resolve(reference)?.1)
    }

    /// The level shown after the model name: nothing for "Auto" or a model without levels.
    private var shownEffort: AskReasoningEffort? {
        guard let effort else { return nil }
        let shown = effort.wrappedValue.nearest(in: effortLevels)
        return shown == .providerDefault ? nil : shown
    }

    private var currentReason: String? {
        guard let (provider, model) = library.registry.resolve(reference) else { return L("ask.models.unavailable") }
        return library.selectionReason(model, provider: provider, hasImage: hasImage, loggedIn: loggedIn, scenario: scenario)
    }

    private var corner: CGFloat {
        compact ? AskMetrics.composerControlHeight / 2 : (fieldStyle ? ModelVisualStyle.controlCornerRadius : 16)
    }
    private var fill: Color {
        guard compact else { return fieldStyle ? ModelVisualStyle.control : ModelVisualStyle.input }
        return hovering || expanded ? AskTheme.hoverFill : .clear
    }
    private var stroke: Color { compact ? .clear : ModelVisualStyle.border }

    var body: some View {
        Button { expanded.toggle() } label: {
            HStack(spacing: compact ? 6 : 8) {
                // Settings shows the provider logo so same-named models stay distinguishable.
                if fieldStyle, let provider = library.registry.resolve(reference)?.0 {
                    ModelProviderIcon(provider: provider.studioProviderID, size: 16)
                }
                // A long model name must not squeeze the context chips out of the
                // footer, and a short one hugs its text instead of padding out to the cap.
                AskCappedWidth(maxWidth: condensed ? 84 : compact ? AskMetrics.modelMenuMaxWidth : .infinity) {
                    Text(library.name(for: reference, scenario: scenario)).lineLimit(1).truncationMode(.middle)
                }
                if let shownEffort, !condensed {
                    Text(shownEffort.label)
                        .font(.system(size: 13.5, weight: .regular))
                        .foregroundStyle(shownEffort.isTop(in: effortLevels)
                                         ? AskTheme.reasoningTopText : StudioTheme.textSecondary)
                        .lineLimit(1).fixedSize()
                }
                if fieldStyle {
                    Spacer(minLength: 4)
                }
                if currentReason != nil {
                    Image(systemName: "exclamationmark.circle")
                }
                if showsChevron {
                    Image(systemName: fieldStyle ? "chevron.up.chevron.down" : "chevron.down")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(StudioTheme.textSecondary)
                }
            }
            .font(.system(size: compact ? 13.5 : 13,
                          weight: fieldStyle ? .regular : (compact ? .semibold : .medium)))
            .padding(.leading, compact ? 12 : (fieldStyle ? 10 : 11))
            .padding(.trailing, compact ? 10 : (fieldStyle ? 10 : 11))
            .frame(width: fieldStyle ? 240 : nil,
                   height: compact ? AskMetrics.composerControlHeight : (fieldStyle ? 30 : 32))
            .background(fill, in: RoundedRectangle(cornerRadius: corner, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: corner, style: .continuous).strokeBorder(stroke))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(disabled)
        .onHover { hovering = $0 }
        .help(currentReason ?? L("ask.models.conversationOnly"))
        .askMenu(isPresented: $expanded, glass: compact) {
            if let effort, compact {
                AskModelEffortCard(library: library, reference: $reference, effort: effort, hasImage: hasImage,
                                   loggedIn: loggedIn, onManage: onManage,
                                   offersCloudSignIn: scenario == "ask" && !auth.isLoggedIn,
                                   close: { expanded = false })
            } else {
                AskModelChoices(library: library, reference: $reference, scenario: scenario, showsDefaultAction: showsDefaultAction,
                                hasImage: hasImage, loggedIn: loggedIn, dismiss: { expanded = false },
                                composerStyle: compact, onManage: onManage,
                                offersCloudSignIn: compact && scenario == "ask" && !auth.isLoggedIn)
            }
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

/// Proposes at most `maxWidth` to its content and takes the content's own size,
/// so text shorter than the cap stays tight. `.frame(maxWidth:)` would instead
/// grow to the cap whenever the parent offers more room.
struct AskCappedWidth: Layout {
    var maxWidth: CGFloat

    init(maxWidth: CGFloat) { self.maxWidth = maxWidth }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        return content.sizeThatFits(capped(proposal))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }

    func capped(_ proposal: ProposedViewSize) -> ProposedViewSize {
        // An unspecified width asks for the ideal size; keep it unless a cap applies.
        let width = proposal.width.map { min($0, maxWidth) } ?? (maxWidth.isFinite ? maxWidth : nil)
        return ProposedViewSize(width: width, height: proposal.height)
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
    /// The composer's chooser follows the Ask design board. Settings and the
    /// image-recovery picker keep the field styling validated in design-qa.md.
    var composerStyle = false
    /// Opens model settings from the chooser's footer.
    var onManage: (() -> Void)?
    /// Signed out: a locked Typeflux Cloud row says what signing in adds.
    var offersCloudSignIn = false

    var body: some View {
        if composerStyle { composerBody } else { standardBody }
    }

    private var standardBody: some View {
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

    private var composerBody: some View {
        // Every model the user can use is listed; those that cannot read this
        // conversation's images stay visible, dimmed with the reason, instead of
        // silently disappearing (custom models rarely declare vision support).
        let choices = library.selectableProviders(loggedIn: loggedIn, hasImage: false, scenario: scenario)
        let compatible = library.selectableProviders(loggedIn: loggedIn, hasImage: hasImage, scenario: scenario)
        let selectionAvailable = compatible.contains { $0.models.contains { $0.reference == reference } }
        return VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if choices.isEmpty {
                        Text(L("models.noAvailable")).font(.system(size: 12))
                            .foregroundStyle(StudioTheme.textTertiary).padding(14)
                    } else if showsUnavailableSelection && !selectionAvailable {
                        Text(L("ask.models.unavailable")).font(.system(size: 12))
                            .foregroundStyle(StudioTheme.textTertiary)
                            .padding(.horizontal, 14).padding(.top, 12)
                    } else if hasImage, compatible.flatMap(\.models).count < choices.flatMap(\.models).count {
                        Label(L("ask.models.imageOnly"), systemImage: "info.circle").font(.system(size: 11.5))
                            .foregroundStyle(StudioTheme.textSecondary)
                            .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 2)
                    }
                    ForEach(Array(choices.enumerated()), id: \.element.id) { index, provider in
                        if index > 0 { AskPopoverDivider() }
                        AskPopoverHeader(title: Self.groupTitle(provider),
                                         trailing: index == 0 && provider.isCloud
                                             ? L("ask.models.multiplierColumn") : nil)
                        ForEach(provider.models) { model in
                            let blocked = Self.imageReason(model, provider: provider, hasImage: hasImage,
                                                           library: library, loggedIn: loggedIn, scenario: scenario)
                            AskPopoverRow(title: model.name,
                                          note: model.reference == library.defaultReference ? L("ask.models.isDefault") : nil,
                                          caption: blocked ?? Self.imageTrialCaption(model, provider: provider, hasImage: hasImage)
                                              ?? Self.caption(model),
                                          selected: reference == model.reference,
                                          enabled: blocked == nil) {
                                reference = model.reference; dismiss()
                            } accessory: {
                                AskModelCapabilities(model: model)
                                if let multiplier = model.pricing?.multiplier,
                                   let text = AskMultiplierBadge.text(multiplier) {
                                    Text(text).font(.system(size: 11)).monospacedDigit()
                                } else if let tag = Self.sourceTag(provider) {
                                    Text(tag).font(.system(size: 11))
                                }
                            }
                            .help(model.displayName + " — " + (model.pricing == nil
                                ? L("models.cloud.priceUnknown") : L("models.cloud.priceExplanation")))
                        }
                    }
                    if offersCloudSignIn {
                        if !choices.isEmpty { AskPopoverDivider() }
                        AskPopoverHeader(title: "Typeflux Cloud")
                        AskPopoverRow(title: L("ask.models.cloudLocked.title"), caption: L("ask.models.cloudLocked.caption"),
                                      selected: false) {
                            dismiss(); LoginWindowController.shared.show()
                        } accessory: {
                            Text(L("ask.cloudPromo.signIn")).font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(Color.white)
                                .padding(.horizontal, 10).frame(height: 22)
                                .background(Capsule().fill(AskTheme.accent))
                        }
                    }
                }
                .padding(.vertical, 6)
            }
            // Tall enough for a typical catalog without scrolling; longer lists scroll.
            .frame(maxHeight: Self.composerListMaxHeight)
            .fixedSize(horizontal: false, vertical: true)
            AskPopoverDivider()
            VStack(spacing: 0) {
                if Self.offersMakeDefault(showsDefaultAction: showsDefaultAction,
                                          selectionAvailable: selectionAvailable,
                                          reference: reference, defaultReference: library.defaultReference) {
                    AskPopoverRow(title: L("ask.models.makeDefault"), caption: nil, selected: false) {
                        library.defaultReference = reference
                        dismiss()
                    }
                }
                if let onManage {
                    AskPopoverRow(title: L("ask.models.manage") + "…", caption: nil, selected: false) {
                        dismiss(); onManage()
                    } accessory: {
                        Text(verbatim: "⌘,").font(.system(size: 11))
                    }
                }
            }
            .padding(.bottom, 6)
        }
        .frame(width: 330)
    }

    static let composerListMaxHeight: CGFloat = 460

    /// Each source is its own group; models on this Mac say so.
    static func groupTitle(_ provider: RegisteredProvider) -> String {
        provider.isOllama ? L("ask.models.localGroup") : provider.name
    }

    /// The trailing word on a row without a Cloud multiplier: where it runs.
    static func sourceTag(_ provider: RegisteredProvider) -> String? {
        if provider.isCloud { return nil }
        return provider.isOllama ? L("ask.location.local") : L("ask.models.ownAPI")
    }

    /// With images, a model of unknown vision support can be picked and is tried once; the row says so.
    static func imageTrialCaption(_ model: RegisteredModel, provider: RegisteredProvider, hasImage: Bool) -> String? {
        hasImage && !provider.isCloud && model.effectiveVision == nil ? L("ask.models.visionTrial") : nil
    }

    /// Why a listed model cannot be picked for this conversation, if it cannot.
    static func imageReason(_ model: RegisteredModel, provider: RegisteredProvider, hasImage: Bool,
                            library: AskModelLibrary, loggedIn: Bool, scenario: String) -> String? {
        guard hasImage else { return nil }
        return library.selectionReason(model, provider: provider, hasImage: true, loggedIn: loggedIn, scenario: scenario)
    }

    /// The footer only offers what it can do: nothing when the selection already
    /// is the default, instead of a greyed-out link.
    static func offersMakeDefault(showsDefaultAction: Bool, selectionAvailable: Bool,
                                  reference: String, defaultReference: String) -> Bool {
        showsDefaultAction && selectionAvailable && reference != defaultReference
    }

    /// "205K context · 16.4K output": compact numbers instead of raw token counts.
    static func caption(_ model: RegisteredModel) -> String? {
        guard let context = model.contextWindowTokens, let output = model.maxOutputTokens else { return nil }
        return String(format: L("ask.models.capacity"),
                      AccountUsageDisplayFormatter.count(Int64(context)),
                      AccountUsageDisplayFormatter.count(Int64(output)))
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

/// Outlined capability words in a model row. Only vision is marked: it decides
/// whether a conversation with images can use the model. Reasoning is not, since
/// nearly every model reasons and the composer's reasoning menu covers it.
struct AskModelCapabilities: View {
    let model: RegisteredModel

    static func badges(_ model: RegisteredModel) -> [(text: String, help: String)] {
        model.effectiveVision == true ? [(L("ask.models.badge.vision"), L("ask.models.supportsImages"))] : []
    }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Self.badges(model), id: \.text) { item in
                Text(item.text)
                    .font(.system(size: 10))
                    .padding(.horizontal, 6)
                    .frame(height: 16)
                    .overlay(Capsule().strokeBorder(lineWidth: 0.5))
                    .opacity(0.85)
                    .help(item.help)
                    .accessibilityLabel(item.help)
            }
        }
    }
}
