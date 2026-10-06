import SwiftUI

/// Small pieces the editor's screens share, drawn like the design
/// (`docs/design/ask-workflow-editor.html`).
enum AskWorkflowEditorStyle {
    static let token = Color.orange
    static let assistant = Color.purple

    /// A stable tile colour per workflow, so the list is easy to scan.
    static func tileColor(for id: String) -> Color {
        let palette: [Color] = [.green, .blue, .indigo, .teal, .orange, .pink, .purple, .cyan]
        let sum = id.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return palette[sum % palette.count]
    }
}

/// A monospaced chip: a keyword, a file, or (as a token) a `{placeholder}`.
struct AskWorkflowChip: View {
    enum Style { case plain, token, problem }

    var text: String
    var style: Style = .plain

    var body: some View {
        Text(text)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(foreground)
            .padding(.horizontal, 6).frame(height: 18)
            .background(background, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(border))
            .lineLimit(1).fixedSize()
    }

    private var foreground: Color {
        switch style {
        case .plain: StudioTheme.textPrimary
        case .token: AskWorkflowEditorStyle.token
        case .problem: StudioTheme.danger
        }
    }

    private var background: Color {
        switch style {
        case .plain: StudioTheme.controlSurface
        case .token: AskWorkflowEditorStyle.token.opacity(0.14)
        case .problem: StudioTheme.danger.opacity(0.08)
        }
    }

    private var border: Color {
        switch style {
        case .plain: StudioTheme.border
        case .token: AskWorkflowEditorStyle.token.opacity(0.35)
        case .problem: StudioTheme.danger.opacity(0.6)
        }
    }
}

/// A small coloured label: runtime, status, "W2".
struct AskWorkflowBadge: View {
    var text: String
    var color: Color
    var symbol: String?

    var body: some View {
        HStack(spacing: 3) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 9, weight: .bold))
            }
            Text(text)
        }
        .font(.system(size: 11, weight: .semibold)).foregroundStyle(color)
        .padding(.horizontal, 7).frame(height: 20)
        .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .fixedSize()
    }
}

/// A choice in a radio list: what it is, one line on what it means, and whether
/// it can be picked yet.
struct AskWorkflowChoice<Value: Hashable>: Identifiable {
    var value: Value
    var title: String
    var detail: String?
    var comingSoon = false

    var id: String {
        title
    }
}

/// Mutually exclusive choices as rows in a card: a radio dot, the title and its
/// meaning. Titles never wrap into the detail, unlike cards squeezed side by side.
struct AskWorkflowRadioList<Value: Hashable>: View {
    var choices: [AskWorkflowChoice<Value>]
    var selection: Value
    /// Details below the title instead of after it, for longer explanations.
    var stacked = false
    var select: (Value) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(choices.enumerated()), id: \.element.id) { index, choice in
                if index > 0 {
                    Rectangle().fill(ModelVisualStyle.divider).frame(height: 1)
                }
                row(choice)
            }
        }
        .background(ModelVisualStyle.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(ModelVisualStyle.border))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func row(_ choice: AskWorkflowChoice<Value>) -> some View {
        let selected = choice.value == selection && !choice.comingSoon
        return Button { select(choice.value) } label: {
            HStack(alignment: stacked ? .top : .center, spacing: 11) {
                Circle()
                    .strokeBorder(selected ? AskTheme.accent : StudioTheme.textTertiary, lineWidth: selected ? 5 : 1.5)
                    .frame(width: 16, height: 16)
                    .padding(.top, stacked ? 1 : 0)
                if stacked {
                    VStack(alignment: .leading, spacing: 2) {
                        title(choice)
                        if let detail = choice.detail, !detail.isEmpty {
                            Text(detail).font(.system(size: 12)).foregroundStyle(StudioTheme.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                } else {
                    title(choice)
                    if let detail = choice.detail, !detail.isEmpty {
                        Text(detail).font(.system(size: 12)).foregroundStyle(StudioTheme.textTertiary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14).padding(.vertical, stacked ? 10 : 0)
            .frame(minHeight: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(choice.comingSoon)
        .opacity(choice.comingSoon ? 0.45 : 1)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func title(_ choice: AskWorkflowChoice<Value>) -> some View {
        HStack(spacing: 6) {
            Text(choice.title).font(.system(size: 13, weight: .medium)).foregroundStyle(StudioTheme.textPrimary)
                .lineLimit(1).fixedSize()
            if choice.comingSoon {
                Text(L("ask.workflow.editor.comingSoon")).font(.system(size: 10.5))
                    .foregroundStyle(StudioTheme.textTertiary)
                    .padding(.horizontal, 6).frame(height: 17)
                    .background(StudioTheme.textSecondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 5))
            }
        }
    }
}

/// The editor's buttons: one height and radius everywhere. `primary` is the single
/// main action, `assistant` the AI's, `ghost` a quiet one in a toolbar.
struct AskWorkflowActionStyle: ButtonStyle {
    enum Kind { case secondary, primary, assistant, ghost }

    var kind: Kind = .secondary
    var small = false
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: small ? 12 : 12.5, weight: .medium))
            .lineLimit(1)
            .padding(.horizontal, small ? 9 : 12).frame(height: small ? 24 : 28)
            .foregroundStyle(foreground)
            .background(background, in: RoundedRectangle(cornerRadius: small ? 7 : 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: small ? 7 : 8, style: .continuous)
                .strokeBorder(kind == .secondary ? ModelVisualStyle.border : .clear))
            .contentShape(Rectangle())
            .opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.45)
    }

    private var foreground: Color {
        switch kind {
        case .primary, .assistant: .white
        case .secondary: StudioTheme.textPrimary
        case .ghost: StudioTheme.textSecondary
        }
    }

    private var background: Color {
        switch kind {
        case .primary: AskTheme.accent
        case .assistant: AskWorkflowEditorStyle.assistant
        case .secondary: ModelVisualStyle.control
        case .ghost: .clear
        }
    }
}

/// A shortcut after a button's title: "⌘S".
struct AskWorkflowShortcutHint: View {
    var text: String

    var body: some View {
        Text(text).font(.system(size: 11, design: .monospaced)).opacity(0.7)
    }
}

/// A launcher action as the launcher draws it: "↩ Copy".
struct AskWorkflowActionChip: View {
    var key: String
    var title: String
    var primary = false

    var body: some View {
        HStack(spacing: 4) {
            Text(key).font(.system(size: 10.5, weight: .semibold)).opacity(0.75)
            Text(title)
        }
        .font(.system(size: 11)).foregroundStyle(primary ? AskTheme.accent : StudioTheme.textSecondary)
        .padding(.horizontal, 7).frame(height: 21)
        .background(primary ? AskTheme.accent.opacity(0.18) : StudioTheme.controlSurface,
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .fixedSize()
    }
}

/// Segmented tabs, as the side panel and the test results use them: a track
/// with the selected tab raised.
struct AskWorkflowTabs<Tab: Hashable>: View {
    struct Item {
        var tab: Tab
        var title: String
        var symbol: String?
        var badge: String?
        var tint: Color = AskTheme.accent
    }

    var items: [Item]
    @Binding var selection: Tab
    var size: CGFloat = 12
    /// Tabs share the width evenly instead of hugging their titles.
    var fills = false

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items.indices, id: \.self) { index in
                let item = items[index]
                let selected = item.tab == selection
                Button { selection = item.tab } label: {
                    HStack(spacing: 5) {
                        if let symbol = item.symbol {
                            Image(systemName: symbol).font(.system(size: size - 2, weight: .semibold))
                                .foregroundStyle(selected ? item.tint : StudioTheme.textTertiary)
                        }
                        Text(item.title).font(.system(size: size, weight: selected ? .semibold : .regular))
                            .lineLimit(1)
                        if let badge = item.badge {
                            Text(badge).font(.system(size: 9.5, weight: .bold)).foregroundStyle(StudioTheme.danger)
                                .padding(.horizontal, 4)
                                .background(StudioTheme.danger.opacity(0.14), in: RoundedRectangle(cornerRadius: 4))
                        }
                    }
                    .foregroundStyle(selected ? StudioTheme.textPrimary : StudioTheme.textSecondary)
                    .padding(.horizontal, 10).frame(height: size + 13)
                    .frame(maxWidth: fills ? .infinity : nil)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(selected ? StudioTheme.selectionSurfaceRaised : Color.clear)
                            .shadow(color: .black.opacity(selected ? 0.18 : 0), radius: 1, y: 1)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(ModelVisualStyle.control, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(ModelVisualStyle.border))
    }
}

/// The launcher as it would look for a run: the input row with the keyword chip,
/// then the result card or the error, with the actions the launcher offers.
struct AskWorkflowLauncherPreview: View {
    var name: String
    var keyword: String
    var query: String
    var result: AskWorkflowTestResult?
    var output: AskWorkflowManifest.Output
    var timeout: Double
    var showsInput = true
    /// Where the run happened, so stderr shows paths relative to it as the launcher does.
    var folder: URL?

    var body: some View {
        VStack(spacing: 0) {
            if showsInput {
                HStack(spacing: 8) {
                    HStack(spacing: 5) {
                        Text(keyword).font(.system(size: 9, weight: .heavy)).foregroundStyle(.black)
                            .frame(minWidth: 16, minHeight: 16).padding(.horizontal, 2)
                            .background(Color.orange, in: RoundedRectangle(cornerRadius: 5))
                        Text(name).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.orange)
                    }
                    .padding(.leading, 4).padding(.trailing, 8).frame(height: 24)
                    .background(Color.orange.opacity(0.16), in: RoundedRectangle(cornerRadius: 7))
                    Text(query).font(.system(size: 13.5)).lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, 10).frame(height: 40)
                Divider()
            }
            card.padding(6)
        }
        .background(StudioTheme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(StudioTheme.border))
        .shadow(color: .black.opacity(0.18), radius: 12, y: 6)
    }

    private var failed: Bool {
        result.map { !$0.succeeded } ?? false
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(name).font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(L("ask.workflow.editor.preview.kind")).font(.system(size: 11))
                    .foregroundStyle(StudioTheme.textTertiary)
            }
            content
            HStack(spacing: 5) {
                Spacer(minLength: 0)
                ForEach(Array(actions.enumerated()), id: \.offset) { index, action in
                    AskWorkflowActionChip(key: action.0, title: action.1, primary: index == 0 && !failed)
                }
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(StudioTheme.controlSurface.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(failed ? StudioTheme.danger.opacity(0.55) : AskTheme.accent.opacity(0.55)))
    }

    @ViewBuilder private var content: some View {
        if let result, let failure = result.failure {
            Text(failure).font(.system(size: 12.5)).foregroundStyle(StudioTheme.danger)
        } else if let result, result.timedOut {
            Text(L("ask.workflow.timedOut", Int(timeout))).font(.system(size: 12.5)).foregroundStyle(StudioTheme.danger)
        } else if let result, result.exitCode != 0 {
            Text(AskWorkflowPlugin.errorMessage(in: result.stdout) ?? L("ask.workflow.failed", Int(result.exitCode)))
                .font(.system(size: 12.5)).foregroundStyle(StudioTheme.danger)
            let tail = AskWorkflowPlugin.tail(result.stderr, lines: 3, folder: folder).trimmingCharacters(in: .newlines)
            if !tail.isEmpty {
                Text(tail).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(StudioTheme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
            }
        } else if output == .none || (result?.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? false) {
            Label(L("ask.workflow.editor.test.dismisses"), systemImage: "checkmark.circle")
                .font(.system(size: 12.5)).foregroundStyle(StudioTheme.success)
        } else {
            let lines = (result?.stdout ?? L("ask.workflow.editor.preview.sample"))
                .trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
            VStack(alignment: .leading, spacing: 2) {
                Text(lines.first ?? "").font(.system(size: 14))
                if lines.count > 1 {
                    Text(lines.dropFirst().joined(separator: "\n")).font(.system(size: 12.5))
                        .foregroundStyle(StudioTheme.textSecondary)
                }
            }
            .textSelection(.enabled)
        }
    }

    private var actions: [(String, String)] {
        if failed {
            return [("⌘E", L("ask.workflow.action.edit")), ("⌘R", L("ask.workflow.action.rerun"))]
        }
        if output == .none {
            return []
        }
        return [("↩", L("ask.plugin.action.copy")), ("⌥↩", L("ask.plugin.action.insert")),
                ("⌘R", L("ask.workflow.action.rerun")), ("⌘↩", L("ask.quick.askAI"))]
    }
}

/// Risk tags, new ones highlighted; optionally also what the code does not do.
struct AskWorkflowRiskChips: View {
    var risks: [AskWorkflowRisk]
    var new: Set<AskWorkflowRisk>
    var showsAbsent: Bool

    var body: some View {
        let kinds = Set(risks.map(\.kind))
        VStack(alignment: .leading, spacing: 4) {
            ForEach(risks, id: \.self) { risk in
                chip(new.contains(risk) || !showsAbsent ? risk.title : risk.title + L("ask.workflow.risk.existing"),
                     symbol: risk.kind == .network ? "network" : risk.isHigh ? "exclamationmark.shield" : "doc",
                     highlighted: new.contains(risk))
            }
            if showsAbsent {
                HStack(spacing: 4) {
                    if !kinds.contains(.writesFiles), !kinds.contains(.deletes) {
                        chip(L("ask.workflow.risk.noWrites"), symbol: nil, highlighted: false)
                    }
                    if !kinds.contains(.runsPrograms) {
                        chip(L("ask.workflow.risk.noPrograms"), symbol: nil, highlighted: false)
                    }
                }
            }
        }
    }

    private func chip(_ text: String, symbol: String?, highlighted: Bool) -> some View {
        HStack(spacing: 4) {
            if let symbol {
                Image(systemName: symbol)
            }
            Text(text)
        }
        .font(.system(size: 11))
        .foregroundStyle(highlighted ? Color.orange : StudioTheme.textSecondary)
        .padding(.horizontal, 7).padding(.vertical, 2)
        .background((highlighted ? Color.orange : Color.gray).opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6)
            .strokeBorder(highlighted ? Color.orange.opacity(0.35) : StudioTheme.border))
        .fixedSize()
    }
}
