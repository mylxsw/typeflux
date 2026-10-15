import AppKit
import SwiftUI

/// What the storage card reports about a composer's conversation.
struct AskLocalModeStatus: Equatable {
    /// Where the conversation's model runs, e.g. "Ollama".
    var source: String
    var searchConfigured: Bool
    /// Signed out: the card offers Typeflux Cloud.
    var offersSignIn: Bool
    /// The conversation is kept on this Mac rather than in Typeflux Cloud.
    var local = true
    /// The conversation has not started, so where it is kept can still change.
    var changeable = false
    var modelAvailable = true
    var modelReason: String? = nil
    /// The conversation is temporary: in no history list and gone once left.
    var temporary = false
    /// The kinds the card offers while `changeable`; Cloud needs a session.
    var choices: [AskStorageKind] = []

    var kind: AskStorageKind { temporary ? .temporary : local ? .local : .cloud }

    /// `offersChoice` is false where the card only describes the session, as in the sidebar.
    @MainActor
    static func make(model: AskConversationModel, signedIn: Bool, launcher: Bool = false,
                     offersChoice: Bool = true) -> Self {
        let library = model.modelLibrary
        let reference = model.modelReference(launcher: launcher)
        let provider = library.registry.resolve(reference)?.0
        let reason = model.modelSelectionIssue(reference, cloudAvailable: model.cloudAvailable(launcher: launcher),
                                               hasImage: model.requiresVision(launcher: launcher))?.text
        let changeable = offersChoice && model.canChooseStorage(launcher: launcher)
        let temporary = offersChoice && model.isTemporaryComposer(launcher: launcher)
        return .init(source: provider.map(sourceName) ?? L("ask.local.sourceNone"),
                     searchConfigured: AskSearchSettings(defaults: library.settings.defaults).provider != .none,
                     offersSignIn: !signedIn,
                     local: model.storesLocally(launcher: launcher),
                     changeable: changeable,
                     modelAvailable: reason == nil, modelReason: reason,
                     temporary: temporary,
                     choices: changeable ? (signedIn ? [.cloud, .local, .temporary] : [.local, .temporary]) : [])
    }

    static func sourceName(_ provider: RegisteredProvider) -> String {
        provider.isOllama ? "Ollama" : provider.name
    }

    /// The card's lead sentence: why it is kept here, or what the choice means.
    var summaryKey: String {
        if temporary, !changeable { return "ask.storage.card.lockedTemporary" }
        if offersSignIn { return "ask.local.card.body" }
        if changeable { return "ask.storage.card.choose" }
        return local ? "ask.storage.card.lockedLocal" : "ask.storage.card.lockedCloud"
    }
}

/// The sidebar's filter while conversations are kept both in Typeflux Cloud and on this Mac.
enum AskHistoryFilter: String, CaseIterable {
    case all, cloud, local

    var titleKey: String { "ask.history.filter." + rawValue }

    var symbol: String? {
        switch self {
        case .all: nil
        case .cloud: "cloud"
        case .local: "lock"
        }
    }

    func apply(_ items: [AskConversationSummary], isLocal: (String) -> Bool) -> [AskConversationSummary] {
        switch self {
        case .all: items
        case .cloud: items.filter { !isLocal($0.id) }
        case .local: items.filter { isLocal($0.id) }
        }
    }
}

/// The sidebar's filter as one full-width segmented bar: a translucent well with the
/// chosen segment raised, so it reads as part of the glass panel.
struct AskHistoryFilterBar: View {
    @Binding var selection: AskHistoryFilter
    static let height: CGFloat = 28
    @Environment(\.interfaceStyle) private var style

    var body: some View {
        HStack(spacing: 2) {
            ForEach(AskHistoryFilter.allCases, id: \.self) { filter in
                let chosen = selection == filter
                Button { selection = filter } label: {
                    HStack(spacing: 4) {
                        if let symbol = filter.symbol {
                            Image(systemName: symbol).font(.system(size: 10.5, weight: .medium))
                        }
                        Text(L(filter.titleKey)).font(.system(size: 12, weight: chosen ? .semibold : .regular))
                    }
                    .foregroundStyle(chosen ? StudioTheme.textPrimary : StudioTheme.textSecondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: Self.height - 4)
                    .background {
                        if chosen {
                            RoundedRectangle(cornerRadius: style.ask.filterCorner - 2, style: .continuous)
                                .fill(style.usesGlass ? AskTheme.controlSurface : AskClassic.card)
                                .shadow(color: .black.opacity(0.18), radius: 1.5, y: 1)
                        }
                    }
                    .contentShape(RoundedRectangle(cornerRadius: style.ask.filterCorner - 2, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(chosen ? .isSelected : [])
            }
        }
        .padding(2)
        .frame(height: Self.height)
        .background(AskTheme.hoverFill, in: RoundedRectangle(cornerRadius: style.ask.filterCorner, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("ask.history.filter"))
    }
}

/// The card behind the composer's storage icon: where the conversation is kept,
/// the choice while it has not started, what works here, and the way to the other kind.
struct AskLocalModeCard: View {
    static let width: CGFloat = 330

    let status: AskLocalModeStatus
    var onOpenSearchSettings: () -> Void
    var onSignIn: () -> Void
    var onOpenModelSettings: () -> Void = {}
    /// Picks where the new conversation is kept.
    var onChoose: (AskStorageKind) -> Void = { _ in }
    /// Starts a conversation of the other kind, for one that already started.
    var onStartOther: () -> Void = {}
    /// Keeps the temporary conversation as an ordinary one.
    var onKeep: () -> Void = {}
    /// Ends the temporary conversation.
    var onEnd: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                Label(L(status.kind.titleKey), systemImage: status.kind.symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(StudioTheme.textPrimary)
                Text(L(status.summaryKey))
                    .font(.system(size: 11.5))
                    .foregroundStyle(StudioTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if status.changeable {
                VStack(spacing: 4) {
                    ForEach(status.choices, id: \.self) { option($0) }
                }
            }
            Rectangle().fill(AskTheme.separator).frame(height: 0.5)
            switch status.kind {
            case .temporary: temporaryDetails
            case .local: localDetails
            case .cloud: cloudDetails
            }
            if status.offersSignIn {
                Rectangle().fill(AskTheme.separator).frame(height: 0.5)
                HStack(spacing: 8) {
                    Text(L("ask.local.card.cloudQuestion")).font(.system(size: 11.5))
                        .foregroundStyle(StudioTheme.textSecondary)
                    Spacer(minLength: 6)
                    Button(L("account.card.signIn"), action: onSignIn)
                        .buttonStyle(AskCapsuleButtonStyle(kind: .primary))
                }
            }
            if status.temporary, !status.changeable {
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    Button(L("ask.temporary.keep"), action: onKeep)
                        .buttonStyle(AskCapsuleButtonStyle(kind: .secondary))
                    Button(L("ask.temporary.end"), action: onEnd)
                        .buttonStyle(AskCapsuleButtonStyle(kind: .secondary))
                }
            } else if !status.changeable, !status.offersSignIn {
                HStack {
                    Spacer(minLength: 0)
                    Button(L(status.local ? "ask.storage.newCloud" : "ask.storage.newLocal"), action: onStartOther)
                        .buttonStyle(AskCapsuleButtonStyle(kind: .secondary))
                }
            }
        }
        .padding(14)
        .frame(width: Self.width, alignment: .leading)
    }

    @ViewBuilder private var localDetails: some View {
        VStack(spacing: 6) {
            row(L("ask.local.card.source"), status.source, available: status.modelAvailable)
            row(L("ask.local.card.readPages"), L("ask.local.card.available"))
        }
        if let reason = status.modelReason {
            Text(reason).font(.system(size: 11)).foregroundStyle(StudioTheme.warning)
                .fixedSize(horizontal: false, vertical: true)
            Button(L("ask.submission.models"), action: onOpenModelSettings)
                .buttonStyle(AskCapsuleButtonStyle(kind: .secondary))
        }
        if !status.searchConfigured {
            HStack(spacing: 8) {
                Image(systemName: "info.circle").font(.system(size: 13)).foregroundStyle(StudioTheme.warning)
                VStack(alignment: .leading, spacing: 1) {
                    Text(L("ask.local.card.noSearch")).font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(StudioTheme.textPrimary)
                    Text(L("ask.local.card.noSearchHint")).font(.system(size: 11))
                        .foregroundStyle(StudioTheme.textSecondary)
                }
                Spacer(minLength: 6)
                Button(L("ask.local.card.configure"), action: onOpenSearchSettings)
                    .buttonStyle(AskCapsuleButtonStyle(kind: .secondary))
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(StudioTheme.warning.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        note(L("ask.storage.card.localNote"))
    }

    private var cloudDetails: some View {
        note(L("ask.storage.card.cloudNote"))
    }

    /// What a temporary conversation leaves behind: nothing in history or memory,
    /// and a Cloud model's run kept on the server for at most a day.
    private var temporaryDetails: some View {
        VStack(alignment: .leading, spacing: 6) {
            fact("clock.arrow.circlepath", L("ask.temporary.fact.history"))
            fact("brain", L("ask.temporary.fact.memory"))
            fact("xmark.bin", L("ask.temporary.fact.end"))
            if !status.offersSignIn { note(L("ask.temporary.fact.cloud")) }
        }
    }

    private func fact(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(AskTheme.temporaryTint)
                .frame(width: 14)
            Text(text).font(.system(size: 12)).foregroundStyle(StudioTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(StudioTheme.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    static func tint(_ kind: AskStorageKind) -> Color {
        switch kind {
        case .cloud: AskTheme.accent
        case .local: AskTheme.privateTint
        case .temporary: AskTheme.temporaryTint
        }
    }

    private func option(_ kind: AskStorageKind) -> some View {
        let chosen = status.kind == kind
        let tint = Self.tint(kind)
        return Button { onChoose(kind) } label: {
            HStack(spacing: 10) {
                Image(systemName: kind.symbol)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(tint)
                    .frame(width: 26, height: 26)
                    .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(L(kind.titleKey))
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(StudioTheme.textPrimary)
                    Text(L(kind.detailKey))
                        .font(.system(size: 11))
                        .foregroundStyle(StudioTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 6)
                if chosen {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(tint)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 7)
            .background(chosen ? tint.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(chosen ? tint.opacity(0.5) : .clear,
                              style: StrokeStyle(lineWidth: 1, dash: kind == .temporary ? AskTheme.temporaryDash : [])))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }

    private func row(_ label: String, _ value: String, available: Bool = true) -> some View {
        HStack(spacing: 8) {
            Text(label).foregroundStyle(StudioTheme.textSecondary).frame(width: 64, alignment: .leading)
            Text(value).foregroundStyle(StudioTheme.textPrimary).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 6)
            Circle().fill(available ? StudioTheme.success : StudioTheme.warning).frame(width: 6, height: 6)
                .accessibilityLabel(L(available ? "ask.local.card.available" : "ask.models.unavailable"))
        }
        .font(.system(size: 12))
    }
}

/// Opens the storage card from any anchor and runs its actions.
private struct AskLocalModeMenu: ViewModifier {
    @Binding var isPresented: Bool
    let status: AskLocalModeStatus
    let model: AskConversationModel
    var launcher = false

    func body(content: Content) -> some View {
        content.askMenu(isPresented: $isPresented, glass: true) {
            AskLocalModeCard(status: status, onOpenSearchSettings: {
                isPresented = false
                model.onOpenSettings?(.agent)
            }, onSignIn: {
                isPresented = false
                model.onSignIn()
            }, onOpenModelSettings: {
                isPresented = false
                model.onOpenSettings?(.models)
            }, onChoose: { kind in
                isPresented = false
                model.chooseStorage(kind, launcher: launcher)
            }, onStartOther: {
                isPresented = false
                model.newConversation(storesLocally: !status.local)
            }, onKeep: {
                isPresented = false
                model.keepTemporaryConversation()
            }, onEnd: {
                isPresented = false
                model.endTemporaryConversation()
            })
        }
    }
}

/// The composer's storage icon: a cloud, or a lock for a conversation kept on this
/// Mac. It carries no text so it stays quiet; hovering names it, a click explains it.
struct AskStorageButton: View {
    @ObservedObject var model: AskConversationModel
    var launcher = false
    @ObservedObject var auth: AuthState = .shared
    @State private var presented = false
    @State private var hovering = false

    static let size: CGFloat = 26

    var body: some View {
        let kind = model.storageKind(launcher: launcher)
        let name = L(kind.titleKey)
        let active = hovering || presented
        Button { presented.toggle() } label: {
            Image(systemName: kind.symbol)
                .font(.system(size: 12.5, weight: kind != .cloud || active ? .semibold : .medium))
                .foregroundStyle(Self.iconColor(kind, active: active))
                .frame(width: Self.size, height: Self.size)
                .background(Self.wellFill(kind, active: active),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(name + " · " + L("ask.storage.help"))
        .accessibilityLabel(name)
        .accessibilityHint(L("ask.storage.help"))
        .modifier(AskLocalModeMenu(isPresented: $presented,
                                   status: .make(model: model, signedIn: model.isSignedIn, launcher: launcher),
                                   model: model, launcher: launcher))
    }

    /// The private tint marks this Mac and teal a temporary conversation; hover or an
    /// open menu brightens the cloud.
    static func iconColor(_ kind: AskStorageKind, active: Bool) -> Color {
        switch kind {
        case .local: AskTheme.privateTint
        case .temporary: AskTheme.temporaryTint
        case .cloud: active ? StudioTheme.textPrimary : StudioTheme.textSecondary
        }
    }

    /// Kept on this Mac and temporary are states, so they sit in a tinted well like an
    /// on switch; the cloud only gets the hover wash.
    static func wellFill(_ kind: AskStorageKind, active: Bool) -> Color {
        switch kind {
        case .local: AskTheme.privateFill
        case .temporary: AskTheme.temporaryFill
        case .cloud: active ? AskTheme.hoverFill : .clear
        }
    }

    static func iconColor(local: Bool, active: Bool) -> Color { iconColor(local ? .local : .cloud, active: active) }
    static func wellFill(local: Bool, active: Bool) -> Color { wellFill(local ? .local : .cloud, active: active) }
}

/// The sidebar footer while signed out: where Ask runs, instead of a lone sign-in link.
struct AskLocalModeIdentity: View {
    @ObservedObject var model: AskConversationModel
    @State private var presented = false

    /// "Ollama · Stays on this Mac": the model's source and where chats are kept.
    static func detail(source: String) -> String {
        String(format: L("ask.local.identity.detail"), source)
    }

    var body: some View {
        let status = AskLocalModeStatus.make(model: model, signedIn: false, offersChoice: false)
        AskSignedOutIdentity(active: presented, detail: Self.detail(source: status.source)) {
            presented.toggle()
        }
        .modifier(AskLocalModeMenu(isPresented: $presented, status: status, model: model))
        .accessibilityLabel(L("ask.local.identity"))
        .accessibilityValue(Self.detail(source: status.source))
        .accessibilityHint(L("ask.location.local.help"))
    }
}
