import SwiftUI

struct AskRecoveryPresentation: Equatable {
    var unknown: Bool
    var otherDevice: Bool
    var active: Bool
    var savedReceipts: Int
    var local: Bool

    init(run: AskRun?, entries: [AskExecutionEntry], deviceId: String, local: Bool) {
        unknown = run?.needsRecoveryInspection == true || entries.contains { $0.unknown || $0.audit == nil }
        otherDevice = run.map { $0.deviceId != deviceId } ?? false
        active = run?.isActive == true
        savedReceipts = entries.filter { $0.receipt != nil && !$0.acknowledged }.count
        self.local = local
    }

    var titleKey: String {
        if unknown {
            return "ask.recovery.unknown"
        }
        if savedReceipts > 0 {
            return "ask.recovery.saved"
        }
        return "ask.recovery.history"
    }

    var bodyKey: String {
        if otherDevice && active {
            return "ask.recovery.binding"
        }
        if unknown {
            return "ask.recovery.unknownBody"
        }
        if savedReceipts > 0 {
            return "ask.recovery.savedBody"
        }
        return active ? "ask.recovery.activeBody" : "ask.recovery.historyBody"
    }
}

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
        VStack(alignment: .leading, spacing: 10) {
            Label(
                L(presentation.titleKey),
                systemImage: presentation.unknown ? "questionmark.circle" : "clock.arrow.circlepath"
            )
            .font(.system(size: 13, weight: .semibold))
            Text(L(presentation.bodyKey)).font(.system(size: 12))
            if presentation
                .local {
                Text(L("ask.recovery.localBody")).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            if presentation
                .active {
                Text(L("ask.recovery.steering")).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            HStack {
                Button(L("ask.recovery.inspect"), action: inspect)
                if canRetransmit {
                    Button(L("ask.recovery.retransmit"), action: retransmit)
                }
                if canContinue {
                    Button(L("ask.recovery.continue"), action: continueRun)
                }
            }.buttonStyle(.bordered).disabled(working)
        }
        .foregroundStyle(StudioTheme.textPrimary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(AskTheme.hoverFill, in: RoundedRectangle(cornerRadius: 14))
    }
}

struct AskRecoveryInspector: View {
    @ObservedObject var model: AskConversationModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L("ask.recovery.inspect")).font(.headline)
            Text(L("ask.recovery.unknownBody")).font(.body)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(model.selectedRecoveryEntries) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L(entry.unknown ? "ask.recovery.unknown" : "ask.recovery.recorded"))
                                .fontWeight(.medium)
                            if let audit = entry.audit, let diagnostic = entry.diagnostic {
                                if let name = audit.toolName {
                                    Text(name).fontWeight(.semibold)
                                }
                                if let receipt = entry.receipt {
                                    switch receipt {
                                    case let .tool(result): Text(String(result.content.prefix(4000)))
                                    case let .inference(result): Text(String(result.content.prefix(4000)))
                                    }
                                }
                                Text(
                                    "\(diagnostic.runId) / \(diagnostic.stepId) / \(diagnostic.callId) / \(diagnostic.operationId)"
                                )
                                Text("\(audit.toolVersion.prefix(80)) · \(audit.argumentsHash.prefix(80))")
                                Text(L(audit
                                        .approvalId == nil ? "ask.recovery.noApproval" :
                                        "ask.recovery.approvalRecorded"))
                                Text("\(diagnostic.status) · \(audit.events.map(\.rawValue).joined(separator: " → "))")
                            } else {
                                Text(L("ask.recovery.binding"))
                            }
                        }.font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    }
                    if model.selectedRecoveryEntries.isEmpty {
                        Text(L("ask.recovery.remoteEvidence"))
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 260)
            HStack {
                Button(L("ask.recovery.close")) { model.inspectingRecovery = false }
                Spacer()
                if model.selected?.run?.isActive == true {
                    Button(L("ask.recovery.end")) { Task { await model.endRecoveryRun() } }
                } else {
                    Button(L("ask.recovery.newRequest")) { model.prepareRecoveryRequest() }
                }
            }.disabled(model.recoveryWorking)
        }.padding(24).frame(width: 580)
    }
}
