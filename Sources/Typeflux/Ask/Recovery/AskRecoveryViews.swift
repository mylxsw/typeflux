import SwiftUI

/// The same card is used in the transcript and screenshot fixtures.
struct AskRecoveryCard: View {
    let presentation: AskRecoveryPresentation
    var canRetransmit = false
    var canContinue = false
    var working = false
    var inspect: () -> Void = {}
    var retransmit: () -> Void = {}
    var continueRun: () -> Void = {}

    var body: some View {
        if presentation.isVisible {
            VStack(alignment: .leading, spacing: 10) {
                Label(
                    L(presentation.titleKey),
                    systemImage: presentation.unknown ? "questionmark.circle" :
                        (presentation.savedReceipts > 0 ? "arrow.triangle.2.circlepath" : "pause.circle")
                )
                .font(.system(size: 13, weight: .semibold))
                Text(L(presentation.bodyKey)).font(.system(size: 12))
                if presentation.unknown || canRetransmit || canContinue {
                    HStack {
                        if presentation.unknown {
                            Button(L("ask.recovery.inspect"), action: inspect)
                        }
                        if canRetransmit {
                            Button(L("ask.recovery.retransmit"), action: retransmit)
                        }
                        if canContinue {
                            Button(L("ask.recovery.continue"), action: continueRun)
                        }
                    }.buttonStyle(.bordered).disabled(working)
                }
            }
            .foregroundStyle(StudioTheme.textPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(AskTheme.hoverFill, in: RoundedRectangle(cornerRadius: 14))
        }
    }
}

struct AskRecoveryInspector: View {
    @ObservedObject var model: AskConversationModel

    var body: some View {
        let presentation = model.recoveryPresentation
        VStack(alignment: .leading, spacing: 16) {
            Text(L(presentation.titleKey)).font(.headline)
            Text(L(presentation.bodyKey)).font(.body)
            if presentation.unknown {
                Text(L("ask.recovery.checkBody")).font(.body)
                Text(L(presentation.active ? "ask.recovery.endBody" : "ask.recovery.newRequestBody"))
                    .font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Button(L("ask.recovery.close")) { model.inspectingRecovery = false }
                Spacer()
                if presentation.active {
                    Button(L("ask.recovery.end")) { Task { await model.endRecoveryRun() } }
                } else {
                    Button(L("ask.recovery.newRequest")) { model.prepareRecoveryRequest() }
                }
            }.disabled(model.recoveryWorking)
        }
        .foregroundStyle(StudioTheme.textPrimary)
        .fixedSize(horizontal: false, vertical: true)
        .padding(24).frame(width: 500, alignment: .leading)
    }
}
