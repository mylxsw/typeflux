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

    /// The global actions: every app without a profile of its own.
    var actions: [RingAction]
    /// Per-app actions, in the order they were added. At most one per bundle identifier.
    var appProfiles: [RingAppProfile] = []
    var hoverSoundEnabled = true
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
        !actions.isEmpty || appProfiles.contains(where: \.isActive)
    }

    /// The profile the ring opens with while this app is in front: switched on and not empty.
    func profile(forBundleIdentifier bundleIdentifier: String?) -> RingAppProfile? {
        guard let bundleIdentifier else { return nil }
        return appProfiles.first { $0.bundleIdentifier == bundleIdentifier && $0.isActive }
    }

    /// Saved slice titles predate feature renames. Only replace former built-in names;
    /// preserve custom names, action ids, targets, symbols and order.
    mutating func migrateLegacyChatTitles() -> Bool {
        let legacyNames: Set = [
            "随便问", "隨便問", "Ask", "Ask Anything", "なんでも質問", "무엇이든 질문"
        ]
        func migrate(_ list: inout [RingAction]) -> Bool {
            var changed = false
            for index in list.indices {
                guard list[index].kind == .feature(.ask), legacyNames.contains(list[index].title) else { continue }
                list[index].title = RingFeature.ask.title
                changed = true
            }
            return changed
        }
        var changed = migrate(&actions)
        for index in appProfiles.indices where migrate(&appProfiles[index].actions) {
            changed = true
        }
        return changed
    }

    private enum CodingKeys: String, CodingKey { case actions, appProfiles, style, centerTitle, hoverSoundEnabled }

    /// Missing fields keep their defaults; an action written by a newer version is skipped
    /// instead of discarding the whole ring.
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        hoverSoundEnabled = try values.decodeIfPresent(Bool.self, forKey: .hoverSoundEnabled) ?? true
        style = (try? values.decodeIfPresent(RingStyle.self, forKey: .style)) ?? .frosted
        centerTitle = try values.decodeIfPresent(String.self, forKey: .centerTitle) ?? Self.defaultCenterTitle
        if values.contains(.actions) {
            let decoded = try values.decode([RingLossyAction].self, forKey: .actions)
            actions = Array(decoded.compactMap(\.action).prefix(Self.maxActions))
        } else {
            actions = Self.defaultActions()
        }
        // Files from before per-app actions have no profiles.
        let profiles = (try? values.decodeIfPresent([RingLossyProfile].self, forKey: .appProfiles)) ?? nil
        var seen = Set<String>()
        appProfiles = (profiles ?? []).compactMap(\.profile).filter { seen.insert($0.bundleIdentifier).inserted }
    }
}
