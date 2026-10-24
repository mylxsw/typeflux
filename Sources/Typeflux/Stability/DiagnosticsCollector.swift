import Foundation

/// Collection runs only while the diagnostics panel is open. Injected sources let
/// tests exercise failures without starting an application or feature process.
@MainActor
struct DiagnosticsCollector {
    var readShortcuts: @Sendable (Date, DateInterval?) throws -> ShortcutLatencyReport = {
        try ShortcutLatencyReport.read(now: $0, interval: $1)
    }

    var readHangs: @Sendable (DateInterval?) throws -> ([DiagnosticsReport.HangRecord], Int) = {
        try DiagnosticsReport.readHangs(interval: $0)
    }

    var resources: @MainActor () async throws -> [FeatureResourceSnapshot] = {
        guard FeatureProcess.enabled else { throw ModuleFailure.unavailable }
        let data = try await FeatureProcess.route(.init(destination: .host, action: "resources"))
        return try JSONDecoder().decode([FeatureResourceSnapshot].self, from: data)
    }

    var modules: @MainActor () async throws -> [ModuleID: ModuleHealth] = {
        guard FeatureProcess.enabled else { throw ModuleFailure.unavailable }
        return try await FeatureModuleHealth().snapshots()
    }

    var readAskFailures: @Sendable (DateInterval?) throws -> [AskFailureDiagnostics.Event] = {
        try AskFailureDiagnostics.read(interval: $0)
    }

    func collect(
        now: Date = Date(),
        interval: DateInterval?,
        previousProcesses: [FeatureResourceSnapshot]? = nil
    ) async throws -> DiagnosticsReport {
        let reader = readShortcuts, hangReader = readHangs
        var failures: [String] = []
        let shortcutResult = await Task.detached(priority: .utility) { Result { try reader(now, interval) } }.value
        try Task.checkCancellation()
        var shortcuts: ShortcutLatencyReport
        switch shortcutResult {
        case let .success(value): shortcuts = value
        case .failure: shortcuts = .init(events: [], now: now); failures.append("shortcuts")
        }
        var health: [String: ModuleHealth]?
        do { shortcuts.processes = try await resources() } catch { failures.append("resources") }
        try Task.checkCancellation()
        do { health = try await Dictionary(uniqueKeysWithValues: modules().map { ($0.key.rawValue, $0.value) }) }
        catch { failures.append("modules") }
        try Task.checkCancellation()
        let hangs = await Task.detached(priority: .utility) { Result { try hangReader(interval) } }.value
        let records: [DiagnosticsReport.HangRecord], unreadable: Int
        switch hangs {
        case let .success(result): (records, unreadable) = result
        case .failure: records = []; unreadable = 0; failures.append("hangs")
        }
        try Task.checkCancellation()
        let failureReader = readAskFailures
        let askFailures: [AskFailureDiagnostics.Event]
        do { askFailures = try await Task.detached(priority: .utility) { try failureReader(interval) }.value }
        catch { failures.append("askFailures"); askFailures = [] }
        try Task.checkCancellation()
        return DiagnosticsReport(generatedAt: now, rangeStart: interval?.start, rangeEnd: interval?.end,
                                 shortcuts: shortcuts, previousProcesses: previousProcesses, currentSnapshotAt: Date(),
                                 currentModules: health, hangs: records,
                                 unreadableHangFiles: unreadable, collectionFailures: failures, askFailures: askFailures)
    }
}
