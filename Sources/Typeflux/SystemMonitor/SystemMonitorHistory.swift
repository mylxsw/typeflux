import Foundation

/// The last `capacity` values of one series, oldest first: what a sparkline draws.
struct SystemMonitorSeries: Equatable, Sendable {
    static let defaultCapacity = 60

    private(set) var values: [Double] = []
    let capacity: Int

    init(capacity: Int = Self.defaultCapacity) {
        self.capacity = max(1, capacity)
    }

    mutating func append(_ value: Double) {
        values.append(value.isFinite ? value : 0)
        if values.count > capacity { values.removeFirst(values.count - capacity) }
    }

    var last: Double? { values.last }
    var peak: Double { values.max() ?? 0 }
}

/// The series every card and chart draws.
struct SystemMonitorHistory: Equatable, Sendable {
    var cpu = SystemMonitorSeries()
    var memory = SystemMonitorSeries()
    var diskRead = SystemMonitorSeries()
    var diskWrite = SystemMonitorSeries()
    var networkDown = SystemMonitorSeries()
    var networkUp = SystemMonitorSeries()

    mutating func append(_ snapshot: SystemSnapshot) {
        cpu.append(snapshot.cpu.total)
        memory.append(snapshot.memory.usedPercent)
        diskRead.append(snapshot.diskRead)
        diskWrite.append(snapshot.diskWrite)
        networkDown.append(snapshot.networkDown)
        networkUp.append(snapshot.networkUp)
    }
}

/// CPU held at or above `threshold` for `duration`: the monitor says so, naming the busiest process.
struct SystemMonitorCPUAlert: Equatable, Sendable {
    static let threshold = 90.0
    static let duration: TimeInterval = 30

    /// When CPU last rose past the threshold and stayed there; nil below it.
    private(set) var since: TimeInterval?

    mutating func record(cpu: Double, at time: TimeInterval) {
        if cpu >= Self.threshold {
            if since == nil { since = time }
        } else {
            since = nil
        }
    }

    /// Seconds above the threshold, once that reaches `duration`; nil before.
    func sustained(at time: TimeInterval) -> TimeInterval? {
        guard let since, time - since >= Self.duration else { return nil }
        return time - since
    }
}

/// The process list: filtered, sorted and, while the user points at it, held in place.
enum SystemMonitorProcessList {
    /// Name (case-insensitive) or exact PID; an empty filter keeps everything.
    static func filter(_ processes: [SystemProcess], query: String) -> [SystemProcess] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return processes }
        if let pid = Int32(query) {
            let exact = processes.filter { $0.pid == pid }
            if !exact.isEmpty { return exact }
        }
        return processes.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    /// Busiest first; ties go to the lower PID so the order is stable.
    static func sorted(_ processes: [SystemProcess], by sort: SystemMonitorSort) -> [SystemProcess] {
        processes.sorted { lhs, rhs in
            let left = value(lhs, sort), right = value(rhs, sort)
            return left != right ? left > right : lhs.pid < rhs.pid
        }
    }

    static func value(_ process: SystemProcess, _ sort: SystemMonitorSort) -> Double {
        switch sort {
        case .cpu: process.cpu
        case .memory: Double(process.memory)
        case .disk: process.disk ?? -1
        }
    }

    /// `processes` in `frozen` order: known ones where they were, new ones after,
    /// gone ones dropped. Values stay current; only rows stop moving.
    static func holding(_ processes: [SystemProcess], in frozen: [Int32]) -> [SystemProcess] {
        let position = Dictionary(frozen.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return processes.enumerated().sorted { lhs, rhs in
            switch (position[lhs.element.pid], position[rhs.element.pid]) {
            case let (left?, right?): left < right
            case (.some, nil): true
            case (nil, .some): false
            case (nil, nil): lhs.offset < rhs.offset
            }
        }.map(\.element)
    }

    /// The busiest process by CPU, for the alert.
    static func busiest(_ processes: [SystemProcess]?) -> SystemProcess? {
        processes?.max { lhs, rhs in lhs.cpu != rhs.cpu ? lhs.cpu < rhs.cpu : lhs.pid > rhs.pid }
    }
}
