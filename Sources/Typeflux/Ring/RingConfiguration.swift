import AppKit
import Foundation

/// The look of the ring. Liquid Glass needs macOS 26; OpieMenu falls back to Frosted before that.
enum RingStyle: String, CaseIterable, Codable, Identifiable, Sendable {
    case classic
    case frosted
    case liquidGlass

    var id: String {
        rawValue
    }

    var title: String {
        L("ring.style.\(rawValue)")
    }
}

/// Everything Settings → Ring stores.
struct RingConfiguration: Codable, Equatable, Sendable {
    /// More slices than this become too narrow to aim at.
    static let maxActions = 8
    static let defaultCenterTitle = "Typeflux"
    static let centerTitleLimit = 10
    /// ⌃⌥Space, offered once when nothing else uses it.
    static let defaultHotkey = HotkeyBinding(
        keyCode: 49,
        modifierFlags: UInt(NSEvent.ModifierFlags.control.union(.option).rawValue)
    )

    var actions: [RingAction]
    var style: RingStyle = .frosted
    var centerTitle = RingConfiguration.defaultCenterTitle

    init(actions: [RingAction] = RingConfiguration.defaultActions(),
         style: RingStyle = .frosted, centerTitle: String = RingConfiguration.defaultCenterTitle) {
        self.actions = actions
        self.style = style
        self.centerTitle = centerTitle
    }

    /// The defaults keep fixed ids, so every reader of an unsaved configuration sees the same slices.
    static func defaultActions() -> [RingAction] {
        let features: [RingFeature] = [.dictation, .ask, .translate, .screenshot, .screenshotText, .clipboard]
        return features.enumerated().map { index, feature in
            var action = RingAction.feature(feature)
            action.id = UUID(uuidString: String(format: "52494E47-0000-4000-8000-%012d", index + 1)) ?? action.id
            return action
        }
    }

    var canAddAction: Bool {
        actions.count < Self.maxActions
    }

    /// A configured shortcut can open the ring only when there is something to choose.
    var isUsable: Bool {
        !actions.isEmpty
    }

    /// Saved slice titles predate feature renames. Only replace former built-in names;
    /// preserve custom names, action ids, targets, symbols and order.
    mutating func migrateLegacyChatTitles() -> Bool {
        let legacyNames: Set<String> = [
            "随便问", "隨便問", "Ask", "Ask Anything", "なんでも質問", "무엇이든 질문"
        ]
        var changed = false
        for index in actions.indices {
            guard actions[index].kind == .feature(.ask), legacyNames.contains(actions[index].title) else { continue }
            actions[index].title = RingFeature.ask.title
            changed = true
        }
        return changed
    }

    private enum CodingKeys: String, CodingKey { case actions, style, centerTitle }

    /// Missing fields keep their defaults; an action written by a newer version is skipped
    /// instead of discarding the whole ring.
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        style = (try? values.decodeIfPresent(RingStyle.self, forKey: .style)) ?? .frosted
        centerTitle = try values.decodeIfPresent(String.self, forKey: .centerTitle) ?? Self.defaultCenterTitle
        if values.contains(.actions) {
            let decoded = try values.decode([LossyAction].self, forKey: .actions)
            actions = Array(decoded.compactMap(\.action).prefix(Self.maxActions))
        } else {
            actions = Self.defaultActions()
        }
    }

    private struct LossyAction: Decodable {
        let action: RingAction?

        init(from decoder: any Decoder) throws {
            action = try? RingAction(from: decoder)
        }
    }
}
