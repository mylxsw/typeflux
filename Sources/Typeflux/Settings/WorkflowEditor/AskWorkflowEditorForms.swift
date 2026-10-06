import SwiftUI
import UniformTypeIdentifiers

/// Form sections share a heading and a hint.
private struct FormSection<Content: View>: View {
    var title: String
    var hint: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 13, weight: .semibold))
            if let hint {
                Text(hint).font(.system(size: 11.5)).foregroundStyle(StudioTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            content().padding(.top, 2)
        }
    }
}

/// A field whose text is parsed into the manifest (`to=cny`): what the user types
/// stays as typed while focused, even before it parses.
private struct DraftField: View {
    var placeholder: String
    var value: String
    var multiline = false
    var commit: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if multiline {
                TextEditor(text: $text).focused($focused)
            } else {
                TextField(placeholder, text: $text).focused($focused)
            }
        }
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

private func problemsText(_ problems: [AskWorkflowManifest.Problem]) -> some View {
    VStack(alignment: .leading, spacing: 2) {
        ForEach(problems, id: \.field) { problem in
            Label(problem.field + ": " + problem.message, systemImage: "xmark.circle")
                .font(.system(size: 11.5)).foregroundStyle(StudioTheme.danger)
        }
    }
}

/// Keywords as a table: keyword, title, preset options (`name=value, …`); rows can be dragged.
struct AskWorkflowKeywordsForm: View {
    @ObservedObject var model: AskWorkflowEditorModel
    @State private var dragging: Int?

    private var rows: [[String: Any]] {
        model.draft?.value(at: ["keywords"]) as? [[String: Any]] ?? []
    }

    var body: some View {
        FormSection(title: L("ask.workflow.editor.step.keywords"), hint: L("ask.workflow.editor.keywords.hint")) {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Text(L("ask.workflow.trust.keywords")).frame(width: 120, alignment: .leading)
                    Text(L("ask.workflow.editor.keywords.title")).frame(maxWidth: .infinity, alignment: .leading)
                    Text(L("ask.workflow.editor.keywords.options")).frame(maxWidth: .infinity, alignment: .leading)
                    Color.clear.frame(width: 44)
                }
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(StudioTheme.textTertiary)
                .padding(.horizontal, 12).padding(.vertical, 7).background(StudioTheme.controlSurface)
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    keywordRow(index, row)
                    if index < rows.count - 1 {
                        Divider()
                    }
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(StudioTheme.border))
            .clipShape(RoundedRectangle(cornerRadius: 9))
            Button { add() } label: { Label(L("ask.workflow.editor.keywords.add"), systemImage: "plus") }
                .buttonStyle(.borderless)
            problemsText(model.problems(for: .keywords).filter { !$0.field.hasPrefix("keywords[") })
        }
        FormSection(title: L("ask.workflow.editor.general"), hint: nil) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text(L("ask.workflow.editor.name")).foregroundStyle(StudioTheme.textSecondary)
                    TextField("", text: stringBinding(["name"]))
                }
                GridRow {
                    Text(L("ask.workflow.editor.description")).foregroundStyle(StudioTheme.textSecondary)
                    TextField("", text: stringBinding(["description"]))
                }
                GridRow {
                    Text(L("ask.workflow.editor.icon")).foregroundStyle(StudioTheme.textSecondary)
                    TextField("sf:dollarsign.circle", text: stringBinding(["icon"]))
                }
            }
            .textFieldStyle(.roundedBorder).font(.system(size: 12.5))
        }
    }

    private func keywordRow(_ index: Int, _ row: [String: Any]) -> some View {
        let keyword = row["keyword"] as? String ?? ""
        let problem = model.keywordProblem(keyword) ?? duplicateProblem(keyword, index: index)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                TextField("fx", text: binding(index, "keyword"))
                    .font(.system(size: 12, design: .monospaced)).frame(width: 120)
                    .overlay(RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(problem == nil ? .clear : StudioTheme.danger.opacity(0.7)))
                TextField(L("ask.workflow.editor.keywords.titlePlaceholder"), text: binding(index, "title"))
                DraftField(placeholder: L("ask.workflow.editor.keywords.optionsPlaceholder"),
                           value: optionsText(index)) { setOptions($0, index) }
                    .font(.system(size: 12, design: .monospaced))
                Image(systemName: "line.3.horizontal").foregroundStyle(StudioTheme.textTertiary)
                    .frame(width: 16).help(L("ask.workflow.editor.keywords.drag"))
                    .onDrag {
                        dragging = index
                        return NSItemProvider(object: "\(index)" as NSString)
                    }
                Button { remove(index) } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless).frame(width: 16).disabled(rows.count <= 1)
                    .foregroundStyle(StudioTheme.textTertiary)
            }
            .textFieldStyle(.roundedBorder)
            if let problem {
                Text(problem).font(.system(size: 11.5)).foregroundStyle(StudioTheme.danger)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(problem == nil ? Color.clear : StudioTheme.danger.opacity(0.06))
        .onDrop(of: [UTType.text], delegate: KeywordDrop(target: index, dragging: $dragging, move: move))
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

    private func optionsText(_ index: Int) -> String {
        let options = rows.indices.contains(index) ? rows[index]["options"] as? [String: String] ?? [:] : [:]
        return options.keys.sorted().map { "\($0)=\(options[$0] ?? "")" }.joined(separator: ", ")
    }

    private func setOptions(_ text: String, _ index: Int) {
        var all = rows
        guard all.indices.contains(index) else { return }
        let options = Self.parseOptions(text)
        all[index]["options"] = options.isEmpty ? nil : options
        model.set(all, at: ["keywords"])
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
        HStack(alignment: .top, spacing: 20) {
            FormSection(title: L("ask.workflow.editor.argument"), hint: L("ask.workflow.editor.argument.hint")) {
                HStack(spacing: 8) {
                    ForEach([AskWorkflowManifest.Input.Argument.required, .optional, .none], id: \.self) { value in
                        AskWorkflowOptionCard(title: L("ask.workflow.editor.argument." + value.rawValue),
                                              detail: L("ask.workflow.editor.argumentDetail." + value.rawValue),
                                              selected: (manifest?.input.argument ?? .optional) == value) {
                            model.set(value.rawValue, at: ["input", "argument"])
                        }
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            FormSection(title: L("ask.workflow.trust.selection"), hint: L("ask.workflow.editor.selection.hint")) {
                HStack(spacing: 8) {
                    ForEach([AskWorkflowManifest.Input.Selection.ifEmpty, .always, .never], id: \.self) { value in
                        AskWorkflowOptionCard(title: L("ask.workflow.editor.selection." + value.rawValue),
                                              detail: L("ask.workflow.editor.selectionDetail." + value.rawValue),
                                              selected: (manifest?.input.selection ?? .ifEmpty) == value) {
                            model.set(value.rawValue, at: ["input", "selection"])
                        }
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        FormSection(title: L("ask.workflow.editor.args"), hint: L("ask.workflow.editor.args.hint")) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text(program).font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(StudioTheme.textSecondary)
                    ForEach(Array(template.enumerated()), id: \.offset) { index, _ in
                        HStack(spacing: 3) {
                            Text("$\(index + 1)").font(.system(size: 10)).foregroundStyle(StudioTheme.textTertiary)
                            TextField("", text: argument(index)).font(.system(size: 12, design: .monospaced))
                                .textFieldStyle(.plain).frame(minWidth: 60, maxWidth: 150).fixedSize()
                            Button { removeArgument(index) } label: { Image(systemName: "xmark") }
                                .buttonStyle(.borderless).font(.system(size: 8))
                                .foregroundStyle(StudioTheme.textTertiary)
                        }
                        .padding(.horizontal, 7).frame(height: 24)
                        .overlay(RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(StudioTheme.border, style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                    }
                    Button { setTemplate(template + [""]) } label: { Image(systemName: "plus") }
                        .buttonStyle(.borderless)
                    Spacer()
                }
                .padding(10)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(StudioTheme.border))
                HStack(spacing: 6) {
                    Text(L("ask.workflow.editor.args.insert")).font(.system(size: 11.5))
                        .foregroundStyle(StudioTheme.textTertiary)
                    ForEach(tokens, id: \.self) { token in
                        Button { setTemplate(template + [token]) } label: { AskWorkflowChip(text: token, style: .token)
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                    if let keyword = manifest?.keywords.first?.keyword {
                        HStack(spacing: 4) {
                            Text(L("ask.workflow.editor.args.example"))
                            AskWorkflowChip(text: keyword)
                            Text(sampleQuery).font(.system(size: 11.5, design: .monospaced))
                        }
                        .font(.system(size: 11.5)).foregroundStyle(StudioTheme.textTertiary)
                    }
                }
                Text(preview).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(StudioTheme.textSecondary)
                    .textSelection(.enabled).padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(StudioTheme.controlSurface, in: RoundedRectangle(cornerRadius: 8))
            }
        }
        problemsText(model.problems(for: .input))
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
        return "argv  " + AskWorkflowAuthorTools.json(argv) + "\nstdin " + AskWorkflowAuthorTools.json(stdin)
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

/// What the script prints, when it runs, its limits, runtime and variables, with
/// the launcher as it would look on the right.
struct AskWorkflowOutputForm: View {
    @ObservedObject var model: AskWorkflowEditorModel

    private var manifest: AskWorkflowManifest? {
        model.draft?.manifest
    }

    var body: some View {
        HStack(alignment: .top, spacing: 22) {
            VStack(alignment: .leading, spacing: 20) {
                outputChoices
                runChoices
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            FormSection(title: L("ask.workflow.editor.preview.title"), hint: L("ask.workflow.editor.preview.hint")) {
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
            .frame(width: 300)
        }
        limits
        problemsText(model.problems(for: .output) + model.problems(for: .script))
    }

    private var outputChoices: some View {
        FormSection(title: L("ask.workflow.editor.output"), hint: L("ask.workflow.editor.output.hint")) {
            let current = manifest?.output ?? .auto
            Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    card(.text, current)
                    card(.none, current)
                }
                GridRow {
                    card(.auto, current)
                    AskWorkflowOptionCard(title: L("ask.workflow.editor.output.items"),
                                          detail: L("ask.workflow.editor.outputDetail.items"), selected: false,
                                          comingIn: "W2") {}
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func card(_ value: AskWorkflowManifest.Output, _ current: AskWorkflowManifest.Output) -> some View {
        AskWorkflowOptionCard(title: L("ask.workflow.editor.output." + value.rawValue),
                              detail: L("ask.workflow.editor.outputDetail." + value.rawValue),
                              selected: current == value) { model.set(value.rawValue, at: ["output"]) }
    }

    private var runChoices: some View {
        FormSection(title: L("ask.workflow.editor.runMode"), hint: nil) {
            HStack(spacing: 8) {
                AskWorkflowOptionCard(title: L("ask.workflow.editor.runMode.onSubmit"),
                                      detail: L("ask.workflow.editor.runMode.onSubmitDetail"),
                                      selected: (manifest?.run.mode ?? .onSubmit) == .onSubmit) {
                    model.set("onSubmit", at: ["run", "mode"])
                }
                AskWorkflowOptionCard(title: L("ask.workflow.editor.runMode.live"),
                                      detail: L("ask.workflow.editor.runMode.liveDetail"), selected: false,
                                      comingIn: "W2") {}
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var limits: some View {
        FormSection(title: L("ask.workflow.editor.limits"), hint: nil) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text(L("ask.workflow.editor.timeout")).foregroundStyle(StudioTheme.textSecondary)
                    HStack {
                        Slider(value: Binding(get: { manifest?.timeout ?? AskWorkflowManifest.defaultTimeout },
                                              set: { model.set(Int($0.rounded()), at: ["run", "timeoutSeconds"]) }),
                               in: 1 ... 120)
                        TextField(
                            "",
                            value: Binding(get: { Int(manifest?.timeout ?? AskWorkflowManifest.defaultTimeout) },
                                           set: { model.set(
                                               min(300, max(1, $0)),
                                               at: ["run", "timeoutSeconds"]
                                           ) }),
                            format: .number
                        )
                        .frame(width: 44).multilineTextAlignment(.trailing)
                        Text(L("ask.workflow.editor.secondsUnit")).foregroundStyle(StudioTheme.textTertiary)
                    }
                }
                GridRow {
                    Text(L("ask.workflow.editor.runtime")).foregroundStyle(StudioTheme.textSecondary)
                    HStack {
                        Picker("", selection: Binding(get: { manifest?.command.runtime ?? .python3 },
                                                      set: { model.set($0.rawValue, at: ["command", "runtime"]) })) {
                            ForEach(AskWorkflowRuntime.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        .labelsHidden().frame(width: 140)
                        TextField(L("ask.workflow.editor.interpreterAuto", model.runtimeInfo ?? "…"), text: Binding(
                            get: { model.draft?.value(at: ["command", "interpreter"]) as? String ?? "" },
                            set: { model.set($0.isEmpty ? nil : $0, at: ["command", "interpreter"]) }
                        ))
                        .font(.system(size: 12, design: .monospaced))
                    }
                }
                GridRow {
                    Text(L("ask.workflow.editor.script")).foregroundStyle(StudioTheme.textSecondary)
                    TextField("main.py", text: Binding(
                        get: { model.draft?.value(at: ["command", "script"]) as? String ?? "" },
                        set: { model.set($0.isEmpty ? nil : $0, at: ["command", "script"]) }
                    ))
                    .font(.system(size: 12, design: .monospaced))
                }
                GridRow(alignment: .top) {
                    Text(L("ask.workflow.editor.env")).foregroundStyle(StudioTheme.textSecondary)
                    VStack(alignment: .leading, spacing: 4) {
                        DraftField(placeholder: "", value: envText, multiline: true) { setEnv($0) }
                            .font(.system(size: 12, design: .monospaced)).frame(height: 56)
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(StudioTheme.border))
                        Text(L("ask.workflow.editor.env.hint")).font(.system(size: 11))
                            .foregroundStyle(StudioTheme.textTertiary)
                    }
                }
            }
            .textFieldStyle(.roundedBorder).font(.system(size: 12.5))
        }
    }

    /// One `NAME=value` per line.
    private var envText: String {
        let env = model.draft?.value(at: ["env"]) as? [String: String] ?? [:]
        return env.keys.sorted().map { "\($0)=\(env[$0] ?? "")" }.joined(separator: "\n")
    }

    private func setEnv(_ text: String) {
        var env: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let pair = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if pair.count == 2, !pair[0].isEmpty {
                env[pair[0]] = pair[1]
            }
        }
        model.set(env.isEmpty ? nil : env, at: ["env"])
    }
}
