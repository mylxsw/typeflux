import SwiftUI

/// Edits or adds one launcher keyword. The fields follow the keyword's kind; nothing
/// is saved until Save, which stays off while the keyword or a field has a problem.
struct AskKeywordEditorSheet: View {
    @State var draft: AskKeywordDraft
    let keywords: [AskKeyword]
    let workflows: [AskWorkflowKeywordEntry]
    let onSave: (AskKeyword) -> Void
    var onDelete: (() -> Void)?
    let onCancel: () -> Void
    @FocusState private var keywordFocused: Bool

    private var interface: AppLanguage {
        AppLocalization.shared.language
    }

    private var keywordProblem: String? {
        draft.keyword.isEmpty ? nil : draft.keywordProblem(among: keywords, workflows: workflows)
    }

    var body: some View {
        TypefluxSheet(title: draft.isNew ? L("ask.settings.keywords.sheet.addTitle", draft.kind.title)
            : L("ask.settings.keywords.sheet.editTitle"),
            cancelTitle: L("ask.workflow.cancel"),
            confirmTitle: L(draft.isNew ? "ask.settings.keywords.sheet.add" : "ask.settings.keywords.save"),
            isConfirmEnabled: draft.canSave(among: keywords, workflows: workflows),
            confirmIdentifier: "ask.settings.keywords.sheet.save", cancel: onCancel,
            confirm: { onSave(draft.result()) }, content: {
                TypefluxForm {
                    Section {
                        field(L("ask.settings.keywords.defaultKeyword")) {
                            TextField(placeholderKeyword, text: $draft.keyword)
                                .textFieldStyle(.roundedBorder).focused($keywordFocused)
                                .accessibilityIdentifier("ask.settings.keywords.sheet.keyword")
                            if let keywordProblem {
                                problem(keywordProblem)
                            }
                        }
                        aliasFields
                    }
                    Section { kindFields }
                    Section {
                        field(L("ask.settings.keywords.sheet.preview")) { preview }
                        TypefluxSwitch(L("ask.settings.keywords.enabled"), isOn: $draft.enabled)
                        if let onDelete {
                            Button(L("ask.settings.keywords.sheet.delete"), role: .destructive, action: onDelete)
                                .accessibilityIdentifier("ask.settings.keywords.sheet.delete")
                        }
                    }
                }.frame(height: 440)
            }).frame(width: 560)
            .onAppear { keywordFocused = true }
    }

    private var aliasFields: some View {
        field(L("ask.settings.keywords.aliases")) {
            ForEach(draft.aliases.indices, id: \.self) { index in
                HStack(spacing: 8) {
                    TextField(L("ask.settings.keywords.alias"), text: $draft.aliases[index])
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("ask.settings.keywords.sheet.alias.\(index)")
                    TypefluxIconButton(L("ask.settings.keywords.removeAlias"), systemImage: "minus.circle") {
                        draft.aliases.remove(at: index)
                    }
                }
            }
            Button { draft.aliases.append("") } label: {
                Label(L("ask.settings.keywords.addAlias"), systemImage: "plus")
            }
            .buttonStyle(.plain).foregroundStyle(TypefluxColor.accent.color).font(.subheadline)
            .accessibilityIdentifier("ask.settings.keywords.sheet.addAlias")
            hint(L("ask.settings.keywords.aliasHint"))
        }
    }

    private var placeholderKeyword: String {
        switch draft.kind {
        case .translate: "fyja"
        case .prompt: "fix"
        case .web: "wiki"
        case .files: "ff"
        case .tabs: "tab"
        case .bookmarks: "bmk"
        case .chat: "chat"
        case .prefix: "prefix"
        case .setting: "setting"
        case .history: "history"
        case .clip: "clip"
        case .kill: "kill"
        case .emoji: "emoji"
        case .system: ""
        case .workflow: ""
        }
    }

    private var translateTargetField: some View {
        field(L("ask.settings.keywords.sheet.target")) {
            Picker("", selection: $draft.target) {
                Text(L("ask.settings.plugins.translate.auto")).tag("")
                ForEach(AskTranslationLanguages.common, id: \.self) { code in
                    Text(L(
                        "ask.settings.plugins.translate.into",
                        AskTranslationLanguages.name(code, in: interface)
                    ))
                    .tag(code)
                }
            }
            .labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel(L("ask.settings.plugins.translate.target"))
            hint(L("ask.settings.keywords.sheet.autoHint"))
        }
    }

    private var translateServiceField: some View {
        field(L("ask.settings.keywords.sheet.service")) {
            Picker("", selection: $draft.translationService) {
                Text(L("ask.settings.keywords.sheet.service.default")).tag("")
                ForEach(AskTranslationProvider.allCases) { provider in
                    Text(provider.title).tag(provider.rawValue)
                }
            }
            .labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel(L("ask.settings.keywords.sheet.service"))
            hint(L("ask.settings.keywords.sheet.serviceHint"))
        }
    }

    @ViewBuilder private var kindFields: some View {
        switch draft.kind {
        case .translate:
            field(L("ask.settings.keywords.sheet.action")) {
                TypefluxSegmentedControl(L("ask.settings.keywords.sheet.action"), selection: $draft.opensWordBook) {
                    Text(L("ask.settings.keywords.sheet.action.translate")).tag(false)
                    Text(L("ask.settings.keywords.sheet.action.wordBook")).tag(true)
                }.accessibilityIdentifier("ask.settings.keywords.sheet.action")
                if draft.opensWordBook {
                    hint(L("ask.settings.keywords.sheet.action.wordBookHint"))
                }
            }
            if !draft.opensWordBook {
                translateTargetField
                translateServiceField
            }
        case .prompt:
            field(L("ask.settings.keywords.name")) {
                TextField(draft.titlePlaceholder, text: $draft.title).textFieldStyle(.roundedBorder)
            }
            field(L("ask.settings.plugins.prompt.prompt")) {
                TextEditor(text: $draft.prompt)
                    .font(.subheadline)
                    .frame(minHeight: 120, maxHeight: 220)
                    .accessibilityIdentifier("ask.settings.keywords.sheet.prompt")
                HStack(spacing: 6) {
                    Button { draft.prompt += AskPromptPlugin.inputToken } label: {
                        Text(AskPromptPlugin.inputToken).font(.body.monospaced())
                    }.buttonStyle(.bordered)
                        .help(L("ask.settings.plugins.prompt.insert"))
                    Text(L("ask.settings.keywords.sheet.insertInput")).font(.subheadline)
                        .foregroundStyle(TypefluxColor.tertiaryLabel.color)
                    Spacer()
                    if let preset = draft.presetPrompt, preset != draft.prompt {
                        Button(L("ask.settings.keywords.sheet.restorePreset")) { draft.restorePreset() }
                            .buttonStyle(.plain).font(.subheadline).foregroundStyle(TypefluxColor.accent.color)
                    }
                }
                if let fieldProblem = draft.fieldProblem, !draft.isNew || !draft.prompt.isEmpty {
                    problem(fieldProblem)
                }
            }
        case .web:
            field(L("ask.settings.keywords.name")) {
                TextField(draft.titlePlaceholder, text: $draft.title).textFieldStyle(.roundedBorder)
            }
            field(L("ask.settings.plugins.web.url")) {
                TextField("https://…?q={query}", text: $draft.url)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("ask.settings.keywords.sheet.url")
                if let fieldProblem = draft.fieldProblem {
                    problem(fieldProblem)
                }
                HStack(spacing: 6) {
                    ForEach(AskWebSearchPlugin.Engine.allCases, id: \.self) { engine in
                        Button(engine.title) { draft.use(engine) }.buttonStyle(.bordered).controlSize(.small)
                    }
                }
            }
        case .kill:
            hint(L("ask.settings.keywords.kind.kill.hint"))
        case .emoji:
            hint(L("emoji.summary"))
        case .system:
            field(L("ask.system.title")) {
                Picker("", selection: $draft.systemCommand) {
                    ForEach(AskSystemCommand.allCases) { command in
                        Text(command.title).tag(command)
                    }
                }.labelsHidden()
                hint(L("ask.settings.keywords.kind.system.hint"))
            }
        case .files, .tabs, .bookmarks, .chat, .prefix, .setting, .history, .clip, .workflow:
            EmptyView()
        }
    }

    /// The keyword as the launcher will show it, with sample text after it.
    private var preview: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text((draft.keyword.isEmpty ? L("ask.settings.keywords.keyword") : draft.keyword) + " · " + draft
                .displayName)
                .font(.body.monospaced()).foregroundStyle(TypefluxColor.accent.color)
            Text(draft.kind == .web ? "swift actor" : "hello world").font(.body)
        }
    }

    private func field(_ label: String, @ViewBuilder content: () -> some View) -> some View {
        TypefluxSettingsRow(label) {
            VStack(alignment: .leading, spacing: 5) { content() }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text).font(.subheadline).foregroundStyle(TypefluxColor.tertiaryLabel.color)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func problem(_ text: String) -> some View {
        Text(text).font(.subheadline).foregroundStyle(TypefluxColor.warning.color)
            .fixedSize(horizontal: false, vertical: true)
    }
}
