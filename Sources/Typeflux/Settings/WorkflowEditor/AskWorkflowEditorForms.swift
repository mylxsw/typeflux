// swiftlint:disable file_length
import SwiftUI
import UniformTypeIdentifiers

/// Form sections share a heading and a hint, like the settings pages.
struct AskWorkflowFormSection<Content: View>: View {
    var title: String
    var hint: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(StudioTheme.textPrimary)
                .padding(.horizontal, 4)
            if let hint {
                Text(hint).font(.system(size: 12)).foregroundStyle(StudioTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4).padding(.top, 3)
            }
            content().padding(.top, 10)
        }
    }
}

/// A field whose text is parsed into the manifest (`to=cny`): what the user types
/// stays as typed while focused, even before it parses.
struct AskWorkflowDraftField: View {
    var placeholder: String
    var value: String
    var commit: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(placeholder, text: $text).focused($focused)
            .onAppear { text = value }
            .onChange(of: value) { newValue in
                guard !focused else { return }
                text = newValue
            }
            .onChange(of: text) { newValue in
                guard focused else { return }
                commit(newValue)
            }
    }
}

func askWorkflowProblemsText(_ problems: [AskWorkflowManifest.Problem]) -> some View {
    VStack(alignment: .leading, spacing: 2) {
        ForEach(problems, id: \.field) { problem in
            Label(problem.field + ": " + problem.message, systemImage: "xmark.circle")
                .font(.system(size: 11.5)).foregroundStyle(StudioTheme.danger)
        }
    }
}

/// Keywords as a table in a card: keyword, display name, preset options as tags.
/// Rows can be dragged by their handle.
struct AskWorkflowKeywordsForm: View {
    @ObservedObject var model: AskWorkflowEditorModel
    @State private var dragging: Int?
    /// The row whose "+ Option" field is open, and what is typed in it.
    @State private var addingOption: Int?
    @State private var newOption = ""
    @FocusState private var optionFocused: Bool

    private var rows: [[String: Any]] {
        model.draft?.value(at: ["keywords"]) as? [[String: Any]] ?? []
    }

    var body: some View {
        AskWorkflowFormSection(title: L("ask.workflow.editor.step.keywords"),
                               hint: L("ask.workflow.editor.keywords.hint")) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Text(L("ask.workflow.trust.keywords")).frame(width: 120, alignment: .leading)
                    Text(L("ask.workflow.editor.keywords.title")).frame(width: 180, alignment: .leading)
                    Text(L("ask.workflow.editor.keywords.optionsShort")).frame(maxWidth: .infinity, alignment: .leading)
                    Color.clear.frame(width: 44)
                }
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(StudioTheme.textTertiary)
                .padding(.horizontal, 14).frame(height: 32)
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    Rectangle().fill(ModelVisualStyle.divider).frame(height: 1)
                    keywordRow(index, row)
                }
                Rectangle().fill(ModelVisualStyle.divider).frame(height: 1)
                Button { add() } label: {
                    Label(L("ask.workflow.editor.keywords.add"), systemImage: "plus")
                        .font(.system(size: 12.5, weight: .medium)).foregroundStyle(ModelVisualStyle.accent)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14).frame(height: 40).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("ask.workflow.editor.keywords.add")
            }
            .background(ModelVisualStyle.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(ModelVisualStyle.border))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            askWorkflowProblemsText(model.problems(for: .keywords).filter { !$0.field.hasPrefix("keywords[") })
                .padding(.top, 6)
        }
    }

    private func keywordRow(_ index: Int, _ row: [String: Any]) -> some View {
        let keyword = row["keyword"] as? String ?? ""
        let problem = model.keywordProblem(keyword) ?? duplicateProblem(keyword, index: index)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                TextField("fx", text: binding(index, "keyword"))
                    .textFieldStyle(ModelFieldStyle())
                    .overlay(RoundedRectangle(cornerRadius: ModelVisualStyle.controlCornerRadius, style: .continuous)
                        .strokeBorder(problem == nil ? .clear : StudioTheme.danger.opacity(0.7)))
                    .frame(width: 120)
                TextField(L("ask.workflow.editor.keywords.titlePlaceholder"), text: binding(index, "title"))
                    .textFieldStyle(ModelFieldStyle(monospaced: false))
                    .frame(width: 180)
                optionTags(index)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "line.3.horizontal").font(.system(size: 11)).foregroundStyle(StudioTheme.textTertiary)
                    .frame(width: 16).help(L("ask.workflow.editor.keywords.drag"))
                    .onDrag {
                        dragging = index
                        return NSItemProvider(object: "\(index)" as NSString)
                    }
                Button { remove(index) } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                        .frame(width: 20, height: 20).contentShape(Rectangle())
                }
                .buttonStyle(.plain).disabled(rows.count <= 1)
                .foregroundStyle(StudioTheme.textTertiary).opacity(rows.count <= 1 ? 0.35 : 1)
                .help(L("ask.workflow.editor.keywords.remove"))
            }
            if let problem {
                Text(problem).font(.system(size: 11.5)).foregroundStyle(StudioTheme.danger)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(problem == nil ? Color.clear : StudioTheme.danger.opacity(0.06))
        .onDrop(of: [UTType.text], delegate: KeywordDrop(target: index, dragging: $dragging, move: move))
    }

    /// Preset options as `name=value` tags with a remove button, then "+ Option".
    private func optionTags(_ index: Int) -> some View {
        let options = optionsOf(index)
        return AgentFlowLayout(spacing: 5) {
            ForEach(options.keys.sorted(), id: \.self) { key in
                HStack(spacing: 3) {
                    Text("\(key)=\(options[key] ?? "")").font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(StudioTheme.textPrimary).lineLimit(1)
                    Button { removeOption(key, index) } label: {
                        Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                            .frame(width: 14, height: 14).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).foregroundStyle(StudioTheme.textTertiary)
                    .accessibilityLabel(L("ask.workflow.editor.keywords.removeOption", key))
                }
                .padding(.leading, 7).padding(.trailing, 3).frame(height: 22)
                .background(ModelVisualStyle.control, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(ModelVisualStyle.border))
            }
            if addingOption == index {
                TextField("name=value", text: $newOption)
                    .textFieldStyle(.plain).font(.system(size: 11.5, design: .monospaced))
                    .focused($optionFocused)
                    .frame(width: 120, height: 22).padding(.horizontal, 6)
                    .background(ModelVisualStyle.control, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(AskTheme.accent))
                    .onSubmit { commitOption(index) }
                    .onExitCommand { addingOption = nil; newOption = "" }
            } else {
                Button {
                    addingOption = index
                    newOption = ""
                    optionFocused = true
                } label: {
                    Text(L("ask.workflow.editor.keywords.addOption")).font(.system(size: 11.5))
                        .foregroundStyle(StudioTheme.textTertiary)
                        .padding(.horizontal, 8).frame(height: 22)
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(ModelVisualStyle.border, style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L("ask.workflow.editor.keywords.optionsPlaceholderHint"))
            }
        }
    }

    /// Moves the dragged row onto the row it is dropped on.
    private struct KeywordDrop: DropDelegate {
        var target: Int
        @Binding var dragging: Int?
        var move: (Int, Int) -> Void

        func performDrop(info _: DropInfo) -> Bool {
            defer { dragging = nil }
            guard let dragging, dragging != target else { return false }
            move(dragging, target)
            return true
        }
    }

    func move(_ source: Int, _ destination: Int) {
        var all = rows
        guard all.indices.contains(source), all.indices.contains(destination) else { return }
        let row = all.remove(at: source)
        all.insert(row, at: destination)
        model.set(all, at: ["keywords"])
    }

    private func duplicateProblem(_ keyword: String, index: Int) -> String? {
        let earlier = rows.prefix(index).compactMap { $0["keyword"] as? String }
            .map { AskKeyword(keyword: $0, pluginID: "") }
        return AskKeywordMatcher.problem(with: keyword, among: earlier).map(AskKeywordList.message(for:))
    }

    private func binding(_ index: Int, _ key: String) -> Binding<String> {
        Binding(get: { rows.indices.contains(index) ? rows[index][key] as? String ?? "" : "" }, set: { value in
            var all = rows
            guard all.indices.contains(index) else { return }
            all[index][key] = value.isEmpty && key != "keyword" ? nil : value
            model.set(all, at: ["keywords"])
        })
    }

    private func optionsOf(_ index: Int) -> [String: String] {
        rows.indices.contains(index) ? rows[index]["options"] as? [String: String] ?? [:] : [:]
    }

    private func setOptions(_ options: [String: String], _ index: Int) {
        var all = rows
        guard all.indices.contains(index) else { return }
        all[index]["options"] = options.isEmpty ? nil : options
        model.set(all, at: ["keywords"])
    }

    private func commitOption(_ index: Int) {
        let parsed = Self.parseOptions(newOption)
        if !parsed.isEmpty {
            setOptions(optionsOf(index).merging(parsed) { $1 }, index)
        }
        addingOption = nil
        newOption = ""
    }

    private func removeOption(_ key: String, _ index: Int) {
        var options = optionsOf(index)
        options[key] = nil
        setOptions(options, index)
    }

    /// `to=cny, scope=mine` → `["to": "cny", "scope": "mine"]`.
    static func parseOptions(_ text: String) -> [String: String] {
        var options: [String: String] = [:]
        for part in text.split(separator: ",") {
            let pair = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if pair.count == 2, !pair[0].isEmpty {
                options[pair[0]] = pair[1]
            }
        }
        return options
    }

    private func add() {
        model.set(rows + [["keyword": ""]], at: ["keywords"])
    }

    private func remove(_ index: Int) {
        var all = rows
        guard all.indices.contains(index) else { return }
        all.remove(at: index)
        model.set(all, at: ["keywords"])
    }
}

/// Name, description and icon: edited from the title in the toolbar.
struct AskWorkflowInfoForm: View {
    @ObservedObject var model: AskWorkflowEditorModel
    var done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            row(L("ask.workflow.editor.name")) {
                TextField("", text: stringBinding(["name"])).textFieldStyle(ModelFieldStyle(monospaced: false))
                    .accessibilityIdentifier("ask.workflow.editor.info.name")
            }
            row(L("ask.workflow.editor.description")) {
                TextField("", text: stringBinding(["description"])).textFieldStyle(ModelFieldStyle(monospaced: false))
            }
            row(L("ask.workflow.editor.icon")) {
                TextField("sf:dollarsign.circle", text: stringBinding(["icon"])).textFieldStyle(ModelFieldStyle())
            }
            HStack {
                Spacer()
                Button(L("ask.workflow.editor.done"), action: done).buttonStyle(AskWorkflowActionStyle(small: true))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14).frame(width: 340)
    }

    private func row(_ label: String, @ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: 10) {
            Text(label).font(.system(size: 12.5)).foregroundStyle(StudioTheme.textSecondary)
                .frame(width: 44, alignment: .leading)
            content()
        }
    }

    private func stringBinding(_ path: [String]) -> Binding<String> {
        Binding(get: { model.draft?.value(at: path) as? String ?? "" },
                set: { model.set($0.isEmpty && path != ["name"] ? nil : $0, at: path) })
    }
}

/// What the script receives: argument, selection, the argv template, and a preview.
struct AskWorkflowInputForm: View {
    @ObservedObject var model: AskWorkflowEditorModel

    private var manifest: AskWorkflowManifest? {
        model.draft?.manifest
    }

    private var template: [String] {
        model.draft?.value(at: ["command", "args"]) as? [String] ?? ["{query}"]
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            AskWorkflowFormSection(
                title: L("ask.workflow.editor.argument"),
                hint: L("ask.workflow.editor.argument.hint")
            ) {
                AskWorkflowRadioList(
                    choices: [AskWorkflowManifest.Input.Argument.required, .optional, .none].map {
                        AskWorkflowChoice(value: $0, title: L("ask.workflow.editor.argument." + $0.rawValue),
                                          detail: L("ask.workflow.editor.argumentDetail." + $0.rawValue))
                    },
                    selection: manifest?.input.argument ?? .optional
                ) { model.set($0.rawValue, at: ["input", "argument"]) }
            }
            .frame(maxWidth: .infinity)
            AskWorkflowFormSection(
                title: L("ask.workflow.trust.selection"),
                hint: L("ask.workflow.editor.selection.hint")
            ) {
                AskWorkflowRadioList(
                    choices: [AskWorkflowManifest.Input.Selection.ifEmpty, .always, .never].map {
                        AskWorkflowChoice(value: $0, title: L("ask.workflow.editor.selection." + $0.rawValue),
                                          detail: L("ask.workflow.editor.selectionDetail." + $0.rawValue))
                    },
                    selection: manifest?.input.selection ?? .ifEmpty
                ) { model.set($0.rawValue, at: ["input", "selection"]) }
            }
            .frame(maxWidth: .infinity)
        }
        AskWorkflowFormSection(title: L("ask.workflow.editor.args"), hint: L("ask.workflow.editor.args.hint")) {
            VStack(alignment: .leading, spacing: 0) {
                argv.padding(.horizontal, 12).padding(.vertical, 10)
                Rectangle().fill(ModelVisualStyle.divider).frame(height: 1)
                insertBar.padding(.horizontal, 12).frame(height: 40)
                Rectangle().fill(ModelVisualStyle.divider).frame(height: 1)
                Text(preview).font(.system(size: 12, design: .monospaced)).foregroundStyle(StudioTheme.textSecondary)
                    .textSelection(.enabled).lineSpacing(3)
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(StudioTheme.textSecondary.opacity(0.04))
            }
            .background(ModelVisualStyle.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(ModelVisualStyle.border))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        askWorkflowProblemsText(model.problems(for: .input))
    }

    private var argv: some View {
        AgentFlowLayout(spacing: 6) {
            Text(program).font(.system(size: 12.5, design: .monospaced)).foregroundStyle(StudioTheme.textSecondary)
                .frame(height: 26)
            ForEach(Array(template.enumerated()), id: \.offset) { index, _ in
                HStack(spacing: 4) {
                    Text("$\(index + 1)").font(.system(size: 10.5)).foregroundStyle(StudioTheme.textTertiary)
                    TextField("", text: argument(index)).font(.system(size: 12.5, design: .monospaced))
                        .textFieldStyle(.plain).frame(minWidth: 50, maxWidth: 160).fixedSize()
                    Button { removeArgument(index) } label: {
                        Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                            .frame(width: 14, height: 14).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).foregroundStyle(StudioTheme.textTertiary)
                }
                .padding(.leading, 8).padding(.trailing, 4).frame(height: 26)
                .background(ModelVisualStyle.control, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(ModelVisualStyle.border))
            }
            Button { setTemplate(template + [""]) } label: {
                Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(StudioTheme.textTertiary)
                    .frame(width: 26, height: 26)
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(ModelVisualStyle.border, style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L("ask.workflow.editor.args.add"))
        }
    }

    private var insertBar: some View {
        HStack(spacing: 6) {
            Text(L("ask.workflow.editor.args.insert")).font(.system(size: 12))
                .foregroundStyle(StudioTheme.textTertiary)
            ForEach(tokens, id: \.self) { token in
                Button { setTemplate(template + [token]) } label: {
                    Text(token).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(AskTheme.accent)
                        .padding(.horizontal, 7).frame(height: 20)
                        .background(AskTheme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 8)
            Text(L("ask.workflow.editor.args.try")).font(.system(size: 12)).foregroundStyle(StudioTheme.textTertiary)
            HStack(spacing: 5) {
                if let keyword = manifest?.keywords.first?.keyword {
                    AskWorkflowChip(text: keyword)
                }
                TextField("100 usd", text: $model.testQuery).textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
            }
            .padding(.horizontal, 6).frame(width: 170, height: 24)
            .background(ModelVisualStyle.control, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(ModelVisualStyle.border))
        }
    }

    private var program: String {
        guard let manifest else { return "" }
        let interpreter = manifest.command.interpreter ?? manifest.command.runtime.interpreterName ?? ""
        return [interpreter, manifest.command.script ?? "-c …"].filter { !$0.isEmpty }.joined(separator: " ")
    }

    private var tokens: [String] {
        let options = Set((manifest?.keywords ?? []).flatMap { ($0.options ?? [:]).keys })
        return ["{query}", "{selection}"] + options.sorted().map { "{option:\($0)}" }
    }

    private var sampleQuery: String {
        model.testQuery.isEmpty ? "100 usd" : model.testQuery
    }

    /// What the script would get for an example input with the first keyword.
    private var preview: String {
        guard let manifest else { return "" }
        let keyword = manifest.keywords.first
        let options = keyword?.options ?? [:]
        let query = sampleQuery
        let selection: String? = manifest.input
            .selection == .always ? L("ask.workflow.editor.args.sampleSelection") : nil
        let argv = AskWorkflowManifest.arguments(manifest.argumentTemplate, query: query, selection: selection,
                                                 options: options)
        var stdin: [String: Any] = [
            "typeflux": 1,
            "query": query,
            "keyword": keyword?.keyword ?? "",
            "options": options
        ]
        stdin["selection"] = selection ?? NSNull()
        return "argv   " + AskWorkflowAuthorTools.json(argv) + "\nstdin  " + AskWorkflowAuthorTools.json(stdin)
    }

    private func argument(_ index: Int) -> Binding<String> {
        Binding(get: { template.indices.contains(index) ? template[index] : "" }, set: { value in
            var all = template
            guard all.indices.contains(index) else { return }
            all[index] = value
            setTemplate(all)
        })
    }

    private func removeArgument(_ index: Int) {
        var all = template
        guard all.indices.contains(index) else { return }
        all.remove(at: index)
        setTemplate(all)
    }

    private func setTemplate(_ value: [String]) {
        model.set(value, at: ["command", "args"])
    }
}

/// What the script prints and when it runs, with the launcher as it would look
/// on the right. Limits, runtime and variables live with the script.
struct AskWorkflowOutputForm: View {
    @ObservedObject var model: AskWorkflowEditorModel

    private var manifest: AskWorkflowManifest? {
        model.draft?.manifest
    }

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 22) {
                AskWorkflowFormSection(
                    title: L("ask.workflow.editor.output"),
                    hint: L("ask.workflow.editor.output.hint")
                ) {
                    AskWorkflowRadioList(
                        choices: [AskWorkflowManifest.Output.text, .none, .auto].map {
                            AskWorkflowChoice(value: $0, title: L("ask.workflow.editor.output." + $0.rawValue),
                                              detail: L("ask.workflow.editor.outputDetail." + $0.rawValue))
                        } + [AskWorkflowChoice(value: AskWorkflowManifest.Output.items,
                                               title: L("ask.workflow.editor.output.items"),
                                               detail: L("ask.workflow.editor.outputDetail.items"), comingSoon: true)],
                        selection: manifest?.output ?? .auto, stacked: true
                    ) { model.set($0.rawValue, at: ["output"]) }
                }
                AskWorkflowFormSection(title: L("ask.workflow.editor.runMode"), hint: nil) {
                    HStack(spacing: 2) {
                        runMode(L("ask.workflow.editor.runMode.onSubmit"), selected: true)
                        runMode(L("ask.workflow.editor.runMode.live") + " · " + L("ask.workflow.editor.comingSoon"),
                                selected: false)
                            .opacity(0.45)
                            .help(L("ask.workflow.editor.runMode.liveDetail"))
                    }
                    .padding(2)
                    .background(ModelVisualStyle.control, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(ModelVisualStyle.border))
                    .fixedSize()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            AskWorkflowFormSection(
                title: L("ask.workflow.editor.preview.title"),
                hint: L("ask.workflow.editor.preview.hint")
            ) {
                VStack(alignment: .leading, spacing: 10) {
                    AskWorkflowLauncherPreview(
                        name: manifest?.name ?? "", keyword: manifest?.keywords.first?.keyword ?? "",
                        query: model.results.last?.input
                            .query ?? (model.testQuery.isEmpty ? "100 usd jpy" : model.testQuery),
                        result: model.results.last.flatMap { $0.succeeded ? $0 : nil },
                        output: manifest?.output ?? .text,
                        timeout: manifest?.timeout ?? AskWorkflowManifest.defaultTimeout
                    )
                    Text(L("ask.workflow.editor.preview.noneNote")).font(.system(size: 11.5))
                        .foregroundStyle(StudioTheme.textTertiary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        askWorkflowProblemsText(model.problems(for: .output))
    }

    private func runMode(_ title: String, selected: Bool) -> some View {
        Text(title).font(.system(size: 12, weight: selected ? .semibold : .regular))
            .foregroundStyle(selected ? StudioTheme.textPrimary : StudioTheme.textSecondary)
            .padding(.horizontal, 11).frame(height: 24)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(selected ? StudioTheme.selectionSurfaceRaised : Color.clear)
                    .shadow(color: .black.opacity(selected ? 0.18 : 0), radius: 1, y: 1)
            )
    }
}

/// Runtime, interpreter, script, timeout and environment: shown above the code
/// when "Run settings" is open.
struct AskWorkflowRunSettings: View {
    @ObservedObject var model: AskWorkflowEditorModel
    /// Environment rows as typed, so a half-written row is not dropped while editing.
    @State private var env: [EnvRow] = []

    struct EnvRow: Identifiable, Equatable {
        let id = UUID()
        var name: String
        var value: String
    }

    private var manifest: AskWorkflowManifest? {
        model.draft?.manifest
    }

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
            GridRow {
                label(L("ask.workflow.editor.runtime"))
                Picker("", selection: Binding(get: { manifest?.command.runtime ?? .python3 },
                                              set: { model.set($0.rawValue, at: ["command", "runtime"]) })) {
                    ForEach(AskWorkflowRuntime.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
                label(L("ask.workflow.editor.interpreter"))
                TextField(L("ask.workflow.editor.interpreterAutoShort", model.runtimeInfo ?? "…"), text: Binding(
                    get: { model.draft?.value(at: ["command", "interpreter"]) as? String ?? "" },
                    set: { model.set($0.isEmpty ? nil : $0, at: ["command", "interpreter"]) }
                ))
                .textFieldStyle(ModelFieldStyle())
            }
            GridRow {
                label(L("ask.workflow.editor.script"))
                TextField("main.py", text: Binding(
                    get: { model.draft?.value(at: ["command", "script"]) as? String ?? "" },
                    set: { model.set($0.isEmpty ? nil : $0, at: ["command", "script"]) }
                ))
                .textFieldStyle(ModelFieldStyle())
                label(L("ask.workflow.editor.timeout"))
                HStack(spacing: 8) {
                    Slider(value: Binding(get: { manifest?.timeout ?? AskWorkflowManifest.defaultTimeout },
                                          set: { model.set(Int($0.rounded()), at: ["run", "timeoutSeconds"]) }),
                           in: 1 ... 120)
                        .controlSize(.small)
                    TextField(
                        "",
                        value: Binding(get: { Int(manifest?.timeout ?? AskWorkflowManifest.defaultTimeout) },
                                       set: { model.set(min(300, max(1, $0)), at: ["run", "timeoutSeconds"]) }),
                        format: .number
                    )
                    .textFieldStyle(ModelFieldStyle()).multilineTextAlignment(.trailing).frame(width: 52)
                    Text(L("ask.workflow.editor.secondsUnit")).font(.system(size: 12.5))
                        .foregroundStyle(StudioTheme.textTertiary)
                }
            }
            GridRow(alignment: .top) {
                label(L("ask.workflow.editor.env")).padding(.top, 6)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach($env) { $row in
                        HStack(spacing: 6) {
                            TextField("NAME", text: $row.name).textFieldStyle(ModelFieldStyle()).frame(width: 170)
                            TextField(L("ask.workflow.editor.env.value"), text: $row.value)
                                .textFieldStyle(ModelFieldStyle())
                            Button { env.removeAll { $0.id == row.id } } label: {
                                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                                    .frame(width: 24, height: 24).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain).foregroundStyle(StudioTheme.textTertiary)
                        }
                    }
                    HStack(spacing: 10) {
                        Button { env.append(EnvRow(name: "", value: "")) } label: {
                            Label(L("ask.workflow.editor.env.add"), systemImage: "plus")
                                .font(.system(size: 12, weight: .medium)).foregroundStyle(AskTheme.accent)
                        }
                        .buttonStyle(.plain)
                        Text(L("ask.workflow.editor.env.noSecrets")).font(.system(size: 11.5))
                            .foregroundStyle(StudioTheme.textTertiary)
                    }
                }
                .gridCellColumns(3)
            }
        }
        .font(.system(size: 12.5))
        .padding(14)
        .onAppear(perform: loadEnv)
        .onChange(of: model.workflowID) { _ in loadEnv() }
        // `workflow.json` or an applied proposal changed the variables: show them.
        .onChange(of: savedEnv) { saved in
            if saved != Self.environment(env) {
                loadEnv()
            }
        }
        .onChange(of: env) { rows in
            let edited = Self.environment(rows)
            if edited != savedEnv {
                model.set(edited.isEmpty ? nil : edited, at: ["env"])
            }
        }
    }

    private var savedEnv: [String: String] {
        model.draft?.value(at: ["env"]) as? [String: String] ?? [:]
    }

    private func label(_ text: String) -> some View {
        Text(text).foregroundStyle(StudioTheme.textSecondary).frame(width: 64, alignment: .leading)
    }

    private func loadEnv() {
        let saved = savedEnv
        env = saved.keys.sorted().map { EnvRow(name: $0, value: saved[$0] ?? "") }
    }

    /// The rows with a name, as the manifest's `env`; a later row wins over an earlier one.
    static func environment(_ rows: [EnvRow]) -> [String: String] {
        var env: [String: String] = [:]
        for row in rows {
            let name = row.name.trimmingCharacters(in: .whitespaces)
            if !name.isEmpty {
                env[name] = row.value
            }
        }
        return env
    }
}
