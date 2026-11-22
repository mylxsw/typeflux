import AppKit
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
        if AskImageCardState.isImageTool(call.function.name) { return .none }
        let args = (try? AskLocalTools.jsonArguments(call.function.arguments)) ?? [:]
        if call.function.name == AskNotebookTool.name { return notebookPreview(call, args: args) }
        switch (call.function.name, args["action"] as? String ?? "") {
        case ("project_terminal", "start"):
            if let request = try? AskLocalTools.launchRequest(args),
               let text = try? AskLocalTools.terminalJSON(request) {
                return .content(text)
            }
            return .content(call.function.arguments)
        case ("project_terminal", "input"): return (args["text"] as? String).map { .content($0) } ?? .content(call.function.arguments)
        case ("project_terminal", _): return .content(call.function.arguments)
        case ("generate_image", _): return (args["prompt"] as? String).map { .content($0) } ?? .none
        case ("files", "edit"), ("project_files", "edit"):
            return .diff(removed: args["old_text"] as? String ?? "", added: args["new_text"] as? String ?? "")
        case ("files", "write"), ("project_files", "write"):
            return (args["content"] as? String).map { .content($0) } ?? .none
        case ("run_code", _):
            return (args["code"] as? String).map { .content($0) } ?? .none
        case ("command_job", "start"):
            guard let request = try? AskCommandJobRequest.validated(args) else { return .none }
            return .content(request.command + "\n\n" + L("ask.commandJob.deadline", request.timeout) + "\n" + L("ask.commandJob.lifetime"))
        case ("command_job", _): return .none
        case ("run_command", _):
            return (args["command"] as? String).map { .content($0) } ?? .none
        case ("computer", "type"), ("browser", "fill"), (AskEmbeddedBrowserTool.name, "fill"):
            return (args["text"] as? String ?? args["value"] as? String).map { .content(clip($0)) } ?? .none
        case ("memory", "remember"):
            return (args["text"] as? String).map { .content(clip($0)) } ?? .none
        default:
            return AskLocalTools.builtinRisk(call) >= .write ? .content(clip(call.function.arguments)) : .none
        }
    }

    private static func notebookPreview(_ call: AskToolCall, args: [String: Any]) -> Preview {
        switch args["action"] as? String ?? "" {
        case "update" where args["find"] != nil:
            return .diff(removed: args["find"] as? String ?? "", added: args["replace"] as? String ?? "")
        case "create", "append", "update":
            let title = (args["title"] as? String).map { "# " + $0 + "\n\n" } ?? ""
            return .content(clip(title + (args["body"] as? String ?? "")))
        default:
            return AskLocalTools.builtinRisk(call) >= .write ? .content(clip(call.function.arguments)) : .none
        }
    }

    /// The full path for file calls, which the row title shortens to a name.
    static func detail(_ call: AskToolCall) -> String? {
        guard ["files", "project_files"].contains(call.function.name),
              let path = (try? AskLocalTools.jsonArguments(call.function.arguments))?["path"] as? String,
              !path.isEmpty else { return nil }
        return path
    }

    static func disclosure(_ call: AskToolCall) -> String? {
        switch call.function.name {
        case AskNotebookTool.name: L("ask.notes.agent.hint")
        default: nil
        }
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

/// Shows the proposed action and keeps both decision buttons outside the scrollable review.
struct AskApprovalCard: View {
    let call: AskToolCall
    let risk: AskToolRisk
    var mcpServer: String?
    var targetSummary: String?
    var boundPath: String?
    var workingDirectory: String?
    /// The model's narration before the call: why it wants this step.
    var reason: String?
    var canAllowForConversation = false
    /// Inside its tool card rather than on its own after the transcript.
    var embedded = false
    var reviewHeight: CGFloat = 360
    var onDeny: () -> Void
    var onAllowForConversation: () -> Void = {}
    var onAllow: () -> Void
    var initiallyShowsDetails = false
    @State private var showsTechnical: Bool?
    private var detailsOpen: Bool { showsTechnical ?? initiallyShowsDetails }
    private var isImage: Bool { AskImageCardState.isImageTool(call.function.name) }
    @State private var scopeChoice: Bool?
    @State private var choosingScope = false

    /// The panel's tint: blue reads, amber changes, red cannot be undone.
    static func panelTint(_ risk: AskToolRisk) -> Color {
        switch risk {
        case .destructive: StudioTheme.danger
        case .write: StudioTheme.warning
        case .none, .read: AskTheme.accent
        }
    }

    /// Which scope the allow button starts with, as on the design board: allowing
    /// for the conversation when offered, else allowing once. A destructive step
    /// never makes "allow for the conversation" the prominent choice.
    static func primaryIsConversation(risk: AskToolRisk, canAllowForConversation: Bool) -> Bool {
        canAllowForConversation && risk != .destructive
    }

    private var tone: AskToolRisk { AskApprovalCopy.tone(call, risk: risk) }
    private var tint: Color { Self.panelTint(tone) }
    private var irreversible: Bool { tone == .destructive }
    private var conversationScope: Bool {
        canAllowForConversation && (scopeChoice ?? Self.primaryIsConversation(risk: risk,
                                                                             canAllowForConversation: canAllowForConversation))
    }

    var body: some View {
        let decision = AskApprovalCopy.decision(call, boundPath: boundPath)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: decision == .run ? "terminal" : AskPresentation.toolSymbol(call))
                    .foregroundStyle(tint).accessibilityHidden(true)
                Text(AskApprovalCopy.title(call, decision: decision, mcpServer: mcpServer))
                    .font(.system(size: 14, weight: .semibold)).lineLimit(2)
                Spacer(minLength: 4)
                Button { showsTechnical = !detailsOpen } label: {
                    HStack(spacing: 4) {
                        Text(L("ask.approval.command.details"))
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                            .rotationEffect(.degrees(detailsOpen ? 90 : 0))
                    }
                }
                .fixedSize().buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(StudioTheme.textSecondary)
                .accessibilityLabel(L("ask.approval.command.details"))
                .accessibilityValue(L(detailsOpen ? "ask.activity.expanded" : "ask.activity.collapsed"))
                .accessibilityIdentifier("ask.approval.details.toggle")
            }
            ViewThatFits(in: .vertical) {
                review(decision).fixedSize(horizontal: false, vertical: true)
                ScrollView { review(decision) }
            }
            .frame(maxHeight: reviewHeight).fixedSize(horizontal: false, vertical: true)
            actions(decision).frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(embedded ? Color.clear : AskTheme.raisedSurface)
        .clipShape(RoundedRectangle(cornerRadius: embedded ? 10 : 12, style: .continuous))
        .overlay {
            if !embedded {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(irreversible ? tint.opacity(0.45) : AskTheme.border)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func review(_ decision: AskApprovalCopy.Decision?) -> some View {
        let facts = AskApprovalCopy.facts(call, risk: risk, targetSummary: targetSummary,
                                          boundPath: boundPath, workingDirectory: workingDirectory)
        return VStack(alignment: .leading, spacing: 8) {
            if let explanation = AskApprovalCopy.reason(reason), decision != .run || detailsOpen {
                Text(explanation).font(.system(size: 12)).foregroundStyle(StudioTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            let visibleFacts = facts.filter { decision != .run || $0.warning }
            if !visibleFacts.isEmpty {
                let labels = ForEach(visibleFacts, id: \.self) { AskApprovalFactLabel(fact: $0) }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { labels }.fixedSize(horizontal: true, vertical: false)
                    VStack(alignment: .leading, spacing: 4) { labels }
                }
            }
            if let disclosure = AskApprovalPresentation.disclosure(call) {
                Text(disclosure).font(.system(size: 11.5)).foregroundStyle(StudioTheme.textSecondary)
            }
            if irreversible {
                Text(L("ask.approval.everyTime")).font(.system(size: 11.5)).foregroundStyle(StudioTheme.textSecondary)
            }
            preview
            if detailsOpen {
                Divider()
                technicalContent(decision)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func technicalContent(_ decision: AskApprovalCopy.Decision?) -> some View {
        if isImage {
            ScrollView {
                Text(AskApprovalCopy.imagePrompt(call) ?? L("ask.approval.image.noPrompt"))
                    .font(.system(size: 12.5)).lineSpacing(4)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(12)
            }
            .frame(height: 240)
            .background(AskTheme.hoverFill, in: RoundedRectangle(cornerRadius: 8))
            .accessibilityIdentifier("ask.approval.details.content")
            Button(L("ask.approval.image.copyArguments")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(call.function.arguments, forType: .string)
            }
            .buttonStyle(.plain).font(.system(size: 11.5))
            .foregroundStyle(StudioTheme.textSecondary)
        } else {
            AskApprovalDetails(call: call, hostAccount: decision == .run, workingDirectory: workingDirectory)
        }
    }

    private func actions(_ decision: AskApprovalCopy.Decision?) -> some View {
        HStack(spacing: 8) {
            Button(action: onDeny) { Text(L("ask.deny")) }
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)
                .help(L("ask.approval.denyHelp"))
            allowButton(decision)
            // An irreversible step is approved one call at a time.
            if canAllowForConversation, !irreversible {
                Button { choosingScope.toggle() } label: {
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.bordered)
                .help(L("ask.approval.scope"))
                .accessibilityLabel(L("ask.approval.scope"))
                .popover(isPresented: $choosingScope, arrowEdge: .bottom) { scopeMenu }
            }
        }
    }

    @ViewBuilder private func allowButton(_ decision: AskApprovalCopy.Decision?) -> some View {
        if irreversible {
            // No shortcut: an irreversible step is never one keystroke away.
            Button(action: onAllow) { Text(L("ask.approval.allowDestructive")) }
                .buttonStyle(.borderedProminent)
                .tint(StudioTheme.danger)
        } else {
            Button(action: conversationScope ? onAllowForConversation : onAllow) {
                Text(conversationScope ? L("ask.approval.allowExact") : decision?.allowLabel ?? L("ask.allow"))
            }
            .buttonStyle(.borderedProminent)
            .tint(AskTheme.accent)
            .keyboardShortcut(.return, modifiers: .command)
            .help(L(conversationScope ? "ask.approval.exactScope" : "ask.approval.allowHelp"))
        }
    }

    private var scopeMenu: some View {
        VStack(alignment: .leading, spacing: 2) {
            scopeOption(conversation: false, title: L("ask.approval.scopeOnce"), detail: L("ask.approval.singleUse"))
            scopeOption(conversation: true, title: L("ask.approval.allowExact"), detail: L("ask.approval.exactScope"))
        }
        .padding(6)
        .frame(width: 280)
    }

    private func scopeOption(conversation: Bool, title: String, detail: String) -> some View {
        Button {
            scopeChoice = conversation
            choosingScope = false
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AskTheme.accentText)
                    .opacity(conversationScope == conversation ? 1 : 0)
                    .frame(width: 14)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 12.5, weight: .medium)).foregroundStyle(StudioTheme.textPrimary)
                    Text(detail).font(.system(size: 11.5)).foregroundStyle(StudioTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var preview: some View {
        if call.function.name == "project_terminal",
           let args = try? AskLocalTools.jsonArguments(call.function.arguments),
           args["action"] as? String == "start", let request = try? AskLocalTools.launchRequest(args) {
            let arguments = request.arguments.map { String(reflecting: $0) }
            source(([String(reflecting: request.script)] + arguments).joined(separator: " "), language: .plain)
            if detailsOpen, case let .content(configuration) = AskApprovalPresentation.preview(call) {
                source(configuration, language: .json)
            }
        } else {
            preview(AskApprovalPresentation.preview(call))
        }
    }

    @ViewBuilder private func preview(_ value: AskApprovalPresentation.Preview) -> some View {
        switch value {
        case let .diff(removed, added):
            let diff = VStack(alignment: .leading, spacing: 0) {
                diffLines(removed, prefix: "-", color: StudioTheme.danger)
                diffLines(added, prefix: "+", color: StudioTheme.success)
            }
            ViewThatFits(in: .vertical) {
                diff.fixedSize(horizontal: false, vertical: true)
                ScrollView { diff }
            }
            .frame(maxHeight: 130).fixedSize(horizontal: false, vertical: true)
            .clipShape(RoundedRectangle(cornerRadius: 7))
        case let .content(text):
            if !detailsOpen || text != call.function.arguments {
                source(text, language: call.function.name == "run_command" ? .shell : .plain)
            }
        case .none:
            EmptyView()
        }
    }

    private func source(_ text: String, language: AskWorkflowSyntaxHighlighter.Language) -> some View {
        AskApprovalSource(source: text, language: language, height: detailsOpen ? 72 : 110)
            .padding(.horizontal, 11).padding(.vertical, 8)
            .background(AskTheme.monoSurface, in: RoundedRectangle(cornerRadius: 7))
    }

    private func diffLines(_ text: String, prefix: String, color: Color) -> some View {
        Text(text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { prefix + " " + $0 }.joined(separator: "\n"))
            .font(.system(size: 11.5, design: .monospaced))
            .foregroundStyle(color)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(color.opacity(0.08))
    }
}

/// One fact about the effect: where, how much, whether it can be undone.
struct AskApprovalFactLabel: View {
    let fact: AskApprovalCopy.Fact

    var body: some View {
        let label = HStack(spacing: 5) {
            Image(systemName: fact.symbol).font(.system(size: 10))
                .foregroundStyle(fact.warning ? StudioTheme.danger : StudioTheme.textTertiary)
            Text(fact.text).font(.system(size: 12, design: fact.symbol == "folder" ? .monospaced : .default))
                .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 11.5))
        .foregroundStyle(fact.warning ? StudioTheme.danger : StudioTheme.textSecondary)

        if let path = fact.revealPath {
            Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) } label: { label }
                .buttonStyle(.plain)
                .help(L("ask.approval.reveal", path))
        } else {
            label
        }
    }
}
