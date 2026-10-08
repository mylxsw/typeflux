import SwiftUI

/// The same card is used in the transcript and screenshot fixtures. One card says
/// why the run stopped and offers one clear next step, Stop, and "Learn more".
struct AskRecoveryCard: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let presentation: AskRecoveryPresentation
    var canRetransmit = false
    var canContinue = false
    var working = false
    var inspect: () -> Void = {}
    var perform: (AskRecoveryAction) -> Void = { _ in }

    private var actions: AskRecoveryPresentation.Actions {
        presentation.actions(canRetransmit: canRetransmit, canContinue: canContinue)
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
                    Text(L(presentation.bodyKey))
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

/// "What next": where the run stopped, the choices with their consequences, and
/// one primary button that follows the chosen option. A single popover surface;
/// only a hairline separates the footer.
struct AskRecoveryInspector: View {
    @ObservedObject var model: AskConversationModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var choice: AskRecoveryAction?

    private var presentation: AskRecoveryPresentation { model.recoveryPresentation }

    private var options: [AskRecoveryAction] {
        presentation.options(canRetransmit: model.canRetransmitReceipts,
                             canContinue: presentation.canContinue && !model.canRetransmitReceipts)
    }

    /// The user's pick while it is still offered, else the recommended option.
    private var selected: AskRecoveryAction? {
        choice.flatMap { options.contains($0) ? $0 : nil } ?? options.first
    }

    var body: some View {
        let timeline = AskRecoveryTimeline(run: model.selected?.run, unknown: presentation.unknown)
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 14) {
                    AskRecoverySymbol(presentation: presentation, size: 38)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L(presentation.unknown && model.selected?.run?.status == "cancelled"
                                ? "ask.recovery.stopped" : presentation.titleKey))
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(StudioTheme.textPrimary)
                        Text(L(presentation.bodyKey))
                            .font(.system(size: 12.5))
                            .foregroundStyle(StudioTheme.textSecondary)
                            .lineSpacing(3)
                    }
                    .fixedSize(horizontal: false, vertical: true)
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
                    .padding(.leading, 52)
                }
                if !timeline.items.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(timeline.items.enumerated()), id: \.offset) { _, item in
                            AskRecoveryTimelineRow(item: item, unknown: presentation.unknown)
                        }
                    }
                }
                if !options.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L("ask.recovery.inspect"))
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(StudioTheme.textTertiary)
                        ForEach(options, id: \.self) { option in
                            AskRecoveryOptionCard(action: option, bodyKey: option.optionBodyKey(active: presentation.active),
                                                  recommended: option == options.first,
                                                  selected: option == selected) { choice = option }
                        }
                    }
                    .accessibilityElement(children: .contain)
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 22)
            .padding(.bottom, 16)
            Rectangle().fill(AskTheme.separator).frame(height: 1)
            footer
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

    /// Always trailing: Return, then the chosen option's own button, red for Stop.
    private var footer: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            if model.recoveryWorking {
                ProgressView().controlSize(.small).accessibilityLabel(L("ask.working"))
            }
            if selected != .selfCheck {
                Button(L("ask.recovery.close"), action: model.dismissRecoveryInspector)
                    .buttonStyle(AskCapsuleButtonStyle(kind: selected == nil ? .primary : .secondary))
                    .keyboardShortcut(.cancelAction)
            }
            if let selected {
                Button(L(selected.titleKey)) { model.performRecovery(selected) }
                    .buttonStyle(AskCapsuleButtonStyle(kind: selected.isDestructive ? .destructive : .primary))
            }
        }
        .disabled(model.recoveryWorking)
        .padding(.horizontal, 22)
        .padding(.top, 14)
        .padding(.bottom, 18)
    }
}

private struct AskRecoveryTimelineRow: View {
    let item: AskRecoveryTimeline.Item
    let unknown: Bool

    var body: some View {
        HStack(spacing: 10) {
            dot
            Text(item.title)
                .font(.system(size: 12.5, weight: item.state == .current ? .semibold : .regular))
                .foregroundStyle(item.state == .upcoming ? StudioTheme.textTertiary
                    : (item.state == .current ? StudioTheme.textPrimary : StudioTheme.textSecondary))
                .lineLimit(2)
            Spacer(minLength: 8)
            if let detail = item.detail {
                Text(detail).font(.system(size: 11.5)).foregroundStyle(StudioTheme.textTertiary)
            }
        }
    }

    @ViewBuilder private var dot: some View {
        switch item.state {
        case .done:
            Image(systemName: "checkmark").font(.system(size: 8, weight: .bold))
                .foregroundStyle(StudioTheme.success)
                .frame(width: 16, height: 16).background(AskTheme.successSoft, in: Circle())
        case .current:
            Image(systemName: unknown ? "questionmark" : "pause.fill").font(.system(size: 8, weight: .bold))
                .foregroundStyle(StudioTheme.warning)
                .frame(width: 16, height: 16).background(AskTheme.warningSoft, in: Circle())
                .overlay(Circle().strokeBorder(StudioTheme.warning.opacity(0.32)))
        case .upcoming:
            Circle().strokeBorder(AskTheme.border, lineWidth: 1.5).frame(width: 16, height: 16)
        }
    }
}

/// One radio choice: what happens, and what it costs.
private struct AskRecoveryOptionCard: View {
    let action: AskRecoveryAction
    let bodyKey: String
    let recommended: Bool
    let selected: Bool
    let choose: () -> Void

    private var tint: Color { action.isDestructive ? StudioTheme.danger : AskTheme.accent }

    var body: some View {
        Button(action: choose) {
            HStack(alignment: .top, spacing: 12) {
                Circle()
                    .strokeBorder(selected ? tint : AskTheme.border, lineWidth: selected ? 5 : 1.5)
                    .frame(width: 16, height: 16)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(L(action.optionTitleKey))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(StudioTheme.textPrimary)
                        if recommended {
                            Text(L("ask.recovery.recommended"))
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(AskTheme.accent, in: RoundedRectangle(cornerRadius: 5))
                        }
                    }
                    Text(L(bodyKey))
                        .font(.system(size: 12))
                        .foregroundStyle(StudioTheme.textTertiary)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(selected ? (action.isDestructive ? AskTheme.dangerSoft : AskTheme.accentSoft) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(selected ? tint : AskTheme.border))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
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
