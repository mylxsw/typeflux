import SwiftUI

/// New workflow: describe it and let the assistant write it, start from a template,
/// or copy the open one. Name and keyword are checked as they are typed.
struct AskWorkflowNewSheet: View {
    enum Mode: String, Identifiable, CaseIterable {
        case assistant, template, duplicate
        var id: String {
            rawValue
        }
    }

    @ObservedObject var model: AskWorkflowEditorModel
    @State var mode: Mode
    var done: () -> Void

    @State private var description = ""
    @State private var name = ""
    @State private var keyword = ""
    @State private var id = ""
    @State private var editedID = false
    @State private var template: AskWorkflowTemplate = .pythonText
    @State private var runtime: AskWorkflowRuntime?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("ask.workflow.editor.new.title")).font(.system(size: 15, weight: .semibold))
            Picker("", selection: $mode) {
                Label(L("ask.workflow.editor.new.ai"), systemImage: "sparkles").tag(Mode.assistant)
                Text(L("ask.workflow.editor.new.template")).tag(Mode.template)
                if model.workflow != nil {
                    Text(L("ask.workflow.editor.duplicate")).tag(Mode.duplicate)
                }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            switch mode {
            case .assistant: assistantFields
            case .template: templateFields
            case .duplicate:
                Text(L("ask.workflow.editor.new.duplicateHint", model.draft?.manifest?.name ?? model.workflowID ?? ""))
                    .font(.system(size: 12)).foregroundStyle(StudioTheme.textSecondary)
            }
            HStack(alignment: .top, spacing: 12) {
                field(
                    L("ask.workflow.editor.name"),
                    text: $name,
                    placeholder: L("ask.workflow.editor.new.namePlaceholder")
                )
                VStack(alignment: .leading, spacing: 4) {
                    field(L("ask.workflow.trust.keywords"), text: $keyword, placeholder: "fx", mono: true)
                    if !keyword.isEmpty {
                        if let problem = keywordProblem {
                            Text(problem).font(.system(size: 11)).foregroundStyle(StudioTheme.danger)
                        } else {
                            Text(L("ask.workflow.editor.new.keywordFree")).font(.system(size: 11))
                                .foregroundStyle(StudioTheme.success)
                        }
                    }
                }
                .frame(width: 150)
                field(L("ask.workflow.editor.new.id"), text: Binding(get: { id }, set: { id = $0; editedID = true }),
                      placeholder: "local.workflow", mono: true)
            }
            HStack {
                Text(mode == .assistant ? L("ask.workflow.editor.new.aiFootnote") :
                    L("ask.workflow.editor.new.footnote"))
                    .font(.system(size: 11.5)).foregroundStyle(StudioTheme.textTertiary).fixedSize(
                        horizontal: false,
                        vertical: true
                    )
                Spacer()
                Button(L("ask.workflow.cancel"), action: done).keyboardShortcut(.cancelAction)
                Button(mode == .assistant ? L("ask.workflow.editor.new.generate") :
                    L("ask.workflow.editor.new.create")) { create() }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(!canCreate)
                    .accessibilityIdentifier("ask.workflow.editor.new.create")
            }
        }
        .padding(22)
        .frame(width: 640)
        .onChange(of: name) { newValue in
            if !editedID {
                id = model.store.suggestedID(for: newValue.isEmpty ? keyword : newValue)
            }
        }
        .onChange(of: keyword) { newValue in
            if !editedID, name.isEmpty {
                id = model.store.suggestedID(for: newValue)
            }
        }
        .onAppear {
            if mode == .duplicate, let source = model.draft?.manifest {
                name = source.name + " " + L("ask.workflow.editor.new.copySuffix")
            }
        }
    }

    private var assistantFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextEditor(text: $description).font(.system(size: 13)).frame(height: 96)
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.purple.opacity(0.5)))
                .overlay(alignment: .topLeading) {
                    if description.isEmpty {
                        Text(L("ask.workflow.editor.new.aiPlaceholder")).font(.system(size: 13))
                            .foregroundStyle(StudioTheme.textTertiary).padding(6).allowsHitTesting(false)
                    }
                }
                .accessibilityIdentifier("ask.workflow.editor.new.description")
            HStack(spacing: 6) {
                Text(L("ask.workflow.editor.new.examples")).font(.system(size: 11.5))
                    .foregroundStyle(StudioTheme.textTertiary)
                ForEach(["markdown", "ip", "code"], id: \.self) { example in
                    Button(L("ask.workflow.editor.new.example." + example)) {
                        description = L("ask.workflow.editor.new.example." + example + ".text")
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                }
            }
            Picker(L("ask.workflow.editor.new.language"), selection: $runtime) {
                Text(L("ask.workflow.editor.new.languageAuto")).tag(AskWorkflowRuntime?.none)
                ForEach([AskWorkflowRuntime.python3, .node, .zsh], id: \.self) { Text($0.title).tag(Optional($0)) }
            }
            .fixedSize()
        }
    }

    private var templateFields: some View {
        Picker(L("ask.workflow.editor.new.template"), selection: $template) {
            ForEach(AskWorkflowTemplate.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.radioGroup)
    }

    private func field(_ title: String, text: Binding<String>, placeholder: String, mono: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 11)).foregroundStyle(StudioTheme.textTertiary)
            TextField(placeholder, text: text).textFieldStyle(.roundedBorder)
                .font(mono ? .system(size: 12.5, design: .monospaced) : .system(size: 12.5))
        }
    }

    private var keywordProblem: String? {
        model.store.keywordProblem(keyword, builtIn: model.builtInKeywords)
    }

    private var canCreate: Bool {
        guard !keyword.isEmpty, keywordProblem == nil, AskWorkflowManifest.isValidID(id) else { return false }
        return mode != .assistant || !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func create() {
        let finalName = name.trimmingCharacters(in: .whitespaces)
        let created: Bool = switch mode {
        case .assistant:
            model.generate(description: description, name: finalName, keyword: keyword, id: id, runtime: runtime)
        case .template:
            model.create(template, name: finalName, keyword: keyword, id: id)
        case .duplicate:
            model.duplicate(model.workflowID ?? "", name: finalName, keyword: keyword, id: id)
        }
        if created {
            done()
        }
    }
}
