import SwiftUI

/// The same card is used in the transcript and screenshot fixtures.
struct AskRecoveryCard: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let presentation: AskRecoveryPresentation
    var canRetransmit = false
    var canContinue = false
    var working = false
    var inspect: () -> Void = {}
    var retransmit: () -> Void = {}
    var continueRun: () -> Void = {}

    var body: some View {
        if presentation.isVisible {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 16) {
                    summary.frame(minWidth: 300)
                    actions
                }
                VStack(alignment: .leading, spacing: 12) {
                    summary
                    actions.padding(.leading, 44)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .askInWindowGlass(corner: 18, opaqueFill: AskTheme.raisedSurface, elevation: nil)
            .environment(\.askGlassMaterialOverride, .opaque)
            .transaction {
                if reduceMotion {
                    $0.animation = nil; $0.disablesAnimations = true
                }
            }
            .accessibilityElement(children: .contain)
        }
    }

    private var summary: some View {
        HStack(alignment: .top, spacing: 12) {
            AskRecoverySymbol(presentation: presentation)
            VStack(alignment: .leading, spacing: 4) {
                Text(L(presentation.titleKey))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(StudioTheme.textPrimary)
                Text(L(presentation.bodyKey))
                    .font(.system(size: 12))
                    .foregroundStyle(StudioTheme.textSecondary)
                    .lineSpacing(3)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            if working {
                ProgressView().controlSize(.small).accessibilityLabel(L("ask.working"))
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { buttons }
                VStack(alignment: .leading, spacing: 8) { buttons }
            }
        }
        .disabled(working)
    }

    @ViewBuilder private var buttons: some View {
        if presentation.unknown {
            Button(action: inspect) {
                HStack(spacing: 6) {
                    Text(L("ask.recovery.inspect"))
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                }
            }
            .buttonStyle(AskCapsuleButtonStyle(kind: .secondary))
        }
        if canRetransmit {
            Button(L("ask.recovery.retransmit"), action: retransmit)
                .buttonStyle(AskCapsuleButtonStyle())
        }
        if canContinue {
            Button(L("ask.recovery.continue"), action: continueRun)
                .buttonStyle(AskCapsuleButtonStyle())
        }
    }
}

struct AskRecoveryInspector: View {
    @ObservedObject var model: AskConversationModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let presentation = model.recoveryPresentation
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top, spacing: 14) {
                    AskRecoverySymbol(presentation: presentation, size: 40)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L(presentation.unknown && model.selected?.run?.status == "cancelled"
                                ? "ask.recovery.stopped" : presentation.titleKey))
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(StudioTheme.textPrimary)
                        Text(L(presentation.bodyKey))
                            .font(.system(size: 13))
                            .foregroundStyle(StudioTheme.textSecondary)
                            .lineSpacing(4)
                    }
                }
                if let message = model.recoveryRequestText {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L("ask.recovery.message"))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(StudioTheme.textSecondary)
                        Text(message)
                            .font(.system(size: 13))
                            .foregroundStyle(StudioTheme.textPrimary)
                            .lineLimit(3)
                            .textSelection(.enabled)
                            .help(message)
                    }
                    .padding(.leading, 12)
                    .overlay(alignment: .leading) { Rectangle().fill(AskTheme.border).frame(width: 2) }
                    .padding(.leading, 54)
                }
                if presentation.unknown {
                    VStack(alignment: .leading, spacing: 14) {
                        guidance("ask.recovery.checkBody", symbol: "checkmark.shield")
                        Rectangle().fill(AskTheme.separator).frame(height: 1)
                        guidance(presentation.active ? "ask.recovery.endBody" : "ask.recovery.followUpBody",
                                 symbol: presentation.active ? "stop.circle" : "bubble.left")
                    }
                    .padding(16)
                    .background(AskTheme.raisedSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
            .padding(24)
            Rectangle().fill(AskTheme.separator).frame(height: 1)
            HStack(spacing: 12) {
                if !presentation.active {
                    Spacer(minLength: 0)
                }
                Button(L("ask.recovery.close"), action: model.dismissRecoveryInspector)
                    .buttonStyle(AskCapsuleButtonStyle(kind: presentation.active ? .secondary : .primary))
                    .keyboardShortcut(.cancelAction)
                if presentation.active {
                    Spacer(minLength: 0)
                }
                if model.recoveryWorking {
                    ProgressView().controlSize(.small).accessibilityLabel(L("ask.working"))
                }
                if presentation.active {
                    Button(L("ask.recovery.end")) { Task { await model.endRecoveryRun() } }
                        .buttonStyle(AskCapsuleButtonStyle())
                }
            }
            .disabled(model.recoveryWorking)
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
        }
        .frame(minWidth: 320, idealWidth: 480, maxWidth: 480, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background(AskTheme.popoverSurface)
        .transaction {
            if reduceMotion {
                $0.animation = nil; $0.disablesAnimations = true
            }
        }
    }

    private func guidance(_ key: String, symbol: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(StudioTheme.textTertiary)
                .frame(width: 18, height: 18)
                .accessibilityHidden(true)
            Text(L(key))
                .font(.system(size: 12.5))
                .foregroundStyle(StudioTheme.textSecondary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct AskRecoverySymbol: View {
    let presentation: AskRecoveryPresentation
    var size: CGFloat = 32

    var body: some View {
        Image(systemName: presentation.unknown ? "questionmark" :
            (presentation.savedReceipts > 0 ? "arrow.triangle.2.circlepath" : "pause.fill"))
            .font(.system(size: size * 0.44, weight: .semibold))
            .foregroundStyle(presentation.unknown ? StudioTheme.warning : AskTheme.accentText)
            .frame(width: size, height: size)
            .background(presentation.unknown ? AskTheme.warningSoft : AskTheme.accentSoft,
                        in: RoundedRectangle(cornerRadius: size * 0.32, style: .continuous))
            .accessibilityHidden(true)
    }
}
