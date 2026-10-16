import Foundation

/// One piece of work Typeflux runs in the background and shows in the menu bar:
/// a model download, an index build or an agent run.
struct BackgroundActivity: Identifiable, Equatable {
    enum Kind: Int, CaseIterable, Equatable {
        case agent
        case download
        case index
    }

    enum State: Equatable {
        /// Waiting for the user, such as an agent step that needs approval.
        case attention
        case failed
        case running
        /// Stopped by the user or by Typeflux (low power, heat, foreground work).
        case paused
        /// Holding back until the Mac is idle; uses no resources meanwhile.
        case waiting
    }

    enum Action: String, Equatable, CaseIterable {
        case open
        case stop
        case pause
        case resume
        case cancel
        case retry
        case dismiss
    }

    /// Where `open` takes the user.
    enum Route: Equatable {
        case speechModels
        case contentSearchSettings
        case conversation(String)
    }

    var id: String
    var kind: Kind
    var title: String
    var detail: String
    /// 0…1, or nil while the size of the work is unknown.
    var progress: Double?
    var state: State
    /// The buttons shown on the row, in order.
    var actions: [Action] = []
    var route: Route?

    /// Uses resources right now or waits for the user: the menu bar dot is on.
    var isActive: Bool {
        state == .running || state == .attention
    }

    var needsUser: Bool {
        state == .attention || state == .failed
    }

    var showsProgress: Bool {
        state == .running || state == .paused || state == .waiting
    }

    /// Needs the user first, then work under way, then work at rest.
    var rank: Int {
        switch state {
        case .attention: 0
        case .failed: 1
        case .running: 2
        case .paused: 3
        case .waiting: 4
        }
    }

    static func sorted(_ activities: [Self]) -> [Self] {
        activities.enumerated().sorted { lhs, rhs in
            if lhs.element.rank != rhs.element.rank {
                return lhs.element.rank < rhs.element.rank
            }
            if lhs.element.kind != rhs.element.kind {
                return lhs.element.kind.rawValue < rhs.element.kind.rawValue
            }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }
}

/// The dot beside the menu bar icon.
enum BackgroundActivityIndicator: Equatable {
    case none
    case running
    case attention

    static func of(_ activities: [BackgroundActivity]) -> Self {
        if activities.contains(where: \.needsUser) {
            return .attention
        }
        if activities.contains(where: { $0.state == .running }) {
            return .running
        }
        return .none
    }
}

/// Background work that finished successfully while Typeflux watched it.
struct BackgroundActivityCompletion: Identifiable, Equatable {
    var id = UUID()
    var activityID: String
    var kind: BackgroundActivity.Kind
    var title: String
    var finishedAt: Date
    /// How long the work was observed running; nil when its start was not seen.
    var duration: TimeInterval?
    /// Whether finishing is worth a system notification; some owners already send their own.
    var notifies = false
}

enum BackgroundActivityFormat {
    static func percent(_ fraction: Double) -> String {
        "\(Int((min(1, max(0, fraction)) * 100).rounded()))%"
    }

    /// "120 MB / 310 MB".
    static func bytes(_ received: Int64, of total: Int64) -> String {
        L("activity.bytes", size(max(0, received)), size(max(0, total)))
    }

    /// "120 MB / 310 MB" for a fraction of a known total.
    static func bytes(fraction: Double, of total: Int64) -> String {
        bytes(Int64((Double(total) * min(1, max(0, fraction))).rounded()), of: total)
    }

    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func count(_ value: Int) -> String {
        value.formatted()
    }
}
