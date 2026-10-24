import AppKit
import Foundation
import os

/// Monotonic timestamps are comparable across processes on this Mac. Wall time
/// is for browsing only; it is never used to calculate a duration.
struct ShortcutLatencyTrace: Codable, Sendable, Equatable {
    let id: UUID
    let feature: FeatureRole
    let date: Date
    let uptime: TimeInterval
}

enum ShortcutLatencyStage: String, Codable, Sendable, CaseIterable {
    case recognized, callback, dispatched, hostReceived, hostRouting
    case targetWarm, targetCold, spawnRequested, processStarted
    case targetWireReceived, targetReceived, readinessStarted, readinessFinished, handlerStarted, handlerFinished
    case dataStarted, dataFinished, captureStarted, captureFinished
    case windowOrdered, visibleNextTurn, dismissed, blocked, failed, superseded
    case ringPressed, ringReleased, ringCancelled, ringShowStarted, ringShowFinished
    case statePreparationStarted, statePreparationFinished, appsRefreshStarted, appsRefreshFinished
    case workflowsStarted, workflowsFinished, contextRequestStarted, contextRequestFinished
    case contextCaptureStarted, contextCaptureFinished, windowCached, windowUncached
    case windowAcquisitionStarted, windowAcquisitionFinished, layoutStarted, layoutFinished
    case windowShowStarted, windowShowFinished, focusStarted, focusFinished, monitorsStarted, monitorsFinished
    case mediaActivationStarted, mediaActivationFinished
    case dataCacheHit, dataCacheMiss
    case dataWorkerStarted, dataCallback, maintenancePlanStarted, maintenancePlanFinished
    case maintenanceStarted, maintenanceFinished, historyReadStarted, historyReadFinished
    case clipboardReadStarted, clipboardReadFinished, pinsReadStarted, pinsReadFinished
    case mergeStarted, mergeFinished, modelUpdateStarted, modelUpdateFinished
    case overlayStarted, overlayFinished, oldOverlayRetired
    case displayViewStarted, displayViewFinished, displayPanelStarted, displayPanelFinished
    case displayShowStarted, displayShowFinished, pointerUpdateStarted, pointerUpdateFinished
    case translationSelectionStarted, translationSelectionFinished
}

struct ShortcutLatencyEvent: Codable, Sendable {
    var version = 1
    let trace: ShortcutLatencyTrace
    let stage: ShortcutLatencyStage
    let uptime: TimeInterval
    let pid: Int32
    let role: FeatureRole
    let build: String
    var droppedBefore = 0
    /// One-based display ordinal and total count; never a display identifier or image.
    var itemIndex: Int?
    var itemCount: Int?

    var milliseconds: Double { (uptime - trace.uptime) * 1000 }
}

enum ShortcutLatency {
    @TaskLocal static var current: ShortcutLatencyTrace?
    @TaskLocal static var receivedUptime: TimeInterval?
    /// Injected observers let focused tests inspect real instrumentation without writing user logs.
    @TaskLocal static var eventSink: (@Sendable (ShortcutLatencyEvent) -> Void)?
    static let enabledKey = "diagnostics.shortcuts.enabled"
    static var directory: URL { TypefluxDataDirectories.cache.appendingPathComponent("shortcut-latency", isDirectory: true) }
    private static let writer = ShortcutLatencyWriter()

    static func begin(_ feature: FeatureRole) -> ShortcutLatencyTrace? {
        guard FeatureProcess.enabled, UserDefaults.standard.object(forKey: enabledKey) as? Bool != false else { return nil }
        let now = ProcessInfo.processInfo.systemUptime
        let start = receivedUptime ?? now
        let trace = ShortcutLatencyTrace(id: UUID(), feature: feature, date: Date().addingTimeInterval(start - now), uptime: start)
        record(.recognized, trace: trace)
        return trace
    }

    static func record(_ stage: ShortcutLatencyStage, trace: ShortcutLatencyTrace? = current,
                       itemIndex: Int? = nil, itemCount: Int? = nil) {
        guard let trace else { return }
        let event = ShortcutLatencyEvent(
            version: 2,
            trace: trace,
            stage: stage,
            uptime: stage == .recognized ? trace.uptime : ProcessInfo.processInfo.systemUptime,
            pid: ProcessInfo.processInfo.processIdentifier,
            role: FeatureProcess.role,
            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "development",
            itemIndex: itemIndex,
            itemCount: itemCount
        )
        if let eventSink {
            eventSink(event)
        } else {
            writer.record(event)
        }
    }

    static func measure<T>(_ start: ShortcutLatencyStage, _ end: ShortcutLatencyStage,
                           trace: ShortcutLatencyTrace? = current, itemIndex: Int? = nil, itemCount: Int? = nil,
                           _ operation: () throws -> T) rethrows -> T {
        record(start, trace: trace, itemIndex: itemIndex, itemCount: itemCount)
        defer { record(end, trace: trace, itemIndex: itemIndex, itemCount: itemCount) }
        return try operation()
    }

    /// Preserve both correlation and an injected sink across GCD, which does not inherit task locals.
    static func deliver(_ trace: ShortcutLatencyTrace?, _ operation: @escaping @MainActor () -> Void) {
        let sink = eventSink
        DispatchQueue.main.async {
            $eventSink.withValue(sink) { $current.withValue(trace) { operation() } }
        }
    }

    /// Does not force layout, draw, or wait on the compositor. This is explicitly
    /// a next-main-queue-turn visibility check, not physical screen first paint.
    @MainActor static func windowOrdered(_ window: NSWindow?, trace: ShortcutLatencyTrace? = current) {
        guard let trace, let window else { return }
        presentationOrdered(trace: trace) { [weak window] in window?.isVisible == true }
    }

    @MainActor static func presentationOrdered(trace: ShortcutLatencyTrace? = current,
                                               isVisible: @escaping @MainActor () -> Bool) {
        guard let trace else { return }
        record(.windowOrdered, trace: trace)
        deliver(trace) {
            record(isVisible() ? .visibleNextTurn : .superseded, trace: trace)
        }
    }
}

/// A separate file per process/rotation avoids cross-process locks in the hot
/// path. Admission is bounded before dispatch; disk I/O never runs on the caller.
final class ShortcutLatencyWriter: @unchecked Sendable {
    static let maximumFileBytes = 256 * 1024
    static let maximumFiles = 16
    static let retention: TimeInterval = 7 * 86400
    private let queue = DispatchQueue(label: "typeflux.shortcut-diagnostics", qos: .utility)
    private let lock = NSLock()
    private var pending = 0
    private var dropped = 0
    private struct TraceAdmission { var events = 0; let uptime: TimeInterval }
    private var traces: [UUID: TraceAdmission] = [:]
    private let directoryOverride: URL?
    private var file: URL?
    private var bytes = 0
    private let logger = Logger(subsystem: "ai.gulu.app.typeflux", category: "ShortcutLatency")

    init(directory: URL? = nil) { directoryOverride = directory }

    func record(_ event: ShortcutLatencyEvent) {
        let accepted: ShortcutLatencyEvent? = lock.withLock {
            guard event.uptime.isFinite, event.trace.uptime.isFinite,
                  (0...300).contains(event.uptime - event.trace.uptime) else { return nil }
            if traces[event.trace.id] == nil, traces.count >= 256 {
                // Bound admission bookkeeping independently of the number of shortcuts used.
                let oldest = traces.min { $0.value.uptime < $1.value.uptime }?.key
                if let oldest { traces[oldest] = nil }
            }
            var admission = traces[event.trace.id] ?? .init(uptime: event.trace.uptime)
            let terminal = [ShortcutLatencyStage.visibleNextTurn, .failed, .blocked, .dismissed, .superseded].contains(event.stage)
            guard pending < 512, admission.events < (terminal ? 264 : 256) else { dropped += 1; return nil }
            admission.events += 1; traces[event.trace.id] = admission
            pending += 1
            var event = event
            event.droppedBefore = dropped; dropped = 0
            return event
        }
        guard let accepted else { return }
        queue.async { [self] in
            defer { lock.withLock { pending -= 1 } }
            do { try append(accepted) }
            catch { logger.error("Could not write shortcut diagnostic") }
        }
    }

    func flush() async { await withCheckedContinuation { continuation in queue.async { continuation.resume() } } }

    private func append(_ event: ShortcutLatencyEvent) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var data = try encoder.encode(event); data.append(10)
        let directory = directoryOverride ?? ShortcutLatency.directory
        if file == nil || bytes + data.count > Self.maximumFileBytes || !FileManager.default.fileExists(atPath: file!.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try Self.prune(directory: directory, keeping: Self.maximumFiles - 1)
            let target = directory.appendingPathComponent("events-\(UUID().uuidString).jsonl")
            guard FileManager.default.createFile(atPath: target.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            file = target; bytes = 0
        }
        guard let file else { return }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf: data)
        bytes += data.count
    }

    static func prune(directory: URL, keeping: Int = maximumFiles, now: Date = Date()) throws {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
            .filter { $0.lastPathComponent.hasPrefix("events-") && $0.pathExtension == "jsonl" }
            .sorted { modification($0) > modification($1) }
        for (index, file) in files.enumerated() where index >= keeping || now.timeIntervalSince(modification(file)) > retention {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private static func modification(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }
}
