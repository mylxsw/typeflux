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

    @MainActor
    static func make(model: AskConversationModel, signedIn: Bool, launcher: Bool = false) -> Self {
        let library = model.modelLibrary
        let provider = library.registry.resolve(model.modelReference(launcher: launcher))?.0
        return .init(source: provider.map(sourceName) ?? L("ask.local.sourceNone"),
                     searchConfigured: AskSearchSettings(defaults: library.settings.defaults).provider != .none,
                     offersSignIn: !signedIn,
                     local: model.storesLocally(launcher: launcher),
                     changeable: model.canChangeStorage(launcher: launcher))
    }

    static func sourceName(_ provider: RegisteredProvider) -> String {
        provider.isOllama ? "Ollama" : provider.name
    }

    /// The card's lead sentence: why it is kept here, or what the choice means.
    var summaryKey: String {
        if offersSignIn { return "ask.local.card.body" }
        if changeable { return "ask.storage.card.choose" }
        return local ? "ask.storage.card.lockedLocal" : "ask.storage.card.lockedCloud"
    }
}

/// Whether the sidebar's Typeflux Cloud card shows: until the user closes it,
/// then again after a quiet period.
enum AskCloudPromo {
    static let dismissedKey = "ask.cloudPromo.dismissedAt"
    static let quietPeriod: TimeInterval = 30 * 24 * 60 * 60

    static func isVisible(dismissedAt: TimeInterval, now: Date = Date()) -> Bool {
        dismissedAt <= 0 || now.timeIntervalSince1970 - dismissedAt >= quietPeriod
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
                            RoundedRectangle(cornerRadius: 7, style: .continuous).fill(AskTheme.controlSurface)
                                .shadow(color: .black.opacity(0.18), radius: 1.5, y: 1)
                        }
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(chosen ? .isSelected : [])
            }
        }
        .padding(2)
        .frame(height: Self.height)
        .background(AskTheme.hoverFill, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
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
    /// Picks where the new conversation is kept: true on this Mac.
    var onChoose: (Bool) -> Void = { _ in }
    /// Starts a conversation of the other kind, for one that already started.
    var onStartOther: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                Label(L(status.local ? "ask.storage.local" : "ask.storage.cloud"),
                      systemImage: status.local ? "lock" : "cloud")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(StudioTheme.textPrimary)
                Text(L(status.summaryKey))
                    .font(.system(size: 11.5))
                    .foregroundStyle(StudioTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if status.changeable {
                VStack(spacing: 4) {
                    option(local: false)
                    option(local: true)
                }
            }
            Rectangle().fill(AskTheme.separator).frame(height: 0.5)
            if status.local { localDetails } else { cloudDetails }
            if status.offersSignIn {
                Rectangle().fill(AskTheme.separator).frame(height: 0.5)
                HStack(spacing: 8) {
                    Text(L("ask.local.card.cloudQuestion")).font(.system(size: 11.5))
                        .foregroundStyle(StudioTheme.textSecondary)
                    Spacer(minLength: 6)
                    Button(L("account.card.signIn"), action: onSignIn)
                        .buttonStyle(AskCapsuleButtonStyle(kind: .primary))
                }
            } else if !status.changeable {
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
            row(L("ask.local.card.source"), status.source)
            row(L("ask.local.card.readPages"), L("ask.local.card.available"))
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

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(StudioTheme.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func option(local: Bool) -> some View {
        let chosen = status.local == local
        let tint = local ? AskTheme.privateTint : AskTheme.accent
        return Button { onChoose(local) } label: {
            HStack(spacing: 10) {
                Image(systemName: local ? "lock" : "cloud")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(tint)
                    .frame(width: 26, height: 26)
                    .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(L(local ? "ask.storage.local" : "ask.storage.cloud"))
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(StudioTheme.textPrimary)
                    Text(L(local ? "ask.storage.local.detail" : "ask.storage.cloud.detail"))
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
                .strokeBorder(chosen ? tint.opacity(0.5) : .clear, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(label).foregroundStyle(StudioTheme.textSecondary).frame(width: 64, alignment: .leading)
            Text(value).foregroundStyle(StudioTheme.textPrimary).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 6)
            Circle().fill(StudioTheme.success).frame(width: 6, height: 6)
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
                LoginWindowController.shared.show()
            }, onChoose: { local in
                isPresented = false
                model.setStoresLocally(local, launcher: launcher)
            }, onStartOther: {
                isPresented = false
                model.newConversation(storesLocally: !status.local)
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
        let local = model.storesLocally(launcher: launcher)
        let name = L(local ? "ask.storage.local" : "ask.storage.cloud")
        let active = hovering || presented
        Button { presented.toggle() } label: {
            Image(systemName: local ? "lock" : "cloud")
                .font(.system(size: 12.5, weight: local || active ? .semibold : .medium))
                .foregroundStyle(Self.iconColor(local: local, active: active))
                .frame(width: Self.size, height: Self.size)
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

    /// No circle behind the icon: the private tint marks this Mac, hover or an
    /// open menu brightens the cloud.
    static func iconColor(local: Bool, active: Bool) -> Color {
        if local { return AskTheme.privateTint }
        return active ? StudioTheme.textPrimary : StudioTheme.textSecondary
    }
}

/// The sidebar footer while signed out: where Ask runs, instead of a lone sign-in link.
struct AskLocalModeIdentity: View {
    @ObservedObject var model: AskConversationModel
    @State private var presented = false
    @State private var hovering = false

    var body: some View {
        let status = AskLocalModeStatus.make(model: model, signedIn: false)
        Button { presented.toggle() } label: {
            HStack(spacing: 9) {
                Image(systemName: "desktopcomputer").font(.system(size: 13, weight: .medium))
                    .foregroundStyle(StudioTheme.textPrimary)
                    .frame(width: 30, height: 30)
                    .background(AskTheme.hoverFill, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(L("ask.local.identity")).font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(StudioTheme.textPrimary)
                    Text(String(format: L("ask.local.identity.detail"), status.source))
                        .font(.system(size: 11))
                        .foregroundStyle(StudioTheme.textTertiary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            .padding(.leading, 4).padding(.trailing, 8)
            .frame(height: 40)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(hovering || presented ? AskTheme.hoverFill : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.leading, -4)
        .onHover { hovering = $0 }
        .modifier(AskLocalModeMenu(isPresented: $presented, status: status, model: model))
        .accessibilityLabel(L("ask.local.identity"))
        .accessibilityHint(L("ask.location.local.help"))
    }
}

/// What Typeflux Cloud adds, above the signed-out footer. Closing it keeps it
/// away for `AskCloudPromo.quietPeriod`.
struct AskCloudPromoCard: View {
    var onSignIn: () -> Void
    var onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "cloud").font(.system(size: 12, weight: .semibold))
                Text(verbatim: "Typeflux Cloud").font(.system(size: 12.5, weight: .semibold))
                Spacer(minLength: 4)
                Button(action: onDismiss) {
                    Image(systemName: "xmark").font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(StudioTheme.textTertiary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L("ask.cloudPromo.dismiss"))
                .accessibilityLabel(L("ask.cloudPromo.dismiss"))
            }
            .foregroundStyle(StudioTheme.textPrimary)
            Text(L("ask.cloudPromo.body"))
                .font(.system(size: 11.5))
                .foregroundStyle(StudioTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(L("ask.cloudPromo.signIn"), action: onSignIn)
                .buttonStyle(AskCapsuleButtonStyle(kind: .primary))
                .padding(.top, 2)
        }
        .padding(.horizontal, 12).padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LinearGradient(colors: [AskTheme.accent.opacity(0.16), Color.purple.opacity(0.1)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(AskTheme.separator, lineWidth: 0.5))
    }
}
