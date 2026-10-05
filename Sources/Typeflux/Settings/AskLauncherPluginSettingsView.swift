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

/// Settings → Agent → Built-in Tools → launcher plugins: the translation
/// keywords and the language translations go into.
struct AskLauncherPluginSettingsView: View {
    let settings: SettingsStore

    @State private var list = AskKeywordList(keywords: [])
    @State private var drafts: [String: String] = [:]
    @State private var problems: [String: String] = [:]
    @State private var secondLanguage = "en"

    private var interface: AppLanguage { AppLocalization.shared.language }
    private let pluginID = AskTranslatePlugin.id

    // The section around it draws the surface.
    var body: some View {
        Group {
            VStack(alignment: .leading, spacing: 0) {
                AgentSettingsRow(icon: "translate", title: L("ask.plugin.translate.title"),
                                 subtitle: L("ask.settings.plugins.translate.subtitle"), subtitleLineLimit: nil) {
                    EmptyView()
                }
                ModelRowDivider(leading: 66)
                ForEach(list.keywords(for: pluginID)) { keyword in
                    keywordRow(keyword)
                    if let problem = problems[keyword.id] {
                        Text(problem).font(.system(size: 11.5)).foregroundStyle(StudioTheme.warning)
                            .padding(.leading, 66).padding(.bottom, 6)
                    }
                }
                AgentSettingsActionRow(icon: "plus", title: L("ask.settings.keywords.add")) {
                    let added = list.add(pluginID: pluginID)
                    drafts[added.id] = added.keyword
                    save()
                }
                ModelRowDivider(leading: 66)
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
            }
        }
        .onAppear(perform: reload)
    }

    private func keywordRow(_ keyword: AskKeyword) -> some View {
        HStack(spacing: 10) {
            TextField("", text: Binding(get: { drafts[keyword.id] ?? keyword.keyword },
                                        set: { drafts[keyword.id] = $0 }))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12.5, design: .monospaced))
                .frame(width: 110)
                .onSubmit { rename(keyword) }
                .accessibilityLabel(L("ask.settings.keywords.keyword"))
            Picker("", selection: Binding(get: { keyword.options[AskTranslatePlugin.targetOption] ?? "" },
                                          set: { target in
                                              list.update(keyword) { $0.options[AskTranslatePlugin.targetOption] = target.isEmpty ? nil : target }
                                              save()
                                          })) {
                Text(L("ask.settings.plugins.translate.auto")).tag("")
                ForEach(AskTranslationLanguages.common, id: \.self) { code in
                    Text(L("ask.settings.plugins.translate.into", AskTranslationLanguages.name(code, in: interface))).tag(code)
                }
            }
            .labelsHidden().frame(width: 180)
            .accessibilityLabel(L("ask.settings.plugins.translate.target"))
            Spacer(minLength: 8)
            Toggle("", isOn: Binding(get: { keyword.enabled }, set: { enabled in
                list.update(keyword) { $0.enabled = enabled }
                save()
            }))
            .labelsHidden().toggleStyle(.switch)
            .accessibilityLabel(L("ask.settings.keywords.enabled"))
            AgentSettingsIconButton(systemImage: "minus", help: L("ask.remove")) {
                list.remove(keyword)
                problems[keyword.id] = nil
                save()
            }
        }
        .padding(.leading, 66).padding(.trailing, 18).padding(.vertical, 6)
    }

    private func rename(_ keyword: AskKeyword) {
        let text = drafts[keyword.id] ?? keyword.keyword
        if let problem = list.rename(keyword, to: text) {
            problems[keyword.id] = AskKeywordList.message(for: problem)
            return
        }
        problems[keyword.id] = nil
        drafts[keyword.id] = nil
        save()
    }

    private func setSecondLanguage(_ code: String) {
        secondLanguage = code
        settings.askTranslationSecondLanguage = code
    }

    private func reload() {
        list = AskKeywordList(keywords: settings.askLauncherKeywords ?? AskPluginRegistry.defaultKeywords)
        secondLanguage = settings.askTranslationSecondLanguage ?? AskTranslationLanguages.defaultSecond(for: interface)
    }

    private func save() { settings.askLauncherKeywords = list.keywords }
}
