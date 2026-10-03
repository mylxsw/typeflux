import AppKit
import SwiftUI

/// One run's tool steps as a single block: open while it works or waits for a
/// decision, folded into a one-line summary once it is done.
struct AskActivityBlock: View {
    static let corner: CGFloat = 18

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
    @State private var userExpanded: Bool?

    private var expanded: Bool { userExpanded ?? (status == .running || status == .attention) }

    /// The thinking before the first step, shown above the card like an
    /// answer's reasoning rather than folded inside it.
    private var leadReasoning: AskMessage? {
        guard let lead = group.messages.first, let reasoning = lead.reasoning, !reasoning.isEmpty else { return nil }
        return lead
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let lead = leadReasoning {
                AskReasoningView(text: lead.reasoning ?? "", milliseconds: lead.reasoningMilliseconds ?? 0,
                                 active: streamingId == lead.id && (lead.toolCalls ?? []).isEmpty)
            }
            VStack(alignment: .leading, spacing: 0) {
                header
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
            // floating controls layer, and one per tool step would be costly.
            .askInWindowGlass(corner: Self.corner, opaqueFill: AskTheme.raisedSurface)
            .environment(\.askGlassMaterialOverride, .opaque)
            .overlay(RoundedRectangle(cornerRadius: Self.corner, style: .continuous)
                .strokeBorder(status == .attention ? StudioTheme.warning.opacity(0.55) : Color.clear))
            if !outputs.isEmpty { AskRunOutputsView(outputs: outputs) }
        }
    }

    private var header: some View {
        Button {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) { userExpanded = !expanded }
        } label: {
            HStack(spacing: 10) {
                statusIcon.frame(width: 20, height: 20)
                Text(AskActivity.title(group, status: status, plan: plan, results: results))
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(StudioTheme.textPrimary)
                    .lineLimit(1)
                Text(AskActivity.categorySummary(group.calls))
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
        .accessibilityLabel(AskActivity.title(group, status: status, plan: plan, results: results))
        .accessibilityValue(L(expanded ? "ask.activity.expanded" : "ask.activity.collapsed"))
    }

    /// A filled disc per state, as in the design: green check, amber "!", red
    /// cross; a spinner while it works.
    @ViewBuilder private var statusIcon: some View {
        switch status {
        case .running: ProgressView().controlSize(.small)
        case .attention: statusDisc("exclamationmark", fill: StudioTheme.warning, ink: .black)
        case .failed: statusDisc("xmark", fill: StudioTheme.danger, ink: .white)
        case .done: statusDisc("checkmark", fill: StudioTheme.success, ink: .white)
        }
    }

    private func statusDisc(_ symbol: String, fill: Color, ink: Color) -> some View {
        Image(systemName: symbol).font(.system(size: 10, weight: .heavy))
            .foregroundStyle(ink)
            .frame(width: 20, height: 20)
            .background(fill, in: Circle())
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
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
                                   isLast: call.id == group.steps.last?.id, exportProjectPatch: exportProjectPatch)
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

/// One tool call as a step on the card's timeline: an icon tile, the step's
/// name with its tool tag and status, a one-line detail, and its arguments and
/// result behind a 参数/结果 switch once opened.
struct AskToolStepRow: View {
    enum Pane: Hashable { case arguments, result }

    let call: AskToolCall
    let result: AskMessage?
    var preparing = false
    var pending = false
    /// The last step draws no line down to a next one.
    var isLast = true
    var exportProjectPatch: ((AskWorkspaceRef) throws -> Data)?
    @State private var expanded = false
    @State private var pane = Pane.arguments

    static let tileSize: CGFloat = 22

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

    /// The tool's own name and action, e.g. "browser.read".
    static func tag(_ call: AskToolCall) -> String {
        let args = (try? JSONSerialization.jsonObject(with: Data(call.function.arguments.utf8))) as? [String: Any]
        guard let action = args?["action"] as? String, !action.isEmpty else { return call.function.name }
        return call.function.name + "." + action
    }

    /// A one-line detail under the name: the target path, else the result's first line.
    static func detail(_ call: AskToolCall, result: AskMessage?) -> String? {
        if let path = AskApprovalPresentation.detail(call) { return path }
        let line = result?.resultText.split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces)
        return line?.isEmpty == false ? line : nil
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: AskPresentation.toolSymbol(call))
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(StudioTheme.textSecondary)
                .frame(width: Self.tileSize, height: Self.tileSize)
                .background(AskTheme.hoverFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(AskTheme.separator, lineWidth: 0.5))
            VStack(alignment: .leading, spacing: 3) {
                Button { withAnimation(.easeOut(duration: 0.18)) { expanded.toggle() } } label: {
                    HStack(spacing: 8) {
                        Text(AskTheme.toolTitle(call))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(StudioTheme.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(Self.tag(call)).font(.system(size: 11)).foregroundStyle(StudioTheme.textTertiary)
                            .lineLimit(1)
                        Text(statusText).font(.system(size: 11, weight: .medium)).foregroundStyle(state.tint)
                            .lineLimit(1)
                        Spacer(minLength: 6)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(StudioTheme.textTertiary)
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                    }
                    .frame(minHeight: Self.tileSize)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(AskTheme.toolTitle(call))
                .accessibilityValue(statusText)
                if let detail = Self.detail(call, result: result) {
                    Text(detail).font(.system(size: 12.5)).foregroundStyle(StudioTheme.textSecondary)
                        .lineLimit(1).truncationMode(.middle)
                }
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
                            if call.function.name == "project_files", result.isError != true,
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
                    .padding(.top, 6)
                    .transition(.opacity)
                }
            }
        }
        .padding(.vertical, 6)
        // The timeline: a line from this step's tile down to the next one.
        .background(alignment: .topLeading) {
            if !isLast {
                Rectangle().fill(AskTheme.separator).frame(width: 1.5)
                    .padding(.top, 6 + Self.tileSize + 4)
                    .padding(.bottom, -6)
                    .offset(x: Self.tileSize / 2 - 0.75)
            }
        }
    }
}

/// Images a run produced and the pages it read, as first-class results.
struct AskRunOutputsView: View {
    let outputs: AskRunOutputs

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
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
                            AskArtifactActions.save(image)
                        }
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

    @MainActor static func save(_ image: NSImage) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "Typeflux.png"
        guard panel.runModal() == .OK, let url = panel.url, let data = pngData(image) else { return }
        try? data.write(to: url)
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

/// Local mode remains visible because it uses a separate conversation history.
/// Cloud mode needs no badge; missing local capabilities stay in the tooltip.
struct AskRunLocationLabel: View {
    var local: Bool
    /// The card it opens is showing.
    var highlighted = false

    var body: some View {
        if local {
            // Running on the user's own models is a state, not a fault: no warning
            // glyph, and the text stays in the launcher too. Gaps live in the card.
            HStack(spacing: 4) {
                Image(systemName: "desktopcomputer").font(.system(size: 11, weight: .medium))
                Text(L("ask.location.local")).font(.system(size: 11.5, weight: .medium)).lineLimit(1).fixedSize()
            }
            .foregroundStyle(highlighted ? StudioTheme.textPrimary : StudioTheme.textSecondary)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(highlighted ? AskTheme.pressFill : AskTheme.hoverFill, in: Capsule())
            .help(L("ask.location.local.help"))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L("ask.location.local"))
            .accessibilityHint(L("ask.location.local.help"))
        }
    }
}
