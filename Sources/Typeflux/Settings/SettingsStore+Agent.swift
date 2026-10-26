import Foundation

extension SettingsStore {
    static let defaultAskAgentMaxSteps = 200
    static let askAgentMaxStepOptions = [50, 100, 200, 500, 1000]

    /// Maximum model replies in each new Ask run. The server applies its own bound.
    var askAgentMaxSteps: Int {
        get {
            let value = defaults.integer(forKey: "ask.agentMaxSteps")
            return (10 ... 1000).contains(value) ? value : Self.defaultAskAgentMaxSteps
        }
        set { defaults.set(min(max(newValue, 10), 1000), forKey: "ask.agentMaxSteps") }
    }

    /// Preserve a previously saved step limit. Fresh installs use continuous execution.
    var askAgentExecutionMode: AskExecutionMode {
        get {
            if let raw = defaults.string(forKey: "ask.executionMode"), let mode = AskExecutionMode(rawValue: raw) { return mode }
            return defaults.object(forKey: "ask.agentMaxSteps") == nil ? .continuous : .bounded
        }
        set { defaults.set(newValue.rawValue, forKey: "ask.executionMode") }
    }

    var askAgentRequestedMaxSteps: Int? { askAgentExecutionMode == .bounded ? askAgentMaxSteps : nil }

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

    /// Whether Ask may offer individually approved commands on this Mac.
    var askCodeExecutionEnabled: Bool {
        get { defaults.object(forKey: "ask.codeExecutionEnabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "ask.codeExecutionEnabled") }
    }

    /// Whether the Ask launcher shows the result of arithmetic typed into it.
    var askQuickCalculatorEnabled: Bool {
        get { defaults.object(forKey: "ask.quickResults.calculator") as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: "ask.quickResults.calculator")
            NotificationCenter.default.post(name: .askLauncherSearchSettingsDidChange, object: self)
        }
    }

    /// Whether plain numeric input offers conversions independently of arithmetic.
    var askQuickNumberConversionsEnabled: Bool {
        get { defaults.object(forKey: "ask.quickResults.numberConversions") as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: "ask.quickResults.numberConversions")
            NotificationCenter.default.post(name: .askLauncherSearchSettingsDidChange, object: self)
        }
    }

    /// Whether the Ask launcher lists applications matching what is typed into it.
    var askQuickAppSearchEnabled: Bool {
        get { defaults.object(forKey: "ask.quickResults.apps") as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: "ask.quickResults.apps")
            NotificationCenter.default.post(name: .askLauncherSearchSettingsDidChange, object: self)
        }
    }

    /// Whether the Ask launcher lists files and folders matching what is typed into it.
    var askQuickFileSearchEnabled: Bool {
        get { defaults.object(forKey: "ask.quickResults.files") as? Bool ?? true }
        set {
            revokeSemanticScope(before: semanticScopeFingerprint(fileSearchEnabled: newValue))
            defaults.set(newValue, forKey: "ask.quickResults.files")
            NotificationCenter.default.post(name: .askLauncherSearchSettingsDidChange, object: self)
        }
    }

    /// How the launcher searches applications and files (Settings › Launcher › Search).
    var askLauncherSearchSettings: AskLauncherSearchSettings {
        get {
            guard let data = defaults.data(forKey: "ask.search.settings"),
                  let settings = try? JSONDecoder().decode(AskLauncherSearchSettings.self, from: data) else { return AskLauncherSearchSettings() }
            return settings
        }
        set {
            var settings = newValue
            settings.mode = .mixed
            if let data = try? JSONEncoder().encode(settings) {
                revokeSemanticScope(before: semanticScopeFingerprint(names: settings))
                defaults.set(data, forKey: "ask.search.settings")
            }
            NotificationCenter.default.post(name: .askLauncherSearchSettingsDidChange, object: self)
        }
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
            NotificationCenter.default.post(name: .askLauncherSearchSettingsDidChange, object: self)
        }
    }

    /// The plugins `askLauncherKeywords` was saved with, so plugins added later bring their keywords.
    var askLauncherKeywordPlugins: [String]? {
        get { defaults.stringArray(forKey: "ask.launcher.keywordPlugins") }
        set { defaults.set(newValue, forKey: "ask.launcher.keywordPlugins") }
    }

    /// Whether the launcher opens centred or where it was last dragged.
    var askLauncherPosition: AskLauncherPosition {
        get { defaults.string(forKey: "ask.launcher.position").flatMap(AskLauncherPosition.init(rawValue:)) ?? .center }
        set {
            defaults.set(newValue.rawValue, forKey: "ask.launcher.position")
            // Centring forgets the old positions, so remembering again starts afresh.
            if newValue == .center { askLauncherAnchors = [:] }
        }
    }

    /// Where the launcher was last left on each display, by `AskLauncherPlacement.key(for:)`.
    var askLauncherAnchors: [String: AskLauncherPlacement.Anchor] {
        get {
            guard let data = defaults.data(forKey: "ask.launcher.anchors") else { return [:] }
            return (try? JSONDecoder().decode([String: AskLauncherPlacement.Anchor].self, from: data)) ?? [:]
        }
        set {
            if newValue.isEmpty {
                defaults.removeObject(forKey: "ask.launcher.anchors")
            } else if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: "ask.launcher.anchors")
            }
        }
    }

    /// The language translations go into when the text is already in the
    /// interface language. Nil follows the interface: English, or Simplified Chinese.
    var askTranslationSecondLanguage: String? {
        get { defaults.string(forKey: "ask.translation.secondLanguage") }
        set { defaults.set(newValue, forKey: "ask.translation.secondLanguage") }
    }

    /// Whether looked-up words go into the word book; starring still works when off.
    var askWordBookRecordsHistory: Bool {
        get { defaults.object(forKey: "ask.wordBook.recordsHistory") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "ask.wordBook.recordsHistory") }
    }

    /// How long lookups that are not starred stay in the word book.
    var askWordBookRetention: AskWordBookRetention {
        get { defaults.string(forKey: "ask.wordBook.retention").flatMap(AskWordBookRetention.init(rawValue:)) ?? .default }
        set { defaults.set(newValue.rawValue, forKey: "ask.wordBook.retention") }
    }

    /// Skills the user turned off; they are not offered to the model.
    var askDisabledSkills: Set<String> {
        get { Set(defaults.stringArray(forKey: "ask.disabledSkills") ?? []) }
        set { defaults.set(newValue.sorted(), forKey: "ask.disabledSkills") }
    }

    /// Whether the agent gets the `notebook` tool and skill for the user's notes.
    var askNotebookAgentEnabled: Bool {
        get { defaults.object(forKey: "ask.notebook.agentEnabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "ask.notebook.agentEnabled") }
    }

    /// Notes with these tags do not exist for the agent.
    var askNotebookHiddenTags: [String] {
        get { defaults.stringArray(forKey: "ask.notebook.hiddenTags") ?? Self.defaultNotebookHiddenTags }
        set { defaults.set(newValue, forKey: "ask.notebook.hiddenTags") }
    }

    static let defaultNotebookHiddenTags = ["私密", "private"]

    /// New Ask conversations are kept on this Mac instead of Typeflux Cloud. The key
    /// predates per-conversation storage, when it switched all of Ask to this Mac,
    /// so users who had that on keep starting private conversations.
    var askNewConversationsStayLocal: Bool {
        get { defaults.bool(forKey: "ask.localMode") }
        set { defaults.set(newValue, forKey: "ask.localMode") }
    }
}

extension SettingsStore {
    var askFilePreviewEnabled: Bool {
        get { defaults.object(forKey: "ask.launcher.filePreview") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "ask.launcher.filePreview") }
    }
}
