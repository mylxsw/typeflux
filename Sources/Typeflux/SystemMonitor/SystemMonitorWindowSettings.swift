import CoreGraphics
import Foundation

/// The three shapes of the monitor window.
enum SystemMonitorWindowMode: String, CaseIterable, Codable, Sendable {
    /// Metrics with charts and the busiest processes.
    case full
    /// Four small cards for a corner of the screen.
    case compact
    /// One line of figures, under the menu bar.
    case mini
}

/// What the monitor window remembers between launches.
struct SystemMonitorWindowSettings: Codable, Equatable, Sendable {
    static let defaultsKey = "SystemMonitorWindow"
    static let intervals: [TimeInterval] = [1, 2, 5]
    static let opacities: [Double] = [1, 0.85, 0.7]

    var mode: SystemMonitorWindowMode = .full
    /// Floats above other windows.
    var pinned = true
    /// Follows the user to every Space and full-screen app.
    var allSpaces = true
    /// Opens again at launch when it was open at quit.
    var restore = true
    /// Whether the window was open when last seen; `restore` decides whether that matters.
    var isOpen = false
    var interval: TimeInterval = 1
    var opacity: Double = 1
    /// The metrics shown, in card order.
    var metrics: [SystemMonitorMetric] = SystemMonitorMetric.allCases
    var sort: SystemMonitorSort = .cpu
    /// Where each mode was last put (and how big the full window was).
    var frames: [String: CGRect] = [:]

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Self()
        mode = (try? values.decodeIfPresent(SystemMonitorWindowMode.self, forKey: .mode)) ?? defaults.mode
        pinned = (try? values.decodeIfPresent(Bool.self, forKey: .pinned)) ?? defaults.pinned
        allSpaces = (try? values.decodeIfPresent(Bool.self, forKey: .allSpaces)) ?? defaults.allSpaces
        restore = (try? values.decodeIfPresent(Bool.self, forKey: .restore)) ?? defaults.restore
        isOpen = (try? values.decodeIfPresent(Bool.self, forKey: .isOpen)) ?? defaults.isOpen
        let interval = (try? values.decodeIfPresent(TimeInterval.self, forKey: .interval)) ?? defaults.interval
        self.interval = Self.intervals.contains(interval) ? interval : defaults.interval
        let opacity = (try? values.decodeIfPresent(Double.self, forKey: .opacity)) ?? defaults.opacity
        self.opacity = Self.opacities.contains(opacity) ? opacity : defaults.opacity
        // Unknown metrics from a later version are dropped rather than failing the whole value.
        let raw = (try? values.decodeIfPresent([String].self, forKey: .metrics)) ?? nil
        metrics = raw.map { Self.ordered($0.compactMap(SystemMonitorMetric.init(rawValue:))) } ?? defaults.metrics
        sort = (try? values.decodeIfPresent(SystemMonitorSort.self, forKey: .sort)) ?? defaults.sort
        frames = (try? values.decodeIfPresent([String: CGRect].self, forKey: .frames)) ?? defaults.frames
    }

    /// Metrics in card order, each once.
    static func ordered(_ metrics: [SystemMonitorMetric]) -> [SystemMonitorMetric] {
        SystemMonitorMetric.allCases.filter(metrics.contains)
    }

    /// Shows or hides a metric. The last one cannot be hidden: an empty window says nothing.
    mutating func toggle(_ metric: SystemMonitorMetric) {
        if metrics.contains(metric) {
            guard metrics.count > 1 else { return }
            metrics.removeAll { $0 == metric }
        } else {
            metrics = Self.ordered(metrics + [metric])
        }
    }

    func frame(for mode: SystemMonitorWindowMode) -> CGRect? { frames[mode.rawValue] }

    mutating func setFrame(_ frame: CGRect, for mode: SystemMonitorWindowMode) {
        frames[mode.rawValue] = frame
    }

    static func load(from defaults: UserDefaults) -> Self {
        guard let data = defaults.data(forKey: defaultsKey),
              let settings = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return settings
    }

    func save(to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}

/// Where the window goes: its saved place when that is still on a screen, else the top right.
enum SystemMonitorWindowPlacement {
    static let margin: CGFloat = 16

    static func frame(size: CGSize, saved: CGRect?, screens: [CGRect], main: CGRect?) -> CGRect {
        if let saved {
            let candidate = CGRect(origin: saved.origin, size: size)
            // Keep it where it was if enough of it is on some screen to grab.
            if screens.contains(where: { $0.intersection(candidate).width >= 60 && $0.intersection(candidate).height >= 20 }) {
                return candidate
            }
        }
        guard let screen = main ?? screens.first else { return CGRect(origin: .zero, size: size) }
        return CGRect(x: screen.maxX - size.width - margin, y: screen.maxY - size.height - margin,
                      width: size.width, height: size.height)
    }
}
