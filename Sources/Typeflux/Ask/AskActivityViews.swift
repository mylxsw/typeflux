import AppKit
import SwiftUI

/// One run's tool steps as a single quiet line above the answer, like the
/// reasoning line: what it did, unfolded on demand into its steps. Only a step
/// waiting for a decision keeps a card, because it needs the user.
struct AskActivityBlock: View {
    static let corner: CGFloat = 18
    static let lineHeight: CGFloat = 26

    let group: AskActivityGroup
    let results: [AskMessage]
    let plan: [AskPlanItem]?
    let status: AskActivity.Status
    var streamingId: String?
    var approvalToolId: String?
    var outputs = AskRunOutputs()
    /// The approval for one of this card's steps, shown under its header.
    var approval: AnyView?
    var exportProjectPatch: ((AskWorkspaceRef) throws -> Data)?
    /// Overrides the default fold until the user toggles it.
    var startsExpanded: Bool?
    @State private var userExpanded: Bool?
    @State private var hovering = false

    /// Folded by default, even while working: the line itself names the step under way.
    private var expanded: Bool { userExpanded ?? startsExpanded ?? (status == .attention) }

    private var title: String { AskActivity.title(group, status: status, plan: plan, results: results) }

    /// The thinking before the first step, shown above the card like an
    /// answer's reasoning rather than folded inside it.
    private var leadReasoning: AskMessage? {
        guard let lead = group.messages.first, let reasoning = lead.reasoning, !reasoning.isEmpty else { return nil }
        return lead
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let lead = leadReasoning {
                AskReasoningView(text: lead.reasoning ?? "", milliseconds: lead.reasoningMilliseconds ?? 0,
                                 active: streamingId == lead.id && (lead.toolCalls ?? []).isEmpty)
            }
            if status == .attention { card } else { trace }
            if !outputs.isEmpty { AskRunOutputsView(outputs: outputs).padding(.top, 4) }
        }
    }

    private func toggle() {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) { userExpanded = !expanded }
    }

    // MARK: Quiet line

    private var trace: some View {
        VStack(alignment: .leading, spacing: 6) {
            traceLine
            if expanded {
                content
                    .padding(.leading, 12)
                    .overlay(alignment: .leading) { Rectangle().fill(AskTheme.border).frame(width: 2) }
                    .padding(.bottom, 4)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private var traceLine: some View {
        let failures = AskActivity.failures(group, results: results)
        let running = status == .running
        return Button(action: toggle) {
            HStack(spacing: 6) {
                if running {
                    ProgressView().controlSize(.mini).frame(width: 14, height: 14)
                } else {
                    Image(systemName: AskActivity.symbol(group)).font(.system(size: 11))
                        .frame(width: 14, height: 14)
                }
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .modifier(AskShimmer(active: running))
                if let note = AskActivity.stepNote(group, status: status) {
                    Text("· " + note).foregroundStyle(StudioTheme.textTertiary.opacity(0.8)).lineLimit(1)
                        .layoutPriority(1)
                }
                if failures > 0, !running {
                    HStack(spacing: 4) {
                        Circle().fill(StudioTheme.danger).frame(width: 6, height: 6)
                        Text(L("ask.activity.failures", failures))
                    }
                    .foregroundStyle(StudioTheme.danger)
                    .lineLimit(1)
                    .layoutPriority(1)
                }
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                    .rotationEffect(.degrees(expanded ? 90 : 0))
            }
            .font(.system(size: 12.5))
            .foregroundStyle(hovering || expanded || running ? StudioTheme.textSecondary : StudioTheme.textTertiary)
            .padding(.leading, 8)
            .padding(.trailing, 10)
            .frame(height: Self.lineHeight)
            .background(hovering ? AskTheme.hoverFill : Color.clear, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .padding(.leading, -8)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .accessibilityLabel(failures > 0 ? title + ", " + L("ask.activity.failures", failures) : title)
        .accessibilityValue(L(expanded ? "ask.activity.expanded" : "ask.activity.collapsed"))
    }

    // MARK: Card (waiting for a decision)

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            cardHeader
            if let approval {
                approval.padding(.horizontal, 14).padding(.bottom, 14)
            }
            if expanded {
                Rectangle().fill(AskTheme.separator).frame(height: 1)
                content.padding(.horizontal, 14).padding(.vertical, 12)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Self.corner, style: .continuous))
        // The card scrolls with the transcript, so it takes the glass card's
        // shape and hairline on an opaque surface: live glass belongs to the
        // floating controls layer.
        .askInWindowGlass(corner: Self.corner, opaqueFill: AskTheme.raisedSurface)
        .environment(\.askGlassMaterialOverride, .opaque)
        .overlay(RoundedRectangle(cornerRadius: Self.corner, style: .continuous)
            .strokeBorder(StudioTheme.warning.opacity(0.55)))
    }

    private var cardHeader: some View {
        Button(action: toggle) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark").font(.system(size: 10, weight: .heavy))
                    .foregroundStyle(.black)
                    .frame(width: 20, height: 20)
                    .background(StudioTheme.warning, in: Circle())
                Text(title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(StudioTheme.textPrimary)
                    .lineLimit(1)
                Text(AskActivity.categorySummary(group.steps))
                    .font(.system(size: 12))
                    .foregroundStyle(StudioTheme.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 6)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(StudioTheme.textSecondary)
                    .rotationEffect(.degrees(expanded ? 180 : 0))
            }
            .padding(.horizontal, 14)
            .frame(height: 46)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(L(expanded ? "ask.activity.expanded" : "ask.activity.collapsed"))
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let plan, !plan.isEmpty {
                AskPlanList(items: plan)
                if !group.steps.isEmpty { Rectangle().fill(AskTheme.separator).frame(height: 1).padding(.vertical, 2) }
            }
            ForEach(group.messages) { message in
                if let reasoning = message.reasoning, !reasoning.isEmpty, message.id != leadReasoning?.id {
                    AskStepNote(text: reasoning, symbol: "sparkle")
                }
                if !message.text.isEmpty { AskStepNote(text: message.text, symbol: nil) }
                ForEach((message.toolCalls ?? []).filter { $0.function.name != "update_plan" }) { call in
                    AskToolStepRow(call: call, result: results.first { $0.toolCallId == call.id },
                                   preparing: streamingId == message.id, pending: approvalToolId == call.id,
                                   exportProjectPatch: exportProjectPatch)
                }
            }
        }
    }
}

/// The model's narration between tool calls, in the block's quieter voice.
private struct AskStepNote: View {
    let text: String
    let symbol: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let symbol { Image(systemName: symbol).font(.system(size: 10)) }
            Text(text)
                .font(.system(size: 12.5))
                .lineSpacing(2)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(StudioTheme.textSecondary)
    }
}

/// One tool call as a step under the activity line: its glyph, the step's
/// name and a one-line detail, a status only when it needs attention, and its
/// arguments and result behind a 参数/结果 switch once opened.
struct AskToolStepRow: View {
    enum Pane: Hashable { case arguments, result }

    let call: AskToolCall
    let result: AskMessage?
    var preparing = false
    var pending = false
    var exportProjectPatch: ((AskWorkspaceRef) throws -> Data)?
    @State private var expanded = false
    @State private var pane = Pane.arguments

    static let iconSize: CGFloat = 14

    private var state: AskActivityState {
        if preparing { return .running }
        if pending { return .attention }
        return AskPresentation.toolState(result: result)
    }

    private var statusText: String {
        if preparing { return L("ask.tool.preparing") }
        if pending { return L("ask.tool.pending") }
        return AskPresentation.toolStatusText(result: result, call: call)
    }

    /// A finished step says nothing about itself; anything else does.
    static func showsStatus(_ state: AskActivityState) -> Bool { state != .done }

    /// The tool's own name and action, e.g. "browser.read".
    static func tag(_ call: AskToolCall) -> String {
        let args = (try? JSONSerialization.jsonObject(with: Data(call.function.arguments.utf8))) as? [String: Any]
        guard let action = args?["action"] as? String, !action.isEmpty else { return call.function.name }
        return call.function.name + "." + action
    }

    /// A one-line detail beside the name: the target path, else the result's first line.
    static func detail(_ call: AskToolCall, result: AskMessage?) -> String? {
        if let path = AskApprovalPresentation.detail(call) { return path }
        let line = result?.resultText.split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces)
        return line?.isEmpty == false ? line : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { withAnimation(.easeOut(duration: 0.18)) { expanded.toggle() } } label: {
                HStack(spacing: 8) {
                    Image(systemName: AskPresentation.toolSymbol(call))
                        .font(.system(size: 10.5))
                        .foregroundStyle(StudioTheme.textTertiary)
                        .frame(width: Self.iconSize, height: Self.iconSize)
                    Text(AskTheme.toolTitle(call))
                        .foregroundStyle(StudioTheme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .layoutPriority(1)
                    if let detail = Self.detail(call, result: result) {
                        Text(detail).foregroundStyle(StudioTheme.textTertiary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: 6)
                    if Self.showsStatus(state) {
                        Text(statusText).font(.system(size: 11, weight: .medium)).foregroundStyle(state.tint)
                            .lineLimit(1)
                            .layoutPriority(1)
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(StudioTheme.textTertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .font(.system(size: 12.5))
                .frame(minHeight: 22)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(Self.tag(call))
            .accessibilityLabel(AskTheme.toolTitle(call))
            .accessibilityValue(statusText)
            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    if result != nil {
                        AskSegmentedControl(options: [(Pane.arguments, L("ask.tool.arguments")),
                                                      (Pane.result, L("ask.tool.result"))],
                                            selection: $pane)
                            .frame(width: 112)
                    }
                    if pane == .arguments || result == nil {
                        AskMonoBlock(title: "", text: call.function.arguments)
                    } else if let result {
                        if call.function.name == "project_terminal",
                           let receipt = AskProjectTerminalReceipt.decode(result.resultText) {
                            AskProjectTerminalCard(receipt: receipt)
                        } else if call.function.name == "project_files", result.isError != true,
                           let review = AskProjectReview.decode(result.resultText) {
                            AskProjectReviewView(review: review, exportPatch: exportProjectPatch)
                        } else if !result.resultText.isEmpty {
                            AskMonoBlock(title: "", text: result.resultText,
                                         isError: AskPresentation.toolState(result: result) == .failed)
                        }
                        ForEach(Array(result.resultImages.enumerated()), id: \.offset) { _, url in
                            if let image = AskImage.decode(url) {
                                Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 220)
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }
                        }
                    }
                }
                .padding(.top, 4)
                .padding(.leading, Self.iconSize + 8)
                .padding(.bottom, 4)
                .transition(.opacity)
            }
        }
    }
}

/// Images a run produced and the pages it read, as first-class results.
struct AskRunOutputsView: View {
    let outputs: AskRunOutputs

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(outputs.storedArtifacts, id: \.id) { ref in
                AskStoredArtifactCard(ref: ref)
            }
            ForEach(outputs.artifacts) { artifact in
                AskArtifactCard(artifact: artifact)
            }
            if !outputs.sources.isEmpty {
                AskSourceList(sources: outputs.sources)
            }
        }
    }
}

private struct AskArtifactCard: View {
    let artifact: AskRunOutputs.Artifact
    @State private var preview = false
    @State private var copied = false
    @State private var saveError: String?

    var body: some View {
        if let image = AskImage.decode(artifact.image) {
            HStack(alignment: .bottom, spacing: 12) {
                Button { preview = true } label: {
                    Image(nsImage: image).resizable().scaledToFit()
                        .frame(maxWidth: 320, maxHeight: 200)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(AskTheme.border))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("ask.preview"))
                .popover(isPresented: $preview) {
                    Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: 720, maxHeight: 640).padding()
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("ask.artifact.caption", AskTheme.toolTitle(AskToolCall(id: artifact.id, function: .init(name: artifact.toolName, arguments: "{}")))))
                        .font(.system(size: 11.5))
                        .foregroundStyle(StudioTheme.textTertiary)
                    HStack(spacing: 2) {
                        AskGhostButton(title: copied ? L("ask.copied") : L("ask.copy"),
                                       systemImage: copied ? "checkmark" : "doc.on.doc", active: copied) {
                            AskArtifactActions.copy(image)
                            copied = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                        }
                        AskGhostButton(title: L("ask.artifact.save"), systemImage: "square.and.arrow.down") {
                            do {
                                try AskArtifactActions.save(image)
                                saveError = nil
                            } catch { saveError = error.localizedDescription }
                        }
                    }
                    if let saveError {
                        Text(saveError).font(.system(size: 12)).foregroundStyle(StudioTheme.danger)
                    }
                }
            }
        }
    }
}

enum AskArtifactActions {
    static func copy(_ image: NSImage, pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
    }

    static func pngData(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    static func exportImage(_ image: NSImage, to url: URL) throws {
        guard let data = pngData(image) else { throw AskArtifactError.unsupported }
        try data.write(to: url, options: .atomic)
    }

    @MainActor static func save(_ image: NSImage) throws {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "Typeflux.png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try exportImage(image, to: url)
    }
}

/// Numbered pages the run read; each opens in the browser.
private struct AskSourceList: View {
    let sources: [URL]

    var body: some View {
        HStack(spacing: 6) {
            Text(L("ask.sources")).font(.system(size: 11.5)).foregroundStyle(StudioTheme.textTertiary)
            ForEach(Array(sources.prefix(6).enumerated()), id: \.offset) { index, url in
                AskChip(title: "\(index + 1) " + (url.host ?? url.absoluteString), systemImage: "link",
                        action: { NSWorkspace.shared.open(url) }, help: url.absoluteString)
            }
            if sources.count > 6 {
                Text("+\(sources.count - 6)").font(.system(size: 11.5)).foregroundStyle(StudioTheme.textTertiary)
            }
        }
    }
}
