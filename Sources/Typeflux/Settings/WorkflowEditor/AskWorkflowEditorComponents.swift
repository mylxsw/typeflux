import SwiftUI

/// A monospaced chip: a keyword, a file, or (as a token) a `{placeholder}`.
struct AskWorkflowChip: View {
    enum Style { case plain, token, problem }

    var text: String
    var style: Style = .plain

    var body: some View {
        Group {
            if style == .problem {
                TypefluxTag(text, tone: .danger)
            } else {
                TypefluxToken(text, removeLabel: "")
            }
        }
    }
}

/// A small coloured label: runtime, status, "W2".
struct AskWorkflowBadge: View {
    var text: String
    var color: Color
    var symbol: String?

    var body: some View {
        Label {
            TypefluxTag(text)
        } icon: {
            if let symbol { Image(systemName: symbol).foregroundStyle(color) }
        }
    }
}

/// A choice in a radio list: what it is and one line on what it means.
struct AskWorkflowChoice<Value: Hashable>: Identifiable {
    var value: Value
    var title: String
    var detail: String?

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
        TypefluxRadioGroup("", selection: Binding(get: { selection }, set: select)) {
            ForEach(choices) { choice in
                VStack(alignment: .leading, spacing: 2) {
                    Text(choice.title)
                    if let detail = choice.detail, !detail.isEmpty {
                        Text(detail).font(.subheadline).foregroundStyle(.secondary)
                    }
                }.tag(choice.value)
            }
        }
        .labelsHidden()
    }
}

/// A shortcut after a button's title: "⌘S".
struct AskWorkflowShortcutHint: View {
    var text: String

    var body: some View {
        Text(text).font(.system(.subheadline, design: .monospaced)).opacity(0.7)
    }
}

/// A launcher action as the launcher draws it: "↩ Copy".
struct AskWorkflowActionChip: View {
    @Environment(\.interfaceStyle) private var interfaceStyle

    var key: String
    var title: String
    var primary = false

    var body: some View {
        HStack(spacing: 4) {
            Text(key).font(.system(.footnote, weight: .semibold)).opacity(0.75)
            Text(title)
        }
        .font(.system(.subheadline))
        .foregroundStyle(primary ? TypefluxColor.accent.color : TypefluxColor.secondaryLabel.color)
        .padding(.horizontal, 7).frame(height: 21)
        .background(primary ? TypefluxColor.accent.color.opacity(0.18) : TypefluxColor.controlBackground.color,
                    in: RoundedRectangle(cornerRadius: TypefluxRadius.navigationIcon.value(for: interfaceStyle),
                                         style: .continuous))
        .fixedSize()
    }
}

/// Native segments shared by the side panel and test results.
struct AskWorkflowTabs<Tab: Hashable>: View {
    struct Item {
        var tab: Tab
        var title: String
        var symbol: String?
        var badge: String?
        var tint: Color = TypefluxColor.accent.color
    }

    var items: [Item]
    @Binding var selection: Tab
    /// Tabs share the width evenly instead of hugging their titles.
    var fills = false

    var body: some View {
        TypefluxSegmentedControl("", selection: $selection) {
            ForEach(items.indices, id: \.self) { index in
                let item = items[index]
                Text([item.title, item.badge].compactMap { $0 }.joined(separator: " · "))
                    .tag(item.tab)
            }
        }
        .frame(maxWidth: fills ? .infinity : nil)
    }
}

/// The launcher as it would look for a run: the input row with the keyword chip,
/// then the result card or the error, with the actions the launcher offers.
struct AskWorkflowLauncherPreview: View {
    @Environment(\.interfaceStyle) private var interfaceStyle

    var name: String
    var keyword: String
    var query: String
    var result: AskWorkflowTestResult?
    var output: AskWorkflowManifest.Output
    var timeout: Double
    var showsInput = true
    /// Where the run happened, so stderr shows paths relative to it as the launcher does.
    var folder: URL?
    /// The chosen row of a list; a click moves it, as in the launcher.
    @State private var selectedItem = 0

    var body: some View {
        VStack(spacing: 0) {
            if showsInput {
                HStack(spacing: 8) {
                    HStack(spacing: 5) {
                        Text(keyword).font(.system(.footnote, weight: .heavy)).foregroundStyle(.black)
                            .frame(minWidth: 16, minHeight: 16).padding(.horizontal, 2)
                            .background(Color.orange,
                                        in: RoundedRectangle(cornerRadius: TypefluxRadius.textField
                                            .value(for: interfaceStyle)))
                        Text(name).font(.system(.callout, weight: .semibold)).foregroundStyle(Color.orange)
                    }
                    .padding(.leading, 4).padding(.trailing, 8).frame(height: 24)
                    .background(Color.orange.opacity(0.16),
                                in: RoundedRectangle(cornerRadius: TypefluxRadius.navigationIcon
                                    .value(for: interfaceStyle)))
                    Text(query).font(.system(.body)).lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, 10).frame(height: 40)
                Divider()
            }
            card.padding(6)
        }
        .background(TypefluxColor.controlBackground.color,
                    in: RoundedRectangle(cornerRadius: TypefluxRadius.popover.value(for: interfaceStyle),
                                         style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: TypefluxRadius.popover.value(for: interfaceStyle), style: .continuous)
            .strokeBorder(TypefluxColor.separator.color))
        .shadow(color: .black.opacity(0.18), radius: 12, y: 6)
    }

    private var failed: Bool {
        result.map { !$0.succeeded } ?? false
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(name).font(.system(.callout, weight: .semibold))
                Spacer()
                Text(L("ask.workflow.editor.preview.kind")).font(.system(.subheadline))
                    .foregroundStyle(TypefluxColor.tertiaryLabel.color)
            }
            content
            // Long action names ("Open in Visual Studio Code") leave out the last chips rather than overflow.
            ViewThatFits(in: .horizontal) {
                ForEach(Array(stride(from: actions.count, through: 1, by: -1)), id: \.self) { count in
                    chips(Array(actions.prefix(count)))
                }
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(TypefluxColor.controlBackground.color.opacity(0.6),
                    in: RoundedRectangle(cornerRadius: TypefluxRadius.form.value(for: interfaceStyle),
                                         style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: TypefluxRadius.form.value(for: interfaceStyle), style: .continuous)
            .strokeBorder(failed ? TypefluxColor.danger.color.opacity(0.55) : TypefluxColor.accent.color.opacity(0.55)))
    }

    private func chips(_ actions: [(String, String)]) -> some View {
        HStack(spacing: 5) {
            Spacer(minLength: 0)
            ForEach(Array(actions.enumerated()), id: \.offset) { index, action in
                AskWorkflowActionChip(key: action.0, title: action.1, primary: index == 0 && !failed)
            }
        }
    }

    @ViewBuilder private var content: some View {
        if let result, let failure = result.failure {
            Text(failure).font(.system(.callout)).foregroundStyle(TypefluxColor.danger.color)
        } else if let result, result.timedOut {
            Text(L("ask.workflow.timedOut", Int(timeout))).font(.system(.callout))
                .foregroundStyle(TypefluxColor.danger.color)
        } else if let result, result.exitCode != 0 {
            Text(AskWorkflowPlugin.errorMessage(in: result.stdout) ?? L("ask.workflow.failed", Int(result.exitCode)))
                .font(.system(.callout)).foregroundStyle(TypefluxColor.danger.color)
            let tail = AskWorkflowPlugin.tail(result.stderr, lines: 3, folder: folder).trimmingCharacters(in: .newlines)
            if !tail.isEmpty {
                Text(tail).font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(TypefluxColor.secondaryLabel.color)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    .background(Color(nsColor: .textBackgroundColor),
                                in: RoundedRectangle(cornerRadius: TypefluxRadius.navigationIcon
                                    .value(for: interfaceStyle)))
            }
        } else if result?.truncated == true {
            Text(L("ask.workflow.truncated")).font(.system(.callout)).foregroundStyle(TypefluxColor.danger.color)
        } else if output.display == .none
            || (result?.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? false) {
            Label(L("ask.workflow.editor.test.dismisses"), systemImage: "checkmark.circle")
                .font(.system(.callout)).foregroundStyle(TypefluxColor.success.color)
        } else {
            switch decoded {
            case let .items(list):
                itemList(list)
            case let .markdown(text):
                AskTranscriptText(text: text)
                    .frame(maxHeight: AskPluginResultsView.maximumMarkdownHeight, alignment: .top)
                    .clipped()
            case let .image(name):
                imageView(name)
            case let .text(text, note):
                textLines(text)
                if let note {
                    Text(note).font(.system(.subheadline)).foregroundStyle(TypefluxColor.tertiaryLabel.color)
                }
            }
        }
    }

    /// What the last run printed, or a sample in the chosen display, decoded as the launcher would.
    var decoded: AskWorkflowDecodedOutput {
        AskWorkflowDecodedOutput.decode(result?.stdout ?? Self.sample(for: output.display), display: output.display)
    }

    static func sample(for display: AskWorkflowManifest.Output.Display) -> String {
        switch display {
        case .items: sampleItems
        case .markdown: L("ask.workflow.editor.preview.sampleMarkdown")
        default: L("ask.workflow.editor.preview.sample")
        }
    }

    /// The design's screen ⑦: three conversions, the first copied on Return.
    static let sampleItems = #"""
    {"items": [
      {"title": "14,912.30 JPY", "subtitle": "1 USD = 149.123 JPY", "arg": "14912.30", "icon": "sf:yensign"},
      {"title": "92.18 EUR", "subtitle": "1 USD = 0.9218 EUR", "arg": "92.18", "icon": "sf:eurosign"},
      {"title": "718.40 CNY", "subtitle": "1 USD = 7.184 CNY", "arg": "718.40", "icon": "sf:yensign"}
    ]}
    """#

    /// The image a test run named, as the launcher shows it; before any run, a sample.
    @ViewBuilder private func imageView(_ name: String) -> some View {
        switch image(name) {
        case let .success(image):
            let size = Self.previewSize(image)
            if let picture = AskPluginResultsView.loadImage(image.url) {
                Image(nsImage: picture).resizable().interpolation(.high)
                    .frame(width: size.width, height: size.height)
                    .clipShape(RoundedRectangle(cornerRadius: TypefluxRadius.navigationIcon.value(for: interfaceStyle),
                                                style: .continuous))
                    .frame(maxWidth: .infinity)
            }
        case let .failure(failure):
            if result == nil {
                // No run yet: what an image result looks like.
                Image(systemName: "qrcode").font(.system(.largeTitle, weight: .light))
                    .foregroundStyle(TypefluxColor.label.color).frame(maxWidth: .infinity).padding(.vertical, 6)
            } else {
                let isData = name.lowercased().hasPrefix("data:")
                textLines(isData ? AskWorkflowActionRunner.clipped(name, limit: 40) : name)
                Text(failure == .notImage ? L("ask.workflow.image.invalid")
                    : L("ask.workflow.image.notFound", AskWorkflowActionRunner.clipped(name, limit: 40)))
                    .font(.system(.subheadline)).foregroundStyle(TypefluxColor.tertiaryLabel.color)
            }
        }
    }

    private func image(_ name: String) -> Result<AskPluginImage, AskWorkflowImage.Failure> {
        guard result != nil, let folder else { return .failure(.notImage) }
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("typeflux-workflow-preview")
        return AskWorkflowImage.resolve(name, folder: folder, cache: cache, home: NSHomeDirectory())
    }

    /// The launcher's size for the image, smaller still if the preview is narrower.
    static func previewSize(_ image: AskPluginImage) -> CGSize {
        let size = AskPluginResultsView.imageSize(image)
        let scale = min(1, 280 / size.width, 180 / size.height)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    private var rows: AskWorkflowItemRows {
        AskWorkflowItemRows(folder: folder ?? FileManager.default.temporaryDirectory, name: name)
    }

    /// The rows, one chosen; the launcher shows at most this many before it scrolls.
    private func itemList(_ list: AskWorkflowItemList) -> some View {
        let items = rows.items(list, replaces: false, original: query)
        let shown = Array(items.prefix(AskPluginResultsView.maximumVisibleItems).enumerated())
        return VStack(spacing: AskPluginResultsView.itemSpacing) {
            ForEach(shown, id: \.element.id) { index, item in
                AskPluginItemRow(item: item, symbol: "terminal", selected: index == min(selectedItem, items.count - 1),
                                 emphasized: true, height: AskPluginResultsView.itemHeight) {
                    selectedItem = index
                }
            }
            if items.count > shown.count {
                Text(L("ask.workflow.editor.preview.moreItems", items.count - shown.count))
                    .font(.system(.subheadline)).foregroundStyle(TypefluxColor.tertiaryLabel.color)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func textLines(_ text: String) -> some View {
        let lines = text.components(separatedBy: "\n")
        return VStack(alignment: .leading, spacing: 2) {
            Text(lines.first ?? "").font(.system(.body))
            if lines.count > 1 {
                Text(lines.dropFirst().joined(separator: "\n")).font(.system(.callout))
                    .foregroundStyle(TypefluxColor.secondaryLabel.color)
            }
        }
        .textSelection(.enabled)
    }

    private var actions: [(String, String)] {
        if failed {
            return [("⌘E", L("ask.workflow.action.edit")), ("⌘R", L("ask.workflow.action.rerun"))]
        }
        if output.display == .none {
            return []
        }
        if case .image = decoded {
            return [("↩", L("ask.plugin.action.copyImage")), ("⌥↩", L("ask.plugin.action.reveal")),
                    ("⌘R", L("ask.workflow.action.rerun")), ("⌘↩", L("ask.quick.askAI"))]
        }
        if case let .items(list) = decoded {
            // The chosen row's keys, as the launcher's bottom bar names them.
            let items = rows.items(list, replaces: false, original: query)
            let item = items[min(selectedItem, items.count - 1)]
            let keys: [(AskPluginAction.Shortcut, String)] = [(.enter, "↩"), (.optionEnter, "⌥↩"), (.commandC, "⌘C")]
            return keys.compactMap { shortcut, key in
                item.actions.first { $0.shortcut == shortcut }.map { (key, $0.title) }
            } + [("⌘↩", L("ask.quick.askAI"))]
        }
        return [("↩", L("ask.plugin.action.copy")), ("⌥↩", L("ask.plugin.action.insert")),
                ("⌘R", L("ask.workflow.action.rerun")), ("⌘↩", L("ask.quick.askAI"))]
    }
}

/// Risk tags, new ones highlighted; optionally also what the code does not do.
struct AskWorkflowRiskChips: View {
    @Environment(\.interfaceStyle) private var interfaceStyle

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
        .font(.system(.subheadline))
        .foregroundStyle(highlighted ? Color.orange : TypefluxColor.secondaryLabel.color)
        .padding(.horizontal, 7).padding(.vertical, 2)
        .background((highlighted ? Color.orange : Color.gray).opacity(0.12),
                    in: RoundedRectangle(cornerRadius: TypefluxRadius.navigationIcon.value(for: interfaceStyle)))
        .overlay(RoundedRectangle(cornerRadius: TypefluxRadius.navigationIcon.value(for: interfaceStyle))
            .strokeBorder(highlighted ? Color.orange.opacity(0.35) : TypefluxColor.separator.color))
        .fixedSize()
    }
}
