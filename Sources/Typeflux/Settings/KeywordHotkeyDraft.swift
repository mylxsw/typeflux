import Foundation

/// The keyword shortcut being added or edited. Nothing is saved until Save, which stays
/// off until a keyword and usable keys are chosen.
struct KeywordHotkeyDraft: Equatable {
    var hotkey: KeywordHotkey
    let isNew: Bool
    /// The user chose to move the keys from the keyword shortcut that has them.
    var takesKeys = false

    init(editing hotkey: KeywordHotkey) {
        self.hotkey = hotkey
        isNew = false
    }

    init(adding option: KeywordHotkeyOption?) {
        hotkey = KeywordHotkey(binding: nil, keyword: option?.keyword.keyword ?? "",
                               pluginID: option?.keyword.pluginID ?? "")
        isNew = true
    }

    var hasKeyword: Bool {
        !hotkey.keyword.isEmpty && !hotkey.pluginID.isEmpty
    }

    func selectedOption(in options: [KeywordHotkeyOption]) -> KeywordHotkeyOption? {
        options.first { $0.keyword.pluginID == hotkey.pluginID && $0.keyword.contains(hotkey.keyword) }
    }

    mutating func select(_ option: KeywordHotkeyOption) {
        hotkey.keyword = option.keyword.keyword
        hotkey.pluginID = option.keyword.pluginID
    }

    mutating func record(_ binding: HotkeyBinding) {
        hotkey.binding = binding
        takesKeys = false
    }

    /// The keyword shortcut whose keys would move here, when the user may take them.
    func keywordOwner(in result: HotkeyConflictChecker.Result?) -> UUID? {
        if case let .taken(.keyword(id))? = result?.problem {
            return id
        }
        return nil
    }

    func canSave(with result: HotkeyConflictChecker.Result?) -> Bool {
        guard hasKeyword, hotkey.binding != nil, let result else { return false }
        return result.canSave || (takesKeys && keywordOwner(in: result) != nil)
    }
}
