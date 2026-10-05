import Foundation

extension SettingsStore {
    var mcpServers: [MCPServerConfig] {
        get {
            guard let data = defaults.data(forKey: "agent.mcpServers"),
                  let servers = try? JSONDecoder().decode([MCPServerConfig].self, from: data)
            else {
                return []
            }
            return servers
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: "agent.mcpServers")
            }
            NotificationCenter.default.post(name: .agentConfigurationDidChange, object: self)
        }
    }

    /// Folders the Ask files tool may read and edit.
    var askFileAccessFolders: [String] {
        get { defaults.stringArray(forKey: "ask.fileAccessFolders") ?? [] }
        set {
            var seen = Set<String>()
            defaults.set(newValue.filter { !$0.isEmpty && seen.insert($0).inserted }, forKey: "ask.fileAccessFolders")
        }
    }

    /// Whether Ask may run programs in the local sandbox.
    var askCodeExecutionEnabled: Bool {
        get { defaults.object(forKey: "ask.codeExecutionEnabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "ask.codeExecutionEnabled") }
    }

    /// Whether the Ask launcher shows the result of arithmetic typed into it.
    var askQuickCalculatorEnabled: Bool {
        get { defaults.object(forKey: "ask.quickResults.calculator") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "ask.quickResults.calculator") }
    }

    /// Whether the Ask launcher lists applications matching what is typed into it.
    var askQuickAppSearchEnabled: Bool {
        get { defaults.object(forKey: "ask.quickResults.apps") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "ask.quickResults.apps") }
    }

    /// The launcher's keywords (`fy` → translate). Nil until the user edits them,
    /// so new plugins' default keywords keep arriving.
    var askLauncherKeywords: [AskKeyword]? {
        get {
            guard let data = defaults.data(forKey: "ask.launcher.keywords") else { return nil }
            return try? JSONDecoder().decode([AskKeyword].self, from: data)
        }
        set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: "ask.launcher.keywords")
            } else {
                defaults.removeObject(forKey: "ask.launcher.keywords")
            }
        }
    }

    /// The plugins `askLauncherKeywords` was saved with, so plugins added later bring their keywords.
    var askLauncherKeywordPlugins: [String]? {
        get { defaults.stringArray(forKey: "ask.launcher.keywordPlugins") }
        set { defaults.set(newValue, forKey: "ask.launcher.keywordPlugins") }
    }

    /// The language translations go into when the text is already in the
    /// interface language. Nil follows the interface: English, or Simplified Chinese.
    var askTranslationSecondLanguage: String? {
        get { defaults.string(forKey: "ask.translation.secondLanguage") }
        set { defaults.set(newValue, forKey: "ask.translation.secondLanguage") }
    }

    /// Skills the user turned off; they are not offered to the model.
    var askDisabledSkills: Set<String> {
        get { Set(defaults.stringArray(forKey: "ask.disabledSkills") ?? []) }
        set { defaults.set(newValue.sorted(), forKey: "ask.disabledSkills") }
    }

    /// New Ask conversations are kept on this Mac instead of Typeflux Cloud. The key
    /// predates per-conversation storage, when it switched all of Ask to this Mac,
    /// so users who had that on keep starting private conversations.
    var askNewConversationsStayLocal: Bool {
        get { defaults.bool(forKey: "ask.localMode") }
        set { defaults.set(newValue, forKey: "ask.localMode") }
    }
}
