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

        var isDiff: Bool { if case .diff = self { true } else { false } }
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
        case ("project_terminal", _): return .content(call.function.arguments)
        case ("files", "edit"), ("project_files", "edit"):
            return .diff(removed: args["old_text"] as? String ?? "", added: args["new_text"] as? String ?? "")
        case ("files", "write"), ("project_files", "write"):
            return (args["content"] as? String).map { .content(clip($0)) } ?? .none
        case ("run_code", _):
            return (args["code"] as? String).map { .content(clip($0)) } ?? .none
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

/// An approval is a message in the conversation, not a sheet over it: the
/// transcript above stays readable while the user decides. It asks one
/// question, gives the model's reason and a few facts, and keeps the content,
/// tool name and raw arguments one click away.
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
    var onDeny: () -> Void
    var onAllowForConversation: () -> Void = {}
    var onAllow: () -> Void
    var initiallyShowsDetails = false
    @State private var showsTechnical: Bool?
    private var detailsOpen: Bool { showsTechnical ?? initiallyShowsDetails }
    private var isImage: Bool { AskImageCardState.isImageTool(call.function.name) }
    @State private var showsPreview: Bool?
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

    /// Keep file changes visible and ordinary command previews one click away.
    static func previewStartsExpanded(_ preview: AskApprovalPresentation.Preview, call: AskToolCall) -> Bool {
        switch preview {
        case .diff: true
        case .content: ["project_terminal", "command_job"].contains(call.function.name)
        case .none: false
        }
    }

    static func previewTitle(_ call: AskToolCall) -> String {
        switch call.function.name {
        case "run_command", "command_job", "project_terminal": L("ask.approval.preview.command")
        case "run_code": L("ask.approval.preview.code")
        case "files", "project_files":
            AskApprovalPresentation.preview(call).isDiff ? L("ask.approval.preview.diff") : L("ask.approval.preview.file")
        case AskNotebookTool.name:
            AskApprovalPresentation.preview(call).isDiff ? L("ask.approval.preview.diff") : L("ask.approval.preview.content")
        default: L("ask.approval.preview.content")
        }
    }

    private var tone: AskToolRisk { AskApprovalCopy.tone(call, risk: risk) }
    private var tint: Color { Self.panelTint(tone) }
    private var irreversible: Bool { tone == .destructive }
    private var previewValue: AskApprovalPresentation.Preview { AskApprovalPresentation.preview(call) }
    private var previewOpen: Bool { showsPreview ?? (irreversible || Self.previewStartsExpanded(previewValue, call: call)) }
    private var conversationScope: Bool {
        canAllowForConversation && (scopeChoice ?? Self.primaryIsConversation(risk: risk,
                                                                             canAllowForConversation: canAllowForConversation))
    }

    private static let inset: CGFloat = 36

    var body: some View {
        let decision = AskApprovalCopy.decision(call, boundPath: boundPath)
        VStack(alignment: .leading, spacing: 10) {
            header(decision)
            let facts = AskApprovalCopy.facts(call, risk: risk, targetSummary: targetSummary,
                                              boundPath: boundPath, workingDirectory: workingDirectory)
            if !facts.isEmpty {
                AskFlowLayout(spacing: 8) {
                    ForEach(facts, id: \.self) { AskApprovalFactLabel(fact: $0) }
                }
                .padding(.leading, Self.inset)
            }
            if let disclosure = AskApprovalPresentation.disclosure(call) {
                Text(disclosure).font(.system(size: 11.5)).foregroundStyle(StudioTheme.textSecondary)
                    .padding(.leading, Self.inset)
            }
            if irreversible {
                Text(L("ask.approval.everyTime")).font(.system(size: 11.5)).foregroundStyle(StudioTheme.textTertiary)
                    .padding(.leading, Self.inset)
            }
            if previewOpen { preview }
            if detailsOpen { technicalContent }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) {
                    disclosures.fixedSize()
                    Spacer(minLength: 0)
                    actions(decision).fixedSize()
                }
                VStack(alignment: .leading, spacing: 10) {
                    disclosures
                    actions(decision).frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .padding(.top, 4)
        }
        .padding(16)
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

    private func header(_ decision: AskApprovalCopy.Decision?) -> some View {
        let explanation = AskApprovalCopy.reason(reason) ?? AskApprovalCopy.reason(AskApprovalCopy.imagePrompt(call))
        let commandTitle = decision == .run ? explanation.flatMap { $0.count <= 32 ? $0 : nil } : nil
        let title = commandTitle ?? AskApprovalCopy.title(call, decision: decision, mcpServer: mcpServer)
        let symbol = switch decision {
        case .run: "terminal"
        case .create, .overwrite, .edit: "doc"
        case nil: AskPresentation.toolSymbol(call)
        }
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 26, height: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(StudioTheme.textPrimary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .fixedSize(horizontal: false, vertical: true)
                if let explanation, commandTitle == nil {
                    Text(explanation).font(.system(size: 12.5)).foregroundStyle(StudioTheme.textSecondary)
                        .lineLimit(3)
                        .lineSpacing(1.5)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                } else if explanation == nil, decision == .run, !previewOpen,
                          case let .content(command) = previewValue {
                    Text(command)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(StudioTheme.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var disclosures: some View {
        HStack(spacing: 14) {
            if previewValue != .none {
                AskApprovalDisclosure(title: Self.previewTitle(call), open: previewOpen) {
                    showsPreview = !previewOpen
                }
            }
            AskApprovalDisclosure(title: L(isImage ? "ask.approval.image.details" : "ask.approval.arguments"),
                                  open: detailsOpen) { showsTechnical = !detailsOpen }
                .accessibilityIdentifier("ask.approval.details.toggle")
        }
    }

    @ViewBuilder private var technicalContent: some View {
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
            AskMonoBlock(title: AskToolPolicy.action(call), text: call.function.arguments)
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

/// A chevron and a label that fold a section of the approval.
private struct AskApprovalDisclosure: View {
    let title: String
    let open: Bool
    var quiet = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                    .rotationEffect(.degrees(open ? 90 : 0))
                Text(title).font(.system(size: quiet ? 11.5 : 12))
            }
            .foregroundStyle(quiet ? StudioTheme.textTertiary : StudioTheme.textSecondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(L(open ? "ask.activity.expanded" : "ask.activity.collapsed"))
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
                .lineLimit(1).truncationMode(.middle)
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
