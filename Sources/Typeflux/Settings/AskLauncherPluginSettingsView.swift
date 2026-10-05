import SwiftUI

/// Edits the launcher's keywords for one plugin. Pure, so renaming, adding and
/// removing can be tested without the settings window.
struct AskKeywordList: Equatable {
    var keywords: [AskKeyword]

    func keywords(for pluginID: String) -> [AskKeyword] { keywords.filter { $0.pluginID == pluginID } }

    /// Renames `keyword`, or says why it cannot be: empty, a space, taken…
    mutating func rename(_ keyword: AskKeyword, to text: String) -> AskKeywordMatcher.Problem? {
        let word = text.trimmingCharacters(in: .whitespaces)
        guard let index = keywords.firstIndex(of: keyword) else { return nil }
        if word.lowercased() == keyword.keyword.lowercased() { return nil }
        let others = keywords.enumerated().filter { $0.offset != index }.map(\.element)
        if let problem = AskKeywordMatcher.problem(with: word, among: others) { return problem }
        keywords[index].keyword = word
        return nil
    }

    /// A new keyword for the plugin, named after its first one plus a number.
    @discardableResult
    mutating func add(pluginID: String) -> AskKeyword {
        let base = keywords(for: pluginID).first?.keyword ?? "kw"
        var number = 2
        while keywords.contains(where: { $0.keyword.lowercased() == "\(base)\(number)" }) { number += 1 }
        let keyword = AskKeyword(keyword: "\(base)\(number)", pluginID: pluginID)
        keywords.append(keyword)
        return keyword
    }

    mutating func remove(_ keyword: AskKeyword) { keywords.removeAll { $0 == keyword } }

    mutating func update(_ keyword: AskKeyword, _ change: (inout AskKeyword) -> Void) {
        guard let index = keywords.firstIndex(of: keyword) else { return }
        change(&keywords[index])
    }

    /// Sets an option, removing it when the text is empty so the keyword's preset shows through.
    mutating func set(_ option: String, to value: String, on keyword: AskKeyword) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        update(keyword) { $0.options[option] = trimmed.isEmpty ? nil : value }
    }

    /// Saves a web search URL template, or says why it cannot be used.
    mutating func setURL(_ template: String, on keyword: AskKeyword) -> String? {
        let trimmed = template.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty, let problem = AskWebSearchPlugin.problem(with: trimmed) { return problem }
        set(AskWebSearchPlugin.urlOption, to: trimmed, on: keyword)
        return nil
    }

    static func message(for problem: AskKeywordMatcher.Problem) -> String {
        switch problem {
        case .empty: L("ask.settings.keywords.problem.empty")
        case .tooLong: L("ask.settings.keywords.problem.tooLong", AskKeywordMatcher.maximumLength)
        case .whitespace: L("ask.settings.keywords.problem.whitespace")
        case .slash: L("ask.settings.keywords.problem.slash")
        case .duplicate: L("ask.settings.keywords.problem.duplicate")
        }
    }
}

/// Settings → Agent → Built-in Tools → launcher keywords: each plugin's keywords
/// and what they preset (a target language, a prompt, a search URL), and the
/// language translations go into.
struct AskLauncherPluginSettingsView: View {
    let settings: SettingsStore

    @State private var list = AskKeywordList(keywords: [])
    /// Text being edited, by keyword and field, until it is submitted.
    @State private var drafts: [String: String] = [:]
    @State private var problems: [String: String] = [:]
    @State private var secondLanguage = "en"

    private var interface: AppLanguage { AppLocalization.shared.language }

    // The section around it draws the surface.
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            pluginHeader(icon: "translate", title: L("ask.plugin.translate.title"),
                         subtitle: L("ask.settings.plugins.translate.subtitle"))
            keywords(for: AskTranslatePlugin.id) { translateOptions($0) }
            AgentSettingsRow(icon: "globe", title: L("ask.settings.plugins.translate.second"),
                             subtitle: L("ask.settings.plugins.translate.secondSubtitle"), subtitleLineLimit: nil) {
                Picker("", selection: Binding(get: { secondLanguage }, set: setSecondLanguage)) {
                    ForEach(AskTranslationLanguages.common, id: \.self) { code in
                        Text(AskTranslationLanguages.name(code, in: interface)).tag(code)
                    }
                }
                .labelsHidden().frame(width: 160)
                .accessibilityLabel(L("ask.settings.plugins.translate.second"))
            }
            ModelRowDivider(leading: 0)
            pluginHeader(icon: "wand.and.stars", title: L("ask.plugin.prompt.title"),
                         subtitle: L("ask.settings.plugins.prompt.subtitle"))
            keywords(for: AskPromptPlugin.id) { promptOptions($0) }
            ModelRowDivider(leading: 0)
            pluginHeader(icon: "magnifyingglass", title: L("ask.plugin.web.title"),
                         subtitle: L("ask.settings.plugins.web.subtitle"))
            keywords(for: AskWebSearchPlugin.id) { webOptions($0) }
            ModelRowDivider(leading: 0)
            AgentSettingsActionRow(icon: "arrow.counterclockwise", title: L("ask.settings.keywords.restore")) {
                list = AskKeywordList(keywords: AskPluginRegistry.defaultKeywords)
                drafts = [:]
                problems = [:]
                settings.saveAskLauncherKeywords(nil)
            }
        }
        .onAppear(perform: reload)
    }

    private func pluginHeader(icon: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 0) {
            AgentSettingsRow(icon: icon, title: title, subtitle: subtitle, subtitleLineLimit: nil) { EmptyView() }
            ModelRowDivider(leading: 66)
        }
    }

    /// A plugin's keywords, each with its options below, and "Add keyword".
    private func keywords<Options: View>(for pluginID: String,
                                         @ViewBuilder options: @escaping (AskKeyword) -> Options) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(list.keywords(for: pluginID)) { keyword in
                VStack(alignment: .leading, spacing: 6) {
                    keywordRow(keyword)
                    options(keyword)
                    ForEach(problems.filter { $0.key.hasPrefix(keyword.id + "/") }.sorted { $0.key < $1.key },
                            id: \.key) { _, problem in
                        Text(problem).font(.system(size: 11.5)).foregroundStyle(StudioTheme.warning)
                    }
                }
                .padding(.leading, 66).padding(.trailing, 18).padding(.vertical, 6)
            }
            AgentSettingsActionRow(icon: "plus", title: L("ask.settings.keywords.add")) {
                let added = list.add(pluginID: pluginID)
                drafts[added.id + "/keyword"] = added.keyword
                save()
            }
            ModelRowDivider(leading: 66)
        }
    }

    private func keywordRow(_ keyword: AskKeyword) -> some View {
        HStack(spacing: 10) {
            TextField("", text: draft(keyword, "keyword", keyword.keyword))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12.5, design: .monospaced))
                .frame(width: 110)
                .onSubmit { rename(keyword) }
                .accessibilityLabel(L("ask.settings.keywords.keyword"))
            if keyword.pluginID == AskTranslatePlugin.id {
                translateTarget(keyword)
            } else {
                // A name for the chip: "Polish", "Wikipedia".
                TextField(nameFallback(keyword), text: draft(keyword, "title", keyword.options["title"] ?? ""))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
                    .onSubmit { submit(keyword, "title") { list.set("title", to: $0, on: keyword); return nil } }
                    .accessibilityLabel(L("ask.settings.keywords.name"))
            }
            Spacer(minLength: 8)
            Toggle("", isOn: Binding(get: { keyword.enabled }, set: { enabled in
                list.update(keyword) { $0.enabled = enabled }
                save()
            }))
            .labelsHidden().toggleStyle(.switch)
            .accessibilityLabel(L("ask.settings.keywords.enabled"))
            AgentSettingsIconButton(systemImage: "minus", help: L("ask.remove")) {
                list.remove(keyword)
                problems = problems.filter { !$0.key.hasPrefix(keyword.id + "/") }
                save()
            }
        }
    }

    private func translateTarget(_ keyword: AskKeyword) -> some View {
        Picker("", selection: Binding(get: { keyword.options[AskTranslatePlugin.targetOption] ?? "" },
                                      set: { target in
                                          list.set(AskTranslatePlugin.targetOption, to: target, on: keyword)
                                          save()
                                      })) {
            Text(L("ask.settings.plugins.translate.auto")).tag("")
            ForEach(AskTranslationLanguages.common, id: \.self) { code in
                Text(L("ask.settings.plugins.translate.into", AskTranslationLanguages.name(code, in: interface))).tag(code)
            }
        }
        .labelsHidden().frame(width: 180)
        .accessibilityLabel(L("ask.settings.plugins.translate.target"))
    }

    @ViewBuilder private func translateOptions(_ keyword: AskKeyword) -> some View { EmptyView() }

    /// The prompt, with `{input}` where the text goes; a preset's shows until it is changed.
    private func promptOptions(_ keyword: AskKeyword) -> some View {
        HStack(alignment: .top, spacing: 8) {
            TextField(AskPromptPlugin.template(of: keyword.options.filter { $0.key != AskPromptPlugin.promptOption })
                ?? L("ask.settings.plugins.prompt.placeholder"),
                text: draft(keyword, "prompt", keyword.options[AskPromptPlugin.promptOption] ?? ""), axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .lineLimit(2 ... 5)
                .onSubmit { savePrompt(keyword) }
                .accessibilityLabel(L("ask.settings.plugins.prompt.prompt"))
            Button(AskPromptPlugin.inputToken) {
                let key = keyword.id + "/prompt"
                drafts[key] = (drafts[key] ?? keyword.options[AskPromptPlugin.promptOption] ?? "") + AskPromptPlugin.inputToken
            }
            .help(L("ask.settings.plugins.prompt.insert"))
            Button(L("ask.settings.keywords.save")) { savePrompt(keyword) }
        }
    }

    /// The search URL, with `{query}` where the words go; a built-in engine's shows until it is changed.
    private func webOptions(_ keyword: AskKeyword) -> some View {
        TextField(AskWebSearchPlugin.engine(of: keyword.options.filter { $0.key != AskWebSearchPlugin.urlOption }).template,
                  text: draft(keyword, "url", keyword.options[AskWebSearchPlugin.urlOption] ?? ""))
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 12, design: .monospaced))
            .onSubmit { submit(keyword, "url") { list.setURL($0, on: keyword) } }
            .accessibilityLabel(L("ask.settings.plugins.web.url"))
    }

    private func nameFallback(_ keyword: AskKeyword) -> String {
        keyword.pluginID == AskWebSearchPlugin.id
            ? AskWebSearchPlugin.engine(of: keyword.options.filter { $0.key != "title" }).title
            : AskPromptPlugin.name(of: keyword.options.filter { $0.key != "title" })
    }

    private func draft(_ keyword: AskKeyword, _ field: String, _ saved: String) -> Binding<String> {
        Binding(get: { drafts[keyword.id + "/" + field] ?? saved }, set: { drafts[keyword.id + "/" + field] = $0 })
    }

    /// Applies a field's draft, or shows why it cannot be used.
    private func submit(_ keyword: AskKeyword, _ field: String, apply: (String) -> String?) {
        let key = keyword.id + "/" + field
        guard let text = drafts[key] else { return }
        if let problem = apply(text) { problems[key] = problem; return }
        problems[key] = nil
        drafts[key] = nil
        save()
    }

    private func savePrompt(_ keyword: AskKeyword) {
        submit(keyword, "prompt") { list.set(AskPromptPlugin.promptOption, to: $0, on: keyword); return nil }
    }

    private func rename(_ keyword: AskKeyword) {
        submit(keyword, "keyword") { text in
            list.rename(keyword, to: text).map(AskKeywordList.message(for:))
        }
    }

    private func setSecondLanguage(_ code: String) {
        secondLanguage = code
        settings.askTranslationSecondLanguage = code
    }

    private func reload() {
        list = AskKeywordList(keywords: settings.effectiveAskLauncherKeywords)
        secondLanguage = settings.askTranslationSecondLanguage ?? AskTranslationLanguages.defaultSecond(for: interface)
    }

    private func save() { settings.saveAskLauncherKeywords(list.keywords) }
}
