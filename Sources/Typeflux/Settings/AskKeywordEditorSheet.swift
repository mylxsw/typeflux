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
        VStack(alignment: .leading, spacing: 0) {
            header.padding(.horizontal, 22).padding(.top, 20).padding(.bottom, 14)
            VStack(alignment: .leading, spacing: 12) {
                field(L("ask.settings.keywords.keyword")) {
                    TextField(placeholderKeyword, text: $draft.keyword)
                        .textFieldStyle(ModelFieldStyle())
                        .focused($keywordFocused)
                        .overlay(problemBorder(keywordProblem != nil))
                        .accessibilityIdentifier("ask.settings.keywords.sheet.keyword")
                    if let keywordProblem {
                        problem(keywordProblem)
                    }
                }
                kindFields
                field(L("ask.settings.keywords.sheet.preview")) { preview }
            }
            .padding(.horizontal, 22)
            footer.padding(.horizontal, 22).padding(.top, 18).padding(.bottom, 20)
        }
        .frame(width: 560)
        .background(ModelVisualStyle.canvas)
        .onAppear { keywordFocused = true }
    }

    private var header: some View {
        HStack(spacing: 12) {
            AskKeywordKindTile(kind: draft.kind, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(draft.isNew ? L("ask.settings.keywords.sheet.addTitle", draft.kind.title)
                    : L("ask.settings.keywords.sheet.editTitle"))
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(StudioTheme.textPrimary)
            }
        }
    }

    private var placeholderKeyword: String {
        switch draft.kind {
        case .translate: "fyja"
        case .prompt: "fix"
        case .web: "wiki"
        case .files: "ff"
        case .chat: "chat"
        case .prefix: "prefix"
        case .setting: "setting"
        case .history: "history"
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
                StudioSegmentedControl(options: [
                    (label: L("ask.settings.keywords.sheet.action.translate"), value: false),
                    (label: L("ask.settings.keywords.sheet.action.wordBook"), value: true)
                ], selection: $draft.opensWordBook, size: .compact)
                .accessibilityIdentifier("ask.settings.keywords.sheet.action")
                if draft.opensWordBook { hint(L("ask.settings.keywords.sheet.action.wordBookHint")) }
            }
            if !draft.opensWordBook {
                translateTargetField
                translateServiceField
            }
        case .prompt:
            field(L("ask.settings.keywords.name")) {
                TextField(draft.titlePlaceholder, text: $draft.title).textFieldStyle(ModelFieldStyle(monospaced: false))
            }
            field(L("ask.settings.plugins.prompt.prompt")) {
                TextEditor(text: $draft.prompt)
                    .font(.system(size: 12.5))
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .frame(minHeight: 120, maxHeight: 220)
                    .background(ModelVisualStyle.control, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(ModelVisualStyle.border))
                    .accessibilityIdentifier("ask.settings.keywords.sheet.prompt")
                HStack(spacing: 6) {
                    Button { draft.prompt += AskPromptPlugin.inputToken } label: {
                        Text(AskPromptPlugin.inputToken).font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(ModelVisualStyle.accent)
                            .padding(.horizontal, 7).frame(height: 20)
                            .background(ModelVisualStyle.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .help(L("ask.settings.plugins.prompt.insert"))
                    Text(L("ask.settings.keywords.sheet.insertInput")).font(.system(size: 11.5))
                        .foregroundStyle(StudioTheme.textTertiary)
                    Spacer()
                    if let preset = draft.presetPrompt, preset != draft.prompt {
                        Button(L("ask.settings.keywords.sheet.restorePreset")) { draft.restorePreset() }
                            .buttonStyle(.plain).font(.system(size: 11.5)).foregroundStyle(ModelVisualStyle.accent)
                    }
                }
                if let fieldProblem = draft.fieldProblem, !draft.isNew || !draft.prompt.isEmpty {
                    problem(fieldProblem)
                }
            }
        case .web:
            field(L("ask.settings.keywords.name")) {
                TextField(draft.titlePlaceholder, text: $draft.title).textFieldStyle(ModelFieldStyle(monospaced: false))
            }
            field(L("ask.settings.plugins.web.url")) {
                TextField("https://…?q={query}", text: $draft.url)
                    .textFieldStyle(ModelFieldStyle())
                    .overlay(problemBorder(draft.fieldProblem != nil))
                    .accessibilityIdentifier("ask.settings.keywords.sheet.url")
                if let fieldProblem = draft.fieldProblem {
                    problem(fieldProblem)
                }
                HStack(spacing: 6) {
                    ForEach(AskWebSearchPlugin.Engine.allCases, id: \.self) { engine in
                        Button(engine.title) { draft.use(engine) }
                            .buttonStyle(.plain).font(.system(size: 11.5))
                            .foregroundStyle(StudioTheme.textSecondary)
                            .padding(.horizontal, 9).frame(height: 20)
                            .background(ModelVisualStyle.control, in: Capsule())
                            .overlay(Capsule().strokeBorder(ModelVisualStyle.border))
                    }
                }
            }
        case .files, .chat, .prefix, .setting, .history, .workflow:
            EmptyView()
        }
    }

    /// The keyword as the launcher will show it, with sample text after it.
    private var preview: some View {
        HStack(spacing: 8) {
            Text((draft.keyword.isEmpty ? L("ask.settings.keywords.keyword") : draft.keyword) + " · " + draft
                .displayName)
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(ModelVisualStyle.accent)
                .padding(.horizontal, 8).frame(height: 22)
                .background(ModelVisualStyle.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 6))
                .lineLimit(1)
            Text(draft.kind == .web ? "swift actor" : "hello world").font(.system(size: 13))
                .foregroundStyle(StudioTheme.textPrimary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).frame(height: 38)
        .background(ModelVisualStyle.control, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(ModelVisualStyle.border))
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let onDelete {
                Button(role: .destructive, action: onDelete) {
                    Text(L("ask.settings.keywords.sheet.delete")).foregroundStyle(StudioTheme.danger)
                }
                .buttonStyle(ModelActionStyle())
                .accessibilityIdentifier("ask.settings.keywords.sheet.delete")
            }
            Spacer()
            Toggle(isOn: $draft.enabled) {
                Text(L("ask.settings.keywords.enabled")).font(.system(size: 12.5))
                    .foregroundStyle(StudioTheme.textSecondary)
            }
            .toggleStyle(.switch).controlSize(.small)
            .padding(.trailing, 6)
            Button(L("ask.workflow.cancel"), action: onCancel)
                .buttonStyle(ModelActionStyle())
                .keyboardShortcut(.cancelAction)
            Button(draft.isNew ? L("ask.settings.keywords.sheet.add") : L("ask.settings.keywords.save")) {
                onSave(draft.result())
            }
            .buttonStyle(ModelActionStyle(primary: true))
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!draft.canSave(among: keywords, workflows: workflows))
            .accessibilityIdentifier("ask.settings.keywords.sheet.save")
        }
    }

    private func field(_ label: String, @ViewBuilder content: () -> some View) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).font(.system(size: 12.5)).foregroundStyle(StudioTheme.textSecondary)
                .frame(width: 76, alignment: .leading)
            VStack(alignment: .leading, spacing: 5) { content() }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text).font(.system(size: 11.5)).foregroundStyle(StudioTheme.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func problem(_ text: String) -> some View {
        Text(text).font(.system(size: 11.5)).foregroundStyle(StudioTheme.warning)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func problemBorder(_ shown: Bool) -> some View {
        RoundedRectangle(cornerRadius: ModelVisualStyle.controlCornerRadius, style: .continuous)
            .strokeBorder(shown ? StudioTheme.warning : .clear)
    }
}
