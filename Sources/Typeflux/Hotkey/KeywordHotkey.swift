import Foundation

/// A global shortcut that runs a launcher keyword (`rw`, `fy`, a workflow's keyword)
/// on the selected text. Keywords have no stable id, so the shortcut keeps the word
/// it was saved with and the plugin, and finds the keyword again by both.
struct KeywordHotkey: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    /// Nil keeps the row so the user can record a new shortcut.
    var binding: HotkeyBinding?
    var keyword: String
    var pluginID: String
    var enabled: Bool

    init(id: UUID = UUID(), binding: HotkeyBinding?, keyword: String, pluginID: String, enabled: Bool = true) {
        self.id = id
        self.binding = binding
        self.keyword = keyword
        self.pluginID = pluginID
        self.enabled = enabled
    }

    private enum CodingKeys: String, CodingKey { case id, binding, keyword, pluginID, enabled }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        binding = try values.decodeIfPresent(HotkeyBinding.self, forKey: .binding)
        keyword = try values.decode(String.self, forKey: .keyword)
        pluginID = try values.decode(String.self, forKey: .pluginID)
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }

    /// The keyword this shortcut runs among `keywords`: one with the saved word for the same
    /// plugin. A workflow is its own plugin, so after its keyword was renamed in the workflow
    /// editor its only keyword is still the one. Nil when the keyword is gone.
    func resolve(in keywords: [AskKeyword]) -> AskKeyword? {
        let samePlugin = keywords.filter { $0.pluginID == pluginID }
        if let exact = samePlugin.first(where: { $0.contains(keyword) }) {
            return exact
        }
        guard pluginID.hasPrefix(AskWorkflowPlugin.idPrefix), samePlugin.count == 1 else { return nil }
        return samePlugin[0]
    }

    /// Whether pressing the shortcut does something: it is on, has keys, and its keyword is there and on.
    func isActive(in keywords: [AskKeyword]) -> Bool {
        guard enabled, binding != nil, let keyword = resolve(in: keywords) else { return false }
        return keyword.enabled
    }
}

/// Why a keyword shortcut is paused while keeping its settings.
enum KeywordHotkeyStatus: Equatable {
    case active
    case disabled
    case unset
    case keywordMissing
    case keywordDisabled

    init(_ hotkey: KeywordHotkey, keywords: [AskKeyword]) {
        if hotkey.binding == nil {
            self = .unset
        } else if !hotkey.enabled {
            self = .disabled
        } else if let keyword = hotkey.resolve(in: keywords) {
            self = keyword.enabled ? .active : .keywordDisabled
        } else {
            self = .keywordMissing
        }
    }
}
