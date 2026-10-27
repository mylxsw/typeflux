import SwiftUI

/// Keep the next action in the transcript. Offer details only when they add
/// actionable evidence beyond the status and controls already shown here.
struct AskRecoveryCard: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let presentation: AskRecoveryPresentation
    var canRetransmit = false
    var canContinue = false
    var working = false
    var hasUsefulDetails = false
    var inspect: () -> Void = {}
    var perform: (AskRecoveryAction) -> Void = { _ in }

    private var actions: AskRecoveryPresentation.Actions {
        presentation.actions(canRetransmit: canRetransmit, canContinue: canContinue, hasUsefulDetails: hasUsefulDetails)
    }

    var body: some View {
        if presentation.isVisible {
            HStack(alignment: .top, spacing: 12) {
                AskRecoverySymbol(presentation: presentation)
                VStack(alignment: .leading, spacing: 0) {
                    Text(L(presentation.titleKey))
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(StudioTheme.textPrimary)
                        .padding(.top, 5)
                    Text(presentation.bodyText)
                        .font(.system(size: 12.5))
                        .foregroundStyle(StudioTheme.textSecondary)
                        .lineSpacing(3)
                        .padding(.top, 4)
                    buttons.padding(.top, 14)
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, 16)
            .padding(.trailing, 18)
            .padding(.vertical, 16)
            .background(background)
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(presentation.unknown ? StudioTheme.warning.opacity(0.32) : AskTheme.border))
            .transaction {
                if reduceMotion {
                    $0.animation = nil; $0.disablesAnimations = true
                }
            }
            .accessibilityElement(children: .contain)
        }
    }

    /// A warm wash only when the outcome is uncertain; otherwise the plain raised surface.
    private var background: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(AskTheme.raisedSurface)
            .overlay {
                if presentation.unknown {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(LinearGradient(colors: [AskTheme.warningSoft, AskTheme.raisedSurface.opacity(0)],
                                             startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.7)))
                }
            }
    }

    private var buttons: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { buttonRow }
            VStack(alignment: .leading, spacing: 8) { buttonRow }
        }
        .disabled(working)
    }

    @ViewBuilder private var buttonRow: some View {
        if working {
            ProgressView().controlSize(.small).accessibilityLabel(L("ask.working"))
        }
        if let primary = actions.primary {
            Button { perform(primary) } label: {
                HStack(spacing: 6) {
                    Image(systemName: Self.symbol(primary)).font(.system(size: 11, weight: .semibold))
                    Text(L(primary.titleKey))
                }
            }
            .buttonStyle(AskCapsuleButtonStyle())
        }
        if actions.stop {
            Button(L("ask.recovery.end")) { perform(.stop) }
                .buttonStyle(AskCapsuleButtonStyle(kind: .secondary))
        }
        if actions.details {
            Button(action: inspect) {
                HStack(spacing: 4) {
                    Text(L("ask.recovery.details"))
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                }
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(StudioTheme.textSecondary)
                .padding(.horizontal, 10)
                .frame(height: 30)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .fixedSize()
        }
    }

    static func symbol(_ action: AskRecoveryAction) -> String {
        switch action {
        case .checkAndContinue: "checkmark.shield"
        case .refresh: "arrow.triangle.2.circlepath"
        case .continueRun: "play.fill"
        case .selfCheck: "bubble.left"
        case .stop: "stop.fill"
        }
    }
}

/// Details explain the evidence and consequences. Actions stay in a pinned
/// footer rather than asking the user to select the same buttons a second time.
struct AskRecoveryInspector: View {
    @ObservedObject var model: AskConversationModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var presentation: AskRecoveryPresentation {
        model.recoveryPresentation
    }

    private var details: AskRecoveryDetails {
        model.recoveryDetails
    }

    private var actions: AskRecoveryPresentation.Actions {
        presentation.actions(canRetransmit: model.canRetransmitReceipts,
                             canContinue: presentation.canContinue && !model.canRetransmitReceipts)
    }

    var body: some View {
        if details.hasUsefulDetails { panel }
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                AskRecoverySymbol(presentation: presentation, size: 36)
                VStack(alignment: .leading, spacing: 5) {
                    Text(L(model.selected?.run?
                            .status == "cancelled" ? "ask.recovery.stopped" : "ask.recovery.detail.title"))
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(StudioTheme.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                    Text(L(
                        details.step > 0 ? "ask.recovery.detail.step" : "ask.recovery.detail.notStarted",
                        details.step
                    ))
                    .font(.system(size: 12)).foregroundStyle(StudioTheme.textSecondary)
                }
            }
            .padding(.horizontal, 22).padding(.top, 20).padding(.bottom, 16)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    section("ask.recovery.detail.why") {
                        paragraph(L(details.reasonKey))
                        if let explanation = details.inspectionExplanation, !explanation.isEmpty {
                            Text(L("ask.recovery.detail.inspectionNote"))
                                .font(.system(size: 11.5)).foregroundStyle(StudioTheme.textTertiary)
                            paragraph(explanation)
                        }
                    }
                    section("ask.recovery.detail.progress") {
                        paragraph(L(
                            details.savedResults > 0 ? "ask.recovery.detail.savedCount" : "ask.recovery.detail.noSaved",
                            details.savedResults
                        ))
                        if let kind = details.pendingKind {
                            paragraph(L("ask.recovery.detail.pending", L("ask.recovery.tool." + kind)))
                        }
                        if details.unconfirmedResults > 0 {
                            paragraph(
                                L("ask.recovery.detail.unconfirmedCount", details.unconfirmedResults),
                                warning: true
                            )
                        }
                        if details.totalPlanItems > 0 {
                            paragraph(L(
                                "ask.recovery.detail.planCount",
                                details.completedPlanItems,
                                details.totalPlanItems
                            ))
                        }
                    }
                    section("ask.recovery.detail.next") {
                        if let next = details.nextPlanStep {
                            Text(L("ask.recovery.detail.nextPlan"))
                                .font(.system(size: 11.5)).foregroundStyle(StudioTheme.textTertiary)
                            paragraph(next)
                        }
                        if let primary = actions.primary {
                            paragraph(L(primary.detailKey))
                        } else {
                            paragraph(L(details.reason == .storage ? "ask.recovery.detail.nextStorage" :
                                    (presentation
                                        .otherDevice ? "ask.recovery.binding" : "ask.recovery.detail.action.return")))
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 22).padding(.bottom, 20)
            }
            .frame(maxHeight: 320)
            Rectangle().fill(AskTheme.separator).frame(height: 1)
            footer
        }
        .frame(minWidth: 280, idealWidth: 520, maxWidth: 520, alignment: .topLeading)
        .background(AskTheme.popoverSurface)
        .transaction {
            if reduceMotion { $0.animation = nil; $0.disablesAnimations = true }
        }
    }

    private func section(_ key: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(L(key)).font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(StudioTheme.textPrimary).accessibilityAddTraits(.isHeader)
            content()
        }
    }

    private func paragraph(_ text: String, warning: Bool = false) -> some View {
        Text(text).font(.system(size: 12.5))
            .foregroundStyle(warning ? StudioTheme.warning : StudioTheme.textSecondary)
            .lineSpacing(3).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 12) {
            if actions.stop { paragraph(L(AskRecoveryAction.stop.detailKey)) }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { Spacer(minLength: 0); footerButtons }
                VStack(alignment: .trailing, spacing: 8) { footerButtons }.frame(
                    maxWidth: .infinity,
                    alignment: .trailing
                )
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .disabled(model.recoveryWorking)
        .padding(.horizontal, 22).padding(.vertical, 16)
    }

    @ViewBuilder private var footerButtons: some View {
        if model.recoveryWorking {
            ProgressView().controlSize(.small).accessibilityLabel(L("ask.working"))
        }
        Button(L("ask.recovery.close"), action: model.dismissRecoveryInspector)
            .buttonStyle(AskCapsuleButtonStyle(kind: actions.primary == nil ? .primary : .secondary))
            .keyboardShortcut(.cancelAction).fixedSize()
        if actions.stop {
            Button(L(AskRecoveryAction.stop.titleKey)) { model.performRecovery(.stop) }
                .buttonStyle(AskCapsuleButtonStyle(kind: .secondary)).fixedSize()
        }
        if let primary = actions.primary {
            Button(L(primary.titleKey)) { model.performRecovery(primary) }
                .buttonStyle(AskCapsuleButtonStyle()).fixedSize()
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
            .overlay {
                if presentation.unknown {
                    RoundedRectangle(cornerRadius: size * 0.32, style: .continuous)
                        .strokeBorder(StudioTheme.warning.opacity(0.32))
                }
            }
            .accessibilityHidden(true)
    }
}
