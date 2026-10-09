import SwiftUI
import TypefluxChat

/// Buy credits through the App Store. Packs and amounts come from the server,
/// prices from StoreKit in the user's own currency.
struct ChatCreditShopView: View {
    @Bindable var store: ChatStore
    @Bindable var shop: ChatCreditShop
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let usage = store.creditUsage {
                        ChatCreditSummary(usage: usage).padding(16).chatCard(corner: 20)
                    }
                    if let notice = shop.notice {
                        noticeView(notice)
                    }
                    content
                    Text(
                        "Payment is charged to your Apple Account. Credits are added to this Typeflux account, shared with your Mac, and used after your monthly credits."
                    )
                    .font(.footnote).foregroundStyle(ChatTheme.secondary)
                    .padding(.horizontal, 4)
                    Button {
                        Task { await shop.checkMissingCredits() }
                    } label: {
                        Text("Missing credits from a purchase?").font(.footnote.weight(.medium))
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .accessibilityIdentifier("credits.restore")
                }
                .padding(16).frame(maxWidth: 560).frame(maxWidth: .infinity)
            }
            .background(ChatTheme.background)
            .navigationTitle("Buy credits")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.fontWeight(.semibold).accessibilityIdentifier("credits.done")
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("credits.root")
        }
        .tint(ChatTheme.accent)
        .interactiveDismissDisabled(shop.purchasingCode != nil)
        .task {
            if shop.phase != .ready {
                await shop.load()
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch shop.phase {
        case .idle, .loading:
            ProgressView("Loading credit packs…").frame(maxWidth: .infinity).padding(.vertical, 40)
        case .unavailable:
            message(symbol: "bag", title: "Credit packs aren't available right now",
                    detail: "Your monthly credits reset at the start of each billing period.")
        case let .failed(error):
            VStack(spacing: 12) {
                message(symbol: "wifi.exclamationmark", title: "Couldn't load credit packs", detail: error)
                Button("Try again") { Task { await shop.load() } }
                    .buttonStyle(.bordered).accessibilityIdentifier("credits.retry")
            }
            .frame(maxWidth: .infinity)
        case .ready:
            VStack(spacing: 12) {
                ForEach(shop.offers) { offer in
                    offerCard(offer)
                }
            }
        }
    }

    private func offerCard(_ offer: ChatCreditShop.Offer) -> some View {
        let buying = shop.purchasingCode == offer.pack.code
        return HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(offer.pack.name).font(.system(size: 16, weight: .semibold))
                    if offer.pack.highlight {
                        Text("Best value").font(.system(size: 10.5, weight: .bold))
                            .foregroundStyle(ChatTheme.accentText)
                            .padding(.horizontal, 6).padding(.vertical, 1.5)
                            .background(ChatTheme.accentSoft, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                }
                Text(String(format: NSLocalizedString("%@ credits", comment: "Credit pack amount"),
                            offer.pack.credits.formatted()))
                    .font(.system(size: 22, weight: .bold)).monospacedDigit()
                if !offer.pack.description.isEmpty {
                    Text(offer.pack.description).font(.footnote).foregroundStyle(ChatTheme.secondary)
                }
                Text(String(format: NSLocalizedString("Valid for %d days", comment: "Credit pack validity"),
                            offer.pack.validDays))
                    .font(.caption).foregroundStyle(ChatTheme.tertiary)
            }
            Spacer(minLength: 8)
            Button {
                Task { await shop.buy(offer) }
            } label: {
                Group {
                    if buying {
                        ProgressView().tint(.white)
                    } else {
                        Text(offer.price).font(.system(size: 15, weight: .semibold)).monospacedDigit()
                    }
                }
                .foregroundStyle(.white).frame(minWidth: 76, minHeight: 40).padding(.horizontal, 6)
                .background(ChatTheme.accent, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(shop.purchasingCode != nil)
            .accessibilityLabel(Text(String(format: NSLocalizedString("Buy %@ for %@", comment: "Buy pack"),
                                            offer.pack.name, offer.price)))
            .accessibilityIdentifier("credits.buy." + offer.pack.code)
        }
        .padding(16)
        .chatCard(corner: 20)
        .overlay {
            if offer.pack.highlight {
                RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(ChatTheme.accent.opacity(0.5))
            }
        }
    }

    private func message(symbol: String, title: LocalizedStringKey, detail: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 26)).foregroundStyle(ChatTheme.tertiary)
            Text(title).font(.headline).multilineTextAlignment(.center)
            Text(LocalizedStringKey(detail)).font(.subheadline).foregroundStyle(ChatTheme.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 28).padding(.horizontal, 16)
        .chatCard(corner: 20)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("credits.message")
    }

    private func noticeView(_ notice: ChatCreditShop.Notice) -> some View {
        let (symbol, color, text) = Self.presentation(notice)
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(color).accessibilityHidden(true)
            Text(text).font(.subheadline).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button { shop.notice = nil } label: {
                Image(systemName: "xmark").font(.caption.weight(.semibold)).foregroundStyle(ChatTheme.tertiary)
                    .frame(width: 32, height: 32)
            }
            .accessibilityLabel("Dismiss")
        }
        .padding(.leading, 14).padding(.vertical, 6).padding(.trailing, 4)
        .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityIdentifier("credits.notice")
    }

    static func presentation(_ notice: ChatCreditShop.Notice) -> (String, Color, String) {
        switch notice {
        case let .delivered(credits):
            let text = credits.map {
                String(format: NSLocalizedString("%@ credits were added to your account.", comment: "Purchase done"),
                       $0.formatted())
            } ?? NSLocalizedString("Your credits were added.", comment: "Purchase done")
            return ("checkmark.circle.fill", ChatTheme.success, text)
        case .pending:
            return ("clock.fill", .orange, NSLocalizedString(
                "Waiting for approval. Credits are added as soon as the purchase is approved.",
                comment: "Purchase pending"
            ))
        case .upToDate:
            return ("checkmark.circle", ChatTheme.secondary, NSLocalizedString(
                "All your purchases have been delivered. Check the add-on credits above.", comment: "Nothing to restore"
            ))
        case .waitingForAccount:
            return ("person.crop.circle.badge.exclamationmark", .orange, NSLocalizedString(
                "This purchase was made with another Typeflux account. Sign in to that account to receive the credits.",
                comment: "Purchase account mismatch"
            ))
        case let .failed(message):
            return ("exclamationmark.triangle.fill", .red, message)
        }
    }
}

/// "Out of credits" above the composer: why the conversation stopped and the
/// two ways forward, buying credits or continuing once the balance is back.
struct ChatCreditPauseCard: View {
    @Bindable var store: ChatStore
    var onBuy: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "pause.fill").font(.system(size: 13, weight: .semibold)).foregroundStyle(.orange)
                    .frame(width: 30, height: 30)
                    .background(Color.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("You're out of credits").font(.system(size: 15, weight: .semibold))
                    Text(detail).font(.system(size: 13)).foregroundStyle(ChatTheme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 8) {
                Button(action: onBuy) {
                    Text("Buy credits").font(.system(size: 14.5, weight: .semibold)).foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .background(ChatTheme.accent, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("chat.credits.buy")
                if store.isPausedForCredits {
                    Button { Task { await store.resumeRun() } } label: {
                        Group {
                            if store.isSending {
                                ProgressView().controlSize(.small)
                            } else {
                                Text("Continue").font(.system(size: 14.5, weight: .semibold))
                            }
                        }
                        .foregroundStyle(.primary).frame(maxWidth: .infinity, minHeight: 40)
                        .background(ChatTheme.fill, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(store.isSending)
                    .accessibilityIdentifier("chat.credits.resume")
                }
            }
        }
        .padding(14)
        .chatCard(corner: 20)
        .padding(.horizontal, 12).padding(.bottom, 8)
        .frame(maxWidth: 780).frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.credits.card")
    }

    private var detail: String {
        if store.isPausedForCredits {
            return NSLocalizedString(
                "This answer is paused. Buy credits, then tap Continue to pick up where it stopped.",
                comment: "Credit pause detail"
            )
        }
        return NSLocalizedString(
            "Buy a credit pack to keep chatting, or wait until your monthly credits reset.",
            comment: "Credits exhausted detail"
        )
    }
}
