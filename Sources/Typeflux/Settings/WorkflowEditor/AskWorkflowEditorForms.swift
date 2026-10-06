import SwiftUI

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

/// Keywords as a table: keyword, title, preset options (`name=value, …`).
struct AskWorkflowKeywordsForm: View {
    @ObservedObject var model: AskWorkflowEditorModel

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
                    Color.clear.frame(width: 24)
                }
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(StudioTheme.textTertiary)
                .padding(.horizontal, 10).padding(.vertical, 6).background(StudioTheme.controlSurface)
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    let keyword = row["keyword"] as? String ?? ""
                    let problem = model.keywordProblem(keyword) ?? duplicateProblem(keyword, index: index)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 10) {
                            TextField("fx", text: binding(index, "keyword"))
                                .font(.system(size: 12, design: .monospaced)).frame(width: 120)
                            TextField(L("ask.workflow.editor.keywords.titlePlaceholder"), text: binding(index, "title"))
                            DraftField(placeholder: "to=cny", value: optionsText(index)) { setOptions($0, index) }
                                .font(.system(size: 12, design: .monospaced))
                            Button { remove(index) } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless).frame(width: 24).disabled(rows.count <= 1)
                        }
                        .textFieldStyle(.roundedBorder)
                        if let problem {
                            Text(problem).font(.system(size: 11.5)).foregroundStyle(StudioTheme.danger).padding(
                                .leading,
                                2
                            )
                        }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(problem == nil ? Color.clear : StudioTheme.danger.opacity(0.06))
                    Divider()
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

    private func duplicateProblem(_ keyword: String, index: Int) -> String? {
        let earlier = rows.prefix(index).compactMap { $0["keyword"] as? String }.map { AskKeyword(
            keyword: $0,
            pluginID: ""
        ) }
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
        HStack(alignment: .top, spacing: 24) {
            FormSection(title: L("ask.workflow.editor.argument"), hint: L("ask.workflow.editor.argument.hint")) {
                Picker("", selection: Binding(get: { manifest?.input.argument ?? .optional },
                                              set: { model.set($0.rawValue, at: ["input", "argument"]) })) {
                    ForEach([AskWorkflowManifest.Input.Argument.required, .optional, .none], id: \.self) {
                        Text(L("ask.workflow.editor.argument." + $0.rawValue)).tag($0)
                    }
                }
                .pickerStyle(.segmented).labelsHidden()
            }
            FormSection(title: L("ask.workflow.trust.selection"), hint: L("ask.workflow.editor.selection.hint")) {
                Picker("", selection: Binding(get: { manifest?.input.selection ?? .ifEmpty },
                                              set: { model.set($0.rawValue, at: ["input", "selection"]) })) {
                    ForEach([AskWorkflowManifest.Input.Selection.ifEmpty, .always, .never], id: \.self) {
                        Text(L("ask.workflow.editor.selection." + $0.rawValue)).tag($0)
                    }
                }
                .pickerStyle(.segmented).labelsHidden()
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
                                .textFieldStyle(.roundedBorder).frame(minWidth: 70, maxWidth: 160)
                            Button { removeArgument(index) } label: { Image(systemName: "xmark") }
                                .buttonStyle(.borderless).font(.system(size: 9))
                        }
                    }
                    Button { setTemplate(template + [""]) } label: { Image(systemName: "plus") }
                        .buttonStyle(.borderless)
                }
                HStack(spacing: 6) {
                    Text(L("ask.workflow.editor.args.insert")).font(.system(size: 11.5))
                        .foregroundStyle(StudioTheme.textTertiary)
                    ForEach(tokens, id: \.self) { token in
                        Button(token) { setTemplate(template + [token]) }
                            .font(.system(size: 11, design: .monospaced)).buttonStyle(.bordered).controlSize(.small)
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

    /// What the script would get for an example input with the first keyword.
    private var preview: String {
        guard let manifest else { return "" }
        let keyword = manifest.keywords.first
        let options = keyword?.options ?? [:]
        let query = model.testQuery.isEmpty ? "100 usd" : model.testQuery
        let selection: String? = manifest.input
            .selection == .always ? L("ask.workflow.editor.args.sampleSelection") : nil
        let argv = AskWorkflowManifest.arguments(
            manifest.argumentTemplate,
            query: query,
            selection: selection,
            options: options
        )
        let argvText = AskWorkflowAuthorTools.json(argv)
        var stdin: [String: Any] = [
            "typeflux": 1,
            "query": query,
            "keyword": keyword?.keyword ?? "",
            "options": options
        ]
        stdin["selection"] = selection ?? NSNull()
        return "argv  " + argvText + "\nstdin " + AskWorkflowAuthorTools.json(stdin)
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

/// What the script prints, when it runs, its limits, runtime and variables.
struct AskWorkflowOutputForm: View {
    @ObservedObject var model: AskWorkflowEditorModel

    private var manifest: AskWorkflowManifest? {
        model.draft?.manifest
    }

    var body: some View {
        FormSection(title: L("ask.workflow.editor.output"), hint: L("ask.workflow.editor.output.hint")) {
            Picker(
                "",
                selection: Binding(get: { manifest?.output ?? .auto }, set: { model.set($0.rawValue, at: ["output"]) })
            ) {
                ForEach([AskWorkflowManifest.Output.text, .none, .auto], id: \.self) {
                    Text(L("ask.workflow.editor.output." + $0.rawValue)).tag($0)
                }
            }
            .pickerStyle(.radioGroup).labelsHidden()
            Text(L("ask.workflow.editor.output.later")).font(.system(size: 11.5))
                .foregroundStyle(StudioTheme.textTertiary)
        }
        FormSection(title: L("ask.workflow.editor.limits"), hint: nil) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text(L("ask.workflow.editor.timeout")).foregroundStyle(StudioTheme.textSecondary)
                    HStack {
                        Slider(value: Binding(get: { manifest?.timeout ?? AskWorkflowManifest.defaultTimeout },
                                              set: { model.set(Int($0.rounded()), at: ["run", "timeoutSeconds"]) }),
                               in: 1 ... AskWorkflowManifest.maximumTimeout)
                        Text(L(
                            "ask.workflow.editor.seconds",
                            Int(manifest?.timeout ?? AskWorkflowManifest.defaultTimeout)
                        ))
                        .frame(width: 60, alignment: .trailing)
                    }
                }
                GridRow {
                    Text(L("ask.workflow.editor.runtime")).foregroundStyle(StudioTheme.textSecondary)
                    HStack {
                        Picker("", selection: Binding(get: { manifest?.command.runtime ?? .python3 },
                                                      set: { model.set($0.rawValue, at: ["command", "runtime"]) })) {
                            ForEach(AskWorkflowRuntime.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        .labelsHidden().frame(width: 150)
                        TextField(L("ask.workflow.editor.interpreter"), text: Binding(
                            get: { model.draft?.value(at: ["command", "interpreter"]) as? String ?? "" },
                            set: { model.set($0.isEmpty ? nil : $0, at: ["command", "interpreter"]) }
                        ))
                        .font(.system(size: 12, design: .monospaced))
                    }
                }
                GridRow {
                    Text(L("ask.workflow.editor.script")).foregroundStyle(StudioTheme.textSecondary)
                    TextField(
                        "main.py",
                        text: Binding(get: { model.draft?.value(at: ["command", "script"]) as? String ?? "" },
                                      set: {
                                          model.set($0.isEmpty ? nil : $0, at: ["command", "script"])
                                      })
                    )
                    .font(.system(size: 12, design: .monospaced))
                }
                GridRow(alignment: .top) {
                    Text(L("ask.workflow.editor.env")).foregroundStyle(StudioTheme.textSecondary)
                    VStack(alignment: .leading, spacing: 4) {
                        DraftField(placeholder: "", value: envText, multiline: true) { setEnv($0) }
                            .font(.system(size: 12, design: .monospaced)).frame(height: 70)
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(StudioTheme.border))
                        Text(L("ask.workflow.editor.env.hint")).font(.system(size: 11))
                            .foregroundStyle(StudioTheme.textTertiary)
                    }
                }
            }
            .textFieldStyle(.roundedBorder).font(.system(size: 12.5))
        }
        problemsText(model.problems(for: .output) + model.problems(for: .script))
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
