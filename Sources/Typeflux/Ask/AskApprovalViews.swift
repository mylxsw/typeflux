import SwiftUI

/// What an approval shows: what the call will do, to what, and how risky it is.
enum AskApprovalPresentation {
    enum Preview: Equatable {
        /// A text replacement in a file.
        case diff(removed: String, added: String)
        /// New content: a written file or code to run.
        case content(String)
        case none
    }

    static func preview(_ call: AskToolCall) -> Preview {
        let args = (try? AskLocalTools.jsonArguments(call.function.arguments)) ?? [:]
        switch (call.function.name, args["action"] as? String ?? "") {
        case ("files", "edit"):
            return .diff(removed: args["old_text"] as? String ?? "", added: args["new_text"] as? String ?? "")
        case ("files", "write"):
            return (args["content"] as? String).map { .content(clip($0)) } ?? .none
        case ("run_code", _):
            return (args["code"] as? String).map { .content(clip($0)) } ?? .none
        case ("computer", "type"), ("browser", "fill"):
            return (args["text"] as? String ?? args["value"] as? String).map { .content(clip($0)) } ?? .none
        case ("memory", "remember"):
            return (args["text"] as? String).map { .content(clip($0)) } ?? .none
        default:
            return .none
        }
    }

    /// The full path for file calls, which the row title shortens to a name.
    static func detail(_ call: AskToolCall) -> String? {
        guard call.function.name == "files",
              let path = (try? AskLocalTools.jsonArguments(call.function.arguments))?["path"] as? String,
              !path.isEmpty else { return nil }
        return path
    }

    static func riskLabel(_ risk: AskToolRisk) -> String {
        switch risk {
        case .none, .read: L("ask.approval.risk.read")
        case .write: L("ask.approval.risk.write")
        case .destructive: L("ask.approval.risk.destructive")
        }
    }

    static func riskState(_ risk: AskToolRisk) -> AskActivityState {
        risk == .destructive ? .failed : (risk == .write ? .attention : .running)
    }

    static func clip(_ text: String, limit: Int = 1200) -> String {
        text.count > limit ? String(text.prefix(limit)) + "\n…" : text
    }
}

/// An approval is a message in the conversation, not a sheet over it: the
/// transcript above stays readable while the user decides.
struct AskApprovalCard: View {
    let call: AskToolCall
    let risk: AskToolRisk
    var mcpServer: String?
    var canAllowForConversation = false
    /// Inside its tool card rather than on its own after the transcript.
    var embedded = false
    var onDeny: () -> Void
    var onAllowForConversation: () -> Void = {}
    var onAllow: () -> Void
    @State private var showsArguments = false

    /// The panel's tint: the accent, except red for destructive steps.
    static func panelTint(_ risk: AskToolRisk) -> Color { risk == .destructive ? StudioTheme.danger : AskTheme.accent }

    /// Which button carries the primary style, as on the design board: allowing
    /// for the conversation when offered, else allowing once. A destructive step
    /// never makes "allow for the conversation" the prominent choice.
    static func primaryIsConversation(risk: AskToolRisk, canAllowForConversation: Bool) -> Bool {
        canAllowForConversation && risk != .destructive
    }

    private var tint: Color { Self.panelTint(risk) }
    private var riskTint: Color { AskApprovalPresentation.riskState(risk).tint }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "checkmark.shield").font(.system(size: 15, weight: .medium))
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Image(systemName: AskPresentation.toolSymbol(call)).font(.system(size: 12))
                            .foregroundStyle(StudioTheme.textSecondary)
                        Text(AskTheme.toolTitle(call, mcpServer: mcpServer))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(StudioTheme.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(AskApprovalPresentation.riskLabel(risk))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(riskTint)
                            .padding(.horizontal, 7)
                            .frame(height: 18)
                            .background(riskTint.opacity(0.16), in: Capsule())
                            .fixedSize()
                    }
                    if let detail = AskApprovalPresentation.detail(call) {
                        Text(detail).font(.system(size: 12)).foregroundStyle(StudioTheme.textSecondary)
                            .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    }
                }
                Spacer(minLength: 0)
            }
            preview
            if risk == .destructive {
                Text(L("ask.approval.destructiveHint")).font(.system(size: 11.5)).foregroundStyle(StudioTheme.textSecondary)
            }
            HStack(spacing: 8) {
                Button { showsArguments.toggle() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: showsArguments ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold))
                        Text(L("ask.approval.arguments")).font(.system(size: 11.5))
                    }
                    .foregroundStyle(StudioTheme.textTertiary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer(minLength: 8)
                let conversationFirst = Self.primaryIsConversation(risk: risk,
                                                                   canAllowForConversation: canAllowForConversation)
                Button(action: onDeny) { Text(L("ask.deny")) }
                    .buttonStyle(AskCapsuleButtonStyle(kind: .secondary))
                    .keyboardShortcut(.cancelAction)
                    .help(L("ask.approval.denyHelp"))
                Button(action: onAllow) { Text(L(risk == .destructive ? "ask.approval.allowDestructive" : "ask.allowOnce")) }
                    .buttonStyle(AskCapsuleButtonStyle(kind: risk == .destructive ? .destructive
                        : (conversationFirst ? .secondary : .primary)))
                    .keyboardShortcut(.return, modifiers: .command)
                    .help(L("ask.approval.allowHelp"))
                if canAllowForConversation {
                    Button(action: onAllowForConversation) { Text(L("ask.allowConversation")) }
                        .buttonStyle(AskCapsuleButtonStyle(kind: conversationFirst ? .primary : .secondary))
                        .help(L("ask.allowConversation.help"))
                }
            }
            if showsArguments {
                AskMonoBlock(title: L("ask.tool.arguments"), text: call.function.arguments)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(tint.opacity(0.3), lineWidth: 0.5))
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var preview: some View {
        switch AskApprovalPresentation.preview(call) {
        case let .diff(removed, added):
            VStack(alignment: .leading, spacing: 0) {
                diffLines(removed, prefix: "-", color: StudioTheme.danger)
                diffLines(added, prefix: "+", color: StudioTheme.success)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(AskTheme.separator))
        case let .content(text):
            Text(text)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(StudioTheme.textSecondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(AskTheme.monoSurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        case .none:
            EmptyView()
        }
    }

    private func diffLines(_ text: String, prefix: String, color: Color) -> some View {
        Text(AskApprovalPresentation.clip(text).split(separator: "\n", omittingEmptySubsequences: false)
            .map { prefix + " " + $0 }.joined(separator: "\n"))
            .font(.system(size: 11.5, design: .monospaced))
            .foregroundStyle(color)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(color.opacity(0.08))
    }
}
