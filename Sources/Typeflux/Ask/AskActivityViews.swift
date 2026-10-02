import AppKit
import SwiftUI

/// One run's tool steps as a single block: open while it works or waits for a
/// decision, folded into a one-line summary once it is done.
struct AskActivityBlock: View {
    static let corner: CGFloat = 14

    let group: AskActivityGroup
    let results: [AskMessage]
    let plan: [AskPlanItem]?
    let status: AskActivity.Status
    var streamingId: String?
    var approvalToolId: String?
    var outputs = AskRunOutputs()
    @State private var userExpanded: Bool?

    private var expanded: Bool { userExpanded ?? (status == .running || status == .attention) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 0) {
                header
                if expanded {
                    Rectangle().fill(AskTheme.separator).frame(height: 1)
                    content.padding(.horizontal, 12).padding(.vertical, 10)
                }
            }
            .background(AskTheme.hoverFill.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: Self.corner, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Self.corner, style: .continuous)
                .strokeBorder(status == .attention ? StudioTheme.warning.opacity(0.45) : AskTheme.border.opacity(0.6)))
            if !outputs.isEmpty { AskRunOutputsView(outputs: outputs) }
        }
    }

    private var header: some View {
        Button { userExpanded = !expanded } label: {
            HStack(spacing: 8) {
                statusIcon.frame(width: 16)
                Text(AskActivity.title(group, status: status, plan: plan, results: results))
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(StudioTheme.textPrimary)
                    .lineLimit(1)
                Text(AskActivity.categorySummary(group.calls))
                    .font(.system(size: 11.5))
                    .foregroundStyle(StudioTheme.textTertiary)
                    .lineLimit(1)
                Spacer(minLength: 6)
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(StudioTheme.textTertiary)
            }
            .padding(.horizontal, 12)
            .frame(height: 38)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(AskActivity.title(group, status: status, plan: plan, results: results))
        .accessibilityValue(L(expanded ? "ask.activity.expanded" : "ask.activity.collapsed"))
    }

    @ViewBuilder private var statusIcon: some View {
        switch status {
        case .running: ProgressView().controlSize(.mini)
        case .attention: Image(systemName: "hand.raised.fill").font(.system(size: 11)).foregroundStyle(StudioTheme.warning)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundStyle(StudioTheme.danger)
        case .done: Image(systemName: "checkmark.circle.fill").font(.system(size: 12)).foregroundStyle(StudioTheme.success)
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let plan, !plan.isEmpty {
                AskPlanList(items: plan)
                if !group.steps.isEmpty { Rectangle().fill(AskTheme.separator).frame(height: 1).padding(.vertical, 2) }
            }
            ForEach(group.messages) { message in
                if let reasoning = message.reasoning, !reasoning.isEmpty {
                    AskStepNote(text: reasoning, symbol: "sparkle")
                }
                if !message.text.isEmpty { AskStepNote(text: message.text, symbol: nil) }
                ForEach((message.toolCalls ?? []).filter { $0.function.name != "update_plan" }) { call in
                    AskToolStepRow(call: call, result: results.first { $0.toolCallId == call.id },
                                   preparing: streamingId == message.id, pending: approvalToolId == call.id)
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

/// One tool call as a compact row; its arguments and result open on demand.
struct AskToolStepRow: View {
    let call: AskToolCall
    let result: AskMessage?
    var preparing = false
    var pending = false
    @State private var expanded = false

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

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 8) {
                    Image(systemName: AskPresentation.toolSymbol(call))
                        .font(.system(size: 11.5))
                        .foregroundStyle(StudioTheme.textSecondary)
                        .frame(width: 18)
                    Text(AskTheme.toolTitle(call))
                        .font(.system(size: 12.5))
                        .foregroundStyle(StudioTheme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 6)
                    // Finished steps stay quiet; only live, waiting and failed steps get a badge.
                    if state == .done {
                        Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(StudioTheme.textTertiary)
                            .help(statusText)
                    } else {
                        AskStatusBadge(text: statusText, state: state)
                    }
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(StudioTheme.textTertiary)
                }
                .frame(minHeight: 24)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(AskTheme.toolTitle(call))
            .accessibilityValue(statusText)
            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    AskMonoBlock(title: L("ask.tool.arguments"), text: call.function.arguments)
                    if let result {
                        if !result.text.isEmpty {
                            AskMonoBlock(title: L("ask.tool.result"), text: result.text, isError: result.isError == true)
                        }
                        if let url = result.image, let image = AskImage.decode(url) {
                            Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 220)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                    }
                }
                .padding(.leading, 26)
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
    var compact = false
    var notice: String?

    static func help(notice: String?) -> String {
        let base = L("ask.location.local.help")
        return notice.map { base + "\n" + $0 } ?? base
    }

    var body: some View {
        if local {
            HStack(spacing: 4) {
                Image(systemName: "desktopcomputer").font(.system(size: 11, weight: .medium))
                if !compact { Text(L("ask.location.local")).font(.system(size: 11.5, weight: .medium)).lineLimit(1).fixedSize() }
                if notice != nil {
                    Image(systemName: "exclamationmark.circle.fill").font(.system(size: 10)).foregroundStyle(StudioTheme.warning)
                }
            }
            .foregroundStyle(StudioTheme.textSecondary)
            .padding(.horizontal, 7)
            .frame(height: 22)
            .background(AskTheme.hoverFill, in: Capsule())
            .help(Self.help(notice: notice))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L("ask.location.local"))
            .accessibilityHint(Self.help(notice: notice))
        }
    }
}
