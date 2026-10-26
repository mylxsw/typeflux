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
    /// The run's step count from `AskRunPhase`, for the block that carries the run.
    var runStep: Int?
    var outputs = AskRunOutputs()
    /// Files changed by a round that ended without an answer after these steps.
    var fileChanges: [AskWorkspaceFileChange] = []
    /// The approval for one of this card's steps, shown under its header.
    var approval: AnyView?
    var exportProjectPatch: ((AskWorkspaceRef) throws -> Data)?
    /// Overrides the default fold until the user toggles it.
    var startsExpanded: Bool?
    @Environment(\.askInspectTranscript) private var inspectTranscript
    @State private var userExpanded: Bool?
    @State private var hovering = false
    @State private var detailPage = 0
    @Environment(\.interfaceStyle) private var style
    @Environment(\.askSidePanelActions) private var sidePanel
    /// The waiting card's corner: the glass card's, or the flat design's tighter one.
    private var cardCorner: CGFloat { style.usesGlass ? Self.corner : 10 }

    /// Folded by default, even while working: the line itself names the step under way,
    /// and a waiting card already shows the plan and the decision.
    private var expanded: Bool { userExpanded ?? startsExpanded ?? false }

    private var title: String {
        if status == .done || status == .failed { return AskActivityRowPresentation.groupTitle(group) }
        return AskActivity.title(group, status: status, plan: plan, results: results)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if status == .attention { card } else { trace }
            if !outputs.isEmpty { AskRunOutputsView(outputs: outputs).padding(.top, 4) }
            if let sidePanel, !fileChanges.isEmpty {
                AskFileChangesView(list: AskFileChangeList(changes: fileChanges), actions: sidePanel).padding(.top, 4)
            }
        }
    }

    private func toggle() {
        inspectTranscript()
        userExpanded = !expanded
    }

    // MARK: Quiet line

    private var trace: some View {
        VStack(alignment: .leading, spacing: 6) {
            traceLine
            if expanded {
                content()
                    .padding(.top, 6)
                    .padding(.bottom, 4)
                    .transition(.identity)
            }
        }
    }

    // Tool attempts can fail while the agent retries or changes approach. Keep their
    // errors in the expanded steps; conversation-level notices report blocked runs.
    private var traceLine: some View {
        let running = status == .running
        return Button(action: toggle) {
            HStack(spacing: 6) {
                if running {
                    ProgressView().controlSize(.mini).frame(width: 14, height: 14)
                } else if status == .paused {
                    Image(systemName: "pause.fill").font(.system(size: 9))
                        .foregroundStyle(StudioTheme.warning)
                        .frame(width: 14, height: 14)
                } else {
                    Image(systemName: AskActivity.symbol(group)).font(.system(size: 11))
                        .frame(width: 14, height: 14)
                }
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .modifier(AskShimmer(active: running))
                if let note = AskActivity.stepNote(group, status: status, runStep: runStep) {
                    Text("· " + note).foregroundStyle(StudioTheme.textTertiary.opacity(0.8)).lineLimit(1)
                        .layoutPriority(1)
                }
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .opacity(hovering ? 1 : 0)
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
        .accessibilityLabel(title)
        .accessibilityValue(L(expanded ? "ask.activity.expanded" : "ask.activity.collapsed"))
    }

    // MARK: Card (waiting for a decision)

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            cardHeader
            if let plan, !plan.isEmpty {
                AskPlanList(items: plan).padding(.horizontal, 14).padding(.bottom, 10)
            }
            if let approval {
                approval.padding(.horizontal, 8).padding(.bottom, 8)
            }
            if expanded {
                Rectangle().fill(AskTheme.separator).frame(height: 1)
                content(includesPlan: false).padding(.horizontal, 14).padding(.vertical, 12)
                    .transition(.identity)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cardCorner, style: .continuous))
        // The card scrolls with the transcript, so it takes the glass card's
        // shape and hairline on an opaque surface: live glass belongs to the
        // floating controls layer. One neutral frame: the approval inside it
        // carries the colour, so the card is not a box around a box.
        .askInWindowGlass(corner: cardCorner, opaqueFill: AskTheme.raisedSurface)
        .environment(\.askGlassMaterialOverride, .opaque)
    }

    private var cardHeader: some View {
        Button(action: toggle) {
            HStack(spacing: 8) {
                Text(AskActivity.attentionTitle(plan: plan))
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(StudioTheme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if plan?.isEmpty == false {
                    HStack(spacing: 5) {
                        Circle().fill(StudioTheme.warning).frame(width: 6, height: 6)
                        Text(L("ask.run.attention"))
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(StudioTheme.warning)
                    .fixedSize()
                }
                Spacer(minLength: 6)
                if !group.steps.isEmpty {
                    Text(L("ask.activity.steps", group.steps.count))
                        .font(.system(size: 11.5))
                        .foregroundStyle(StudioTheme.textTertiary)
                        .fixedSize()
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(StudioTheme.textTertiary)
                    .rotationEffect(.degrees(expanded ? 180 : 0))
            }
            .padding(.horizontal, 14)
            .frame(height: 42)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(plan?.isEmpty == false
            ? AskActivity.attentionTitle(plan: plan) + ", " + L("ask.run.attention")
            : AskActivity.attentionTitle(plan: plan))
        .accessibilityValue(L(expanded ? "ask.activity.expanded" : "ask.activity.collapsed"))
    }

    private func content(includesPlan: Bool = true) -> some View {
        let rows = AskActivityDetail.rows(group.messages)
        let range = AskActivityPage.range(count: rows.count, page: detailPage)
        let index = AskActivity.resultIndex(results)
        return VStack(alignment: .leading, spacing: 8) {
            if includesPlan, let plan, !plan.isEmpty {
                Text(AskActivity.planSummary(plan))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(StudioTheme.textSecondary)
                AskPlanList(items: plan)
            }
            if rows.count > AskActivityPage.size {
                HStack(spacing: 12) {
                    Button(L("ask.activity.previous")) { detailPage = max(0, range.lowerBound / AskActivityPage.size - 1) }
                        .disabled(range.lowerBound == 0)
                    Text(L("ask.activity.page", range.lowerBound + 1, range.upperBound, rows.count))
                        .foregroundStyle(StudioTheme.textTertiary)
                    Button(L("ask.activity.next")) { detailPage = range.lowerBound / AskActivityPage.size + 1 }
                        .disabled(range.upperBound == rows.count)
                    Spacer(minLength: 0)
                    Button(L("ask.activity.latest")) { detailPage = AskActivityPage.last(count: rows.count) }
                }
                .font(.system(size: 11.5))
                .buttonStyle(.plain)
            }
            ForEach(Array(rows[range])) { row in
                switch row.kind {
                case let .reasoning(text):
                    AskActivityTextDisclosure(text: text, title: L("ask.activity.reasoning"), symbol: "sparkle")
                case let .note(text):
                    AskActivityNarration(text: text)
                case let .tool(call, messageID):
                    AskToolStepRow(call: call, result: index[call.id],
                                   preparing: streamingId == messageID && index[call.id] == nil,
                                   pending: approvalToolId == call.id, exportProjectPatch: exportProjectPatch)
                }
            }
        }
    }

}

/// The model's narration between tool calls, in the block's quieter voice.
private struct AskActivityTextDisclosure: View {
    let text: String
    let title: String
    let symbol: String
    @State private var expanded = false
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: symbol).font(.system(size: 10))
                    Text(title)
                    Image(systemName: "chevron.right").rotationEffect(.degrees(expanded ? 90 : 0))
                        .opacity(hovering ? 1 : 0)
                    Spacer(minLength: 0)
                }
                .font(.system(size: 12.5))
                .foregroundStyle(StudioTheme.textSecondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .accessibilityValue(L(expanded ? "ask.activity.expanded" : "ask.activity.collapsed"))
            if expanded { AskReasoningText(text: text).frame(height: 220) }
        }
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
    var startsExpanded = false
    @State private var userExpanded: Bool?
    private var expanded: Bool { userExpanded ?? startsExpanded }
    @State private var hovering = false
    @State private var pane = Pane.result
    @Environment(\.askInspectTranscript) private var inspectTranscript
    @Environment(\.askSidePanelActions) private var sidePanel

    static let iconSize: CGFloat = 14

    /// The workspace file a `files` read, write or edit step names, which the side panel can
    /// show; folders, searches and absolute paths (granted folders) are left out.
    static func openablePath(_ call: AskToolCall) -> String? {
        guard call.function.name == "files",
              let args = try? AskLocalTools.jsonArguments(call.function.arguments),
              let action = args["action"] as? String, ["read", "write", "edit"].contains(action),
              let raw = args["path"] as? String, !raw.hasPrefix("/") else { return nil }
        return AskWorkspaceFileChange.workspacePath(raw, root: "/")
    }

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
        let line = result.map { String($0.resultText.prefix(240).prefix(while: { !$0.isNewline })) }?
            .trimmingCharacters(in: .whitespaces)
        guard let line, !line.isEmpty else { return nil }
        return exitSummary(line) ?? line
    }

    /// "Exit code: 0" in words: commands and code report how they ended.
    static func exitSummary(_ line: String) -> String? {
        let prefix = "Exit code: "
        guard line.hasPrefix(prefix), let code = Int(line.dropFirst(prefix.count)) else { return nil }
        return code == 0 ? L("ask.tool.exitSucceeded") : L("ask.tool.exitFailed", code)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Button { inspectTranscript(); userExpanded = !expanded } label: {
                    HStack(spacing: 8) {
                        Image(systemName: AskPresentation.toolSymbol(call))
                            .font(.system(size: 10.5))
                            .foregroundStyle(StudioTheme.textTertiary)
                            .frame(width: Self.iconSize, height: Self.iconSize)
                        Text(AskActivityRowPresentation.title(call))
                            .foregroundStyle(StudioTheme.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.tail)
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
                            .opacity(hovering ? 1 : 0)
                    }
                    .font(.system(size: 12.5))
                    .frame(minHeight: 22)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(Self.tag(call))
                .accessibilityLabel(AskTheme.toolTitle(call))
                .accessibilityValue(statusText + ", " + L(expanded ? "ask.activity.expanded" : "ask.activity.collapsed"))
                // Beside the step, not inside its button: a file it names opens in the side panel.
                if let sidePanel, let path = Self.openablePath(call), result?.isError != true {
                    Button { sidePanel.openFile(path) } label: {
                        Image(systemName: "arrow.up.right.square").font(.system(size: 11))
                            .foregroundStyle(StudioTheme.textTertiary)
                            .frame(width: 18, height: 18).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(L("ask.sidePanel.open.inPanel") + " · " + path)
                    .accessibilityLabel(L("ask.sidePanel.open.inPanel"))
                    .accessibilityIdentifier("ask.tool.openFile")
                    .opacity(hovering ? 1 : 0)
                }
            }
            .onHover { hovering = $0 }
            if expanded {
                if let command = AskActivityRowPresentation.command(call) {
                    let transcript = "$ " + command + (result.map { "\n\n" + $0.resultText } ?? "")
                    AskMonoBlock(title: "Shell", text: transcript, isError: state == .failed,
                                 contentHeight: AskActivityRowPresentation.outputHeight(transcript))
                        .padding(.top, 6).padding(.bottom, 8)
                    DisclosureGroup(L("ask.tool.arguments")) {
                        AskMonoBlock(title: "", text: call.function.arguments)
                    }
                    .font(.system(size: 11.5)).foregroundStyle(StudioTheme.textTertiary)
                    if let result {
                        ForEach(Array(result.retainedResultImages.enumerated()), id: \.offset) { _, url in
                            AskToolImageView(url: url)
                        }
                    }
                } else {
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
                            ForEach(Array(result.retainedResultImages.enumerated()), id: \.offset) { _, url in
                                AskToolImageView(url: url)
                            }
                        }
                    }
                    .padding(.top, 4)
                    .padding(.leading, Self.iconSize + 8)
                    .padding(.bottom, 4)
                    .transition(.identity)
                }
            }
        }
    }
}

/// Images a run produced and the pages it read, as first-class results.
struct AskRunOutputsView: View {
    let outputs: AskRunOutputs
    var remoteImages = AskRemoteImageLoader()
    /// Under an answer, non-image artifacts are listed in its file changes block instead.
    var showsFileArtifacts = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(outputs.generatedImages.enumerated()), id: \.element.assetId) { index, image in
                AskRemoteImageView(asset: image, enabled: index < 8, loader: remoteImages)
            }
            ForEach(outputs.storedArtifacts.filter { showsFileArtifacts || $0.mediaType.hasPrefix("image/") },
                    id: \.id) { ref in
                AskStoredArtifactCard(ref: ref, name: outputs.storedArtifactNames[ref.id])
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
    @StateObject private var imageModel = AskToolImageModel()
    @State private var preview = false
    @State private var copied = false
    @State private var saveError: String?

    var body: some View {
        ZStack { content }
            .task(id: artifact.image) { await imageModel.load(artifact.image) }
            .onDisappear { imageModel.cancel(); preview = false }
    }

    @ViewBuilder private var content: some View {
        if imageModel.source == artifact.image, let image = imageModel.image {
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
        } else if imageModel.unavailable {
            Label(AskArtifactError.unavailable.localizedDescription, systemImage: "photo")
        } else {
            ProgressView().controlSize(.small).frame(width: 32, height: 24)
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
