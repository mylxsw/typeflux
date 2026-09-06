import Foundation

final class RecordingStartupLatencyTrace {
    static let shared = RecordingStartupLatencyTrace()

    private let lock = NSLock()
    private var sessionID = UUID()
    private var events: [(label: String, time: UInt64)] = []
    private var didLogFirstBuffer = false

    private init() {}

    func begin(_ label: String, physicalUptime: TimeInterval? = nil) {
        lock.lock()
        sessionID = UUID()
        let now = Self.now()
        if let physicalUptime, physicalUptime.isFinite, physicalUptime >= 0,
           physicalUptime <= Double(now) / 1_000_000_000 {
            events = [("hotkey.physical_press", UInt64(physicalUptime * 1_000_000_000)), (label, now)]
        } else {
            events = [(label, now)]
        }
        didLogFirstBuffer = false
        lock.unlock()
    }

    func mark(_ label: String, logSummary: Bool = false) {
        lock.lock()
        if events.isEmpty {
            events = [(label, Self.now())]
            didLogFirstBuffer = false
        } else {
            events.append((label, Self.now()))
        }
        let summary = logSummary ? summaryLocked() : nil
        lock.unlock()
        if let summary { NetworkDebugLogger.logMessage(summary) }
    }

    func markFirstAudioBuffer() {
        lock.lock()
        guard !didLogFirstBuffer else {
            lock.unlock()
            return
        }
        didLogFirstBuffer = true
        events.append(("audio.first_buffer", Self.now()))
        let summary = summaryLocked()
        lock.unlock()

        NetworkDebugLogger.logMessage(summary)
    }

    private func summaryLocked() -> String {
        guard let first = events.first else {
            return "[Recording Startup] no events"
        }

        let totalMilliseconds = Self.milliseconds(from: first.time, to: events.last?.time ?? first.time)
        let chain = events.map { event in
            let delta = Self.milliseconds(from: first.time, to: event.time)
            return "\(event.label)=\(String(format: "%.1f", delta))ms"
        }.joined(separator: " -> ")

        return "[Recording Startup] total=\(String(format: "%.1f", totalMilliseconds))ms \(chain)"
    }

    private static func now() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }

    private static func milliseconds(from start: UInt64, to end: UInt64) -> Double {
        Double(end - start) / 1_000_000.0
    }
}
