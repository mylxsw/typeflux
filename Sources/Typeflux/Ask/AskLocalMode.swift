import AppKit
import SwiftUI

/// What the "On this Mac" card reports about a local run.
struct AskLocalModeStatus: Equatable {
    /// Where the conversation's model runs, e.g. "Ollama".
    var source: String
    var searchConfigured: Bool
    /// Signed out: the card offers Typeflux Cloud. A signed-in user who chose
    /// local mode already knows about it.
    var offersSignIn: Bool

    @MainActor
    static func make(model: AskConversationModel, signedIn: Bool) -> Self {
        let library = model.modelLibrary
        let provider = library.registry.resolve(model.modelReference(launcher: false))?.0
        return .init(source: provider.map(sourceName) ?? L("ask.local.sourceNone"),
                     searchConfigured: AskSearchSettings(defaults: library.settings.defaults).provider != .none,
                     offersSignIn: !signedIn)
    }

    static func sourceName(_ provider: RegisteredProvider) -> String {
        provider.isOllama ? "Ollama" : provider.name
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

/// The card behind "On this Mac": why Ask runs here, what works, the one fix
/// for what does not, and the way to Typeflux Cloud.
struct AskLocalModeCard: View {
    static let width: CGFloat = 320

    let status: AskLocalModeStatus
    var onOpenSearchSettings: () -> Void
    var onSignIn: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                Label(L("ask.local.card.title"), systemImage: "desktopcomputer")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(StudioTheme.textPrimary)
                Text(L(status.offersSignIn ? "ask.local.card.body" : "ask.local.card.bodyLocalMode"))
                    .font(.system(size: 11.5))
                    .foregroundStyle(StudioTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Rectangle().fill(AskTheme.separator).frame(height: 0.5)
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
        }
        .padding(14)
        .frame(width: Self.width, alignment: .leading)
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

/// Opens the local-mode card from any anchor and runs its actions.
private struct AskLocalModeMenu: ViewModifier {
    @Binding var isPresented: Bool
    let status: AskLocalModeStatus
    let openSettings: ((StudioSection) -> Void)?

    func body(content: Content) -> some View {
        content.askMenu(isPresented: $isPresented, glass: true) {
            AskLocalModeCard(status: status, onOpenSearchSettings: {
                isPresented = false
                openSettings?(.agent)
            }, onSignIn: {
                isPresented = false
                LoginWindowController.shared.show()
            })
        }
    }
}

/// The composer's "On this Mac" pill. It reads as a neutral state, not a
/// warning, and a click explains it.
struct AskLocalModeButton: View {
    @ObservedObject var model: AskConversationModel
    @ObservedObject var auth: AuthState = .shared
    @State private var presented = false

    var body: some View {
        if !model.cloudAvailable {
            Button { presented.toggle() } label: {
                AskRunLocationLabel(local: true, highlighted: presented)
            }
            .buttonStyle(.plain)
            .modifier(AskLocalModeMenu(isPresented: $presented,
                                       status: .make(model: model, signedIn: auth.isLoggedIn),
                                       openSettings: model.onOpenSettings))
        }
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
        .modifier(AskLocalModeMenu(isPresented: $presented, status: status, openSettings: model.onOpenSettings))
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
