import AppKit
import SwiftUI

/// Opens the account card 400ms into a hover (a quick pass over the footer does
/// nothing), keeps it open while the pointer is on the name or the card, and
/// closes it shortly after the pointer leaves both. A click pins it open until
/// a second click, a click outside or Esc (the glass presenter handles those).
@MainActor
final class AskAccountCardHover: ObservableObject {
    static let openDelay: Duration = .milliseconds(400)
    static let pollInterval: Duration = .milliseconds(120)

    @Published var isPresented = false {
        didSet {
            guard !isPresented, oldValue else { return }
            pinned = false
            task?.cancel()
        }
    }

    private(set) var pinned = false
    private var task: Task<Void, Never>?
    private let openDelay: Duration
    private let pollInterval: Duration
    /// Consecutive polls outside the name and the card before closing.
    private let closeAfterMisses = 2
    private let pointerInside: @MainActor () -> Bool

    init(openDelay: Duration = AskAccountCardHover.openDelay,
         pollInterval: Duration = AskAccountCardHover.pollInterval,
         pointerInside: @escaping @MainActor () -> Bool = {
             AskGlassMenuPresenter.shared.containsPointer(NSEvent.mouseLocation)
         }) {
        self.openDelay = openDelay
        self.pollInterval = pollInterval
        self.pointerInside = pointerInside
    }

    deinit { task?.cancel() }

    func hover(_ inside: Bool) {
        task?.cancel()
        if inside {
            guard !isPresented else { return }
            let delay = openDelay
            task = Task { [weak self] in
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
                self?.isPresented = true
            }
        } else if isPresented, !pinned {
            watchForExit()
        }
    }

    func click() {
        task?.cancel()
        if isPresented, pinned {
            isPresented = false
        } else {
            pinned = true
            isPresented = true
        }
    }

    private func watchForExit() {
        let interval = pollInterval, limit = closeAfterMisses
        task = Task { [weak self] in
            var misses = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self, !Task.isCancelled, isPresented, !pinned else { return }
                misses = pointerInside() ? 0 : misses + 1
                if misses >= limit {
                    isPresented = false
                    return
                }
            }
        }
    }
}

/// The Ask sidebar's footer identity: the name with a plan badge, or a sign-in
/// link when signed out. Hovering or clicking the name opens `AskAccountCard`.
struct AskAccountFooterIdentity: View {
    @ObservedObject var auth: AuthState
    let name: String
    /// Ask runs on the user's own models rather than Cloud.
    var runsLocally = false
    let onOpenAccount: () -> Void
    @StateObject private var hover = AskAccountCardHover()
    @State private var hovering = false

    var body: some View {
        Group {
            if auth.isLoggedIn {
                identity
            } else {
                signIn
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await auth.refreshAccountSummary() }
        }
        .task { await auth.refreshAccountSummary() }
    }

    private var presentation: AccountStatusPresentation {
        AccountStatusPresentation.make(subscription: auth.subscription, credits: auth.usageCredits,
                                       usagePeriodStart: auth.usagePeriodStart, usagePeriodEnd: auth.usagePeriodEnd)
    }

    private var identity: some View {
        let footer = presentation.footerBadge(runsLocally: runsLocally)
        let highlighted = hovering || hover.isPresented
        return Button { hover.click() } label: {
            HStack(spacing: 7) {
                Text(name)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(highlighted ? StudioTheme.textPrimary : StudioTheme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let badge = footer.badge {
                    AskAccountBadge(text: AccountStatusText.badge(badge), tone: footer.tone)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
            .background(Capsule().fill(highlighted ? AskTheme.hoverFill : .clear))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .padding(.leading, -8)
        .onHover { inside in
            hovering = inside
            hover.hover(inside)
        }
        .askMenu(isPresented: $hover.isPresented, glass: true) {
            AskAccountCard(auth: auth, onOpenAccount: {
                hover.isPresented = false
                onOpenAccount()
            }, onDismiss: { hover.isPresented = false })
        }
        .accessibilityLabel(name)
        .accessibilityValue(footer.badge.map(AccountStatusText.badge) ?? "")
        .accessibilityHint(L("account.card.openHint"))
    }

    private var signIn: some View {
        Button { LoginWindowController.shared.show() } label: {
            HStack(spacing: 4) {
                Text(L("account.card.signIn"))
                Image(systemName: "chevron.right").font(.system(size: 9.5, weight: .bold))
            }
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(AskTheme.accentText)
            .padding(.horizontal, 8)
            .frame(height: 30)
            .background(Capsule().fill(hovering ? AskTheme.hoverFill : .clear))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .padding(.leading, -8)
        .onHover { hovering = $0 }
    }
}

struct AskAccountBadge: View {
    let text: String
    let tone: AccountStatusPresentation.Tone

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(AskAccountTone.foreground(tone))
            .padding(.horizontal, 7)
            .frame(height: 18)
            .background(Capsule().fill(AskAccountTone.fill(tone)))
            .overlay {
                if tone == .neutral { Capsule().strokeBorder(AskTheme.border) }
            }
    }
}

enum AskAccountTone {
    /// A faint wash for the card's blocks, readable on glass in both appearances.
    static let chip = StudioTheme.dynamic(
        light: NSColor(calibratedWhite: 0, alpha: 0.045),
        dark: NSColor(calibratedWhite: 1, alpha: 0.07)
    )

    static func foreground(_ tone: AccountStatusPresentation.Tone) -> Color {
        switch tone {
        case .neutral: StudioTheme.textSecondary
        case .accent: AskTheme.accentText
        case .warning: StudioTheme.warning
        case .danger: StudioTheme.danger
        }
    }

    static func fill(_ tone: AccountStatusPresentation.Tone) -> Color {
        switch tone {
        case .neutral: chip
        case .accent: StudioTheme.accent.opacity(0.18)
        case .warning: StudioTheme.warning.opacity(0.16)
        case .danger: StudioTheme.danger.opacity(0.16)
        }
    }

    static func bar(_ level: AccountStatusPresentation.QuotaLevel) -> Color {
        switch level {
        case .normal: StudioTheme.accent
        case .low: StudioTheme.warning
        case .exhausted: StudioTheme.danger
        }
    }
}
