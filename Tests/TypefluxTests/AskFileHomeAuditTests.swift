import Foundation
import Testing
@testable import Typeflux

/// Explicit opt-in only: never touch the developer's home during an ordinary test run.
@Suite("Real home file index audit", .serialized)
struct AskFileHomeAuditTests {
    @Test func productionScanWithoutFullDiskAccess() throws {
        guard ProcessInfo.processInfo.environment["TYPEFLUX_REAL_HOME_AUDIT"] == "1" else { return }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("file-audit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "file-audit-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let reader = AskRecordingFileReader()
        let production = AskFileReader()
        reader.respond = { try production.read($0) }
        let settings = AskLauncherSearchSettings()
        let guarded = AskFileScope(settings: settings, fullDiskAccess: false)
        let index = AskFileIndex(configuration: { (true, settings) }, fullDiskAccess: { false },
                                 snapshotURL: root.appendingPathComponent("index.bin"), defaults: defaults,
                                 makeReader: { reader }, makeWatcher: { AskTestFileWatcher() })
        let started = Date()
        index.start()
        index.waitUntilIdle()
        let elapsed = Date().timeIntervalSince(started)
        let reads = reader.requests.filter { $0.operation != .resolve }
        let protectedReads = reads.filter { request in guarded.blocked.contains { AskFileScope.isInside(request.path, $0) } }
        #expect(protectedReads.isEmpty)
        #expect(index.status.phase == .ready)
        #expect(index.status.count > 0)
        #expect(elapsed < 120)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("index.bin").path))
        let apps = AskAppIndex.scan(AskLauncherSearchSettings.defaultAppRoots.map {
            URL(fileURLWithPath: AskLauncherSearchSettings.expand($0))
        })
        let safari = apps.filter { $0.id == "com.apple.Safari" }
        #expect(safari.count == 1)
        #expect(safari.first.map { FileManager.default.fileExists(atPath: $0.url.path) } == true)
        print("HOME_AUDIT elapsed=\(String(format: "%.3f", elapsed))s entries=\(index.status.count) reads=\(reads.count) protectedReads=\(protectedReads.count) timedOut=\(index.status.timedOut) failed=\(index.status.failed) snapshot=true")
        print("APP_AUDIT apps=\(apps.count) safari=\(safari.count) path=\(safari.first?.url.path ?? "missing")")
        index.saveBeforeQuitting()
        index.waitUntilIdle()
    }
}
