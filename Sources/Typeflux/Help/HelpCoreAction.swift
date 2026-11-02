import SwiftUI

/// The four things Typeflux is built around, the same ones the welcome screen lists. The start
/// page teaches them in this order and the sidebar counts how many the user has tried.
enum HelpCoreAction: String, CaseIterable, Identifiable, Sendable {
    case voice
    case launcher
    case ring
    case chat

    var id: String { rawValue }

    var scene: OnboardingWelcomeHero.Scene {
        switch self {
        case .voice: .voice
        case .launcher: .launcher
        case .ring: .ring
        case .chat: .chat
        }
    }

    var verb: String { scene.verb }
    var name: String { scene.featureName }
    var symbol: String { scene.symbol }
    var tint: Color { scene.tint }
    var tryTitle: String { L("help.action.\(rawValue).try") }

    /// How to use it, in three short steps; the detail is shown on hover. The keys are drawn
    /// beside the action, so steps never name them.
    var steps: [(title: String, detail: String)] {
        (1 ... 3).map { step in
            let base = "help.action.\(rawValue).step\(step)"
            return (L(base + ".title"), L(base + ".detail"))
        }
    }
}

/// How often the core actions were used. Voice comes from the usage stats; the others have no
/// counter elsewhere, so their entry points record here. Shared through the defaults, which
/// the feature processes also read. It never leaves this Mac.
final class HelpCoreActionUsageStore {
    static let shared = HelpCoreActionUsageStore()

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private func key(_ action: HelpCoreAction) -> String { "help.coreActionUsage." + action.rawValue }

    func record(_ action: HelpCoreAction) {
        defaults.set(count(action) + 1, forKey: key(action))
    }

    func count(_ action: HelpCoreAction) -> Int {
        defaults.integer(forKey: key(action))
    }

    /// Everything known about each action, so people who used Typeflux before this counter
    /// existed are not told to start over: keyword uses count as launcher use, and answers as chat.
    func counts(keywordUses: Int, stats: UsageStatsStore) -> [HelpCoreAction: Int] {
        [
            .voice: count(.voice) + stats.dictationCount + stats.personaRewriteCount + stats.editSelectionCount,
            .launcher: count(.launcher) + keywordUses,
            .ring: count(.ring),
            .chat: count(.chat) + stats.askAnswerCount
        ]
    }
}

/// What the animated scenes show at a point in their cycle, kept apart from the drawing.
enum HelpSceneTimeline {
    /// The start of `text` typed so far: nothing before `start`, all of it from `end` on.
    static func revealed(_ text: String, phase: Double, start: Double = 0.05, end: Double = 0.7) -> String {
        guard end > start else { return text }
        let progress = min(max((phase - start) / (end - start), 0), 1)
        return String(text.prefix(Int((Double(text.count) * progress).rounded(.up))))
    }

    /// Which of `count` slices the pointer is on, moving on `stops` times a cycle.
    static func slice(phase: Double, count: Int, stops: [Int] = [2, 3, 0, 4]) -> Int {
        guard count > 0, !stops.isEmpty else { return 0 }
        let wrapped = min(max(phase, 0), 0.999_999)
        return stops[Int(wrapped * Double(stops.count))] % count
    }
}

/// Which keys of the keyboard drawing a shortcut uses.
enum HelpKeyboardMap {
    /// One key of the drawing: what it shows, its id, and its width relative to a letter.
    struct Key: Identifiable, Equatable {
        var label: String
        var id: String
        var width: CGFloat = 1

        init(_ label: String, id: String? = nil, width: CGFloat = 1) {
            self.label = label
            self.id = id ?? label
            self.width = width
        }
    }

    static let rows: [[Key]] = {
        func plain(_ labels: String) -> [Key] { labels.map { Key(String($0)) } }
        let functions: [Key] = [Key("esc")] + (1 ... 12).map { Key("F\($0)") }
        let numbers: [Key] = plain("`1234567890-=") + [Key("⌫", width: 1.6)]
        let upper: [Key] = [Key("⇥", width: 1.6)] + plain("QWERTYUIOP[]\\")
        let home: [Key] = [Key("⇪", width: 1.9)] + plain("ASDFGHJKL;'") + [Key("↩", width: 1.9)]
        let lower: [Key] = [Key("⇧", id: "⇧(L)", width: 2.4)] + plain("ZXCVBNM,./")
            + [Key("⇧", id: "⇧(R)", width: 2.4)]
        let bottom: [Key] = [
            Key("Fn"), Key("⌃", id: "⌃(L)"), Key("⌥", id: "⌥(L)"), Key("⌘", id: "⌘(L)", width: 1.3),
            Key("", id: "Space", width: 5), Key("⌘", id: "⌘(R)", width: 1.3), Key("⌥", id: "⌥(R)"),
            Key("←"), Key("↑"), Key("↓"), Key("→")
        ]
        return [functions, numbers, upper, home, lower, bottom]
    }()

    /// The ids to light for keycaps as `HelpKeys` draws them. A bare modifier means the left
    /// one; press counts like `×2`, and keys the drawing lacks, light nothing.
    static func keyIDs(for keys: [String]) -> Set<String> {
        let known = Set(rows.joined().map(\.id))
        return Set(keys.map { key -> String in
            switch key {
            case "⌘", "⌥", "⌃", "⇧": key + "(L)"
            case "⌃(R)": "⌃(L)"
            case "Tab": "⇥"
            case "Esc": "esc"
            default: key.count == 1 ? key.uppercased() : key
            }
        }).intersection(known)
    }
}
