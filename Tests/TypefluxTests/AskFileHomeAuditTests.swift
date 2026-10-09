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
        let reader = AskHomeAuditReader()
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
        #expect(elapsed < 300)
        #expect(!index.status.truncated)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("index.bin").path))
        let snapshot = try #require(AskFileSnapshot.decode(Data(contentsOf: root.appendingPathComponent("index.bin"))))
        let largeDirectories = reader.directories.filter { $0.hasSuffix("/target/debug/deps") }.sorted()
        #expect(largeDirectories.count >= 2, "audit includes the reviewer's large Rust build directories")
        for path in largeDirectories {
            let directory = try #require(snapshot.state.directoryIndex[path])
            let indexed = Set(snapshot.state.children[Int(directory)].map { snapshot.state.name(of: snapshot.state.records[Int($0)]) })
            let listed = try FileManager.default.contentsOfDirectory(atPath: path)
            let expected = Set(listed.filter { guarded.includes(path + "/" + $0, isDirectory: false) })
            #expect(indexed == expected, "every visible entry in the large directory is saved in the snapshot")
            print("HOME_DEPS path=\(path) indexed=\(indexed.count) expected=\(expected.count) complete=\(indexed == expected)")
        }
        for (path, reason) in reader.skips.sorted(by: { $0.key < $1.key }) {
            print("HOME_SKIP reason=\(reason) path=\(path)")
        }
        let apps = AskAppIndex.scan(AskLauncherSearchSettings.defaultAppRoots.map {
            URL(fileURLWithPath: AskLauncherSearchSettings.expand($0))
        })
        let safari = apps.filter { $0.id == "com.apple.Safari" }
        #expect(safari.count == 1)
        #expect(safari.first.map { FileManager.default.fileExists(atPath: $0.url.path) } == true)
        print("HOME_AUDIT elapsed=\(String(format: "%.3f", elapsed))s entries=\(index.status.count) reads=\(reads.count) protectedReads=\(protectedReads.count) timedOut=\(index.status.timedOut) failed=\(index.status.failed) mounts=\(index.status.nonLocalMounts) snapshot=true")
        print("APP_AUDIT apps=\(apps.count) safari=\(safari.count) path=\(safari.first?.url.path ?? "missing")")
        index.saveBeforeQuitting()
        index.waitUntilIdle()
    }
}

/// Observes production streaming reads without changing their policy, progress or deadlines.
private final class AskHomeAuditReader: AskFileReading {
    let worker = AskFileReader()
    var requests: [AskFileReadRequest] = []
    var directories = Set<String>()
    var skips: [String: String] = [:]

    func read(_ request: AskFileReadRequest, isCancelled: () -> Bool) throws -> AskFileReadResponse {
        var result = AskFileReadResponse()
        try stream(request, isCancelled: isCancelled) {
            result.entries += $0.entries
            result.path = $0.path ?? result.path
            result.error = $0.error ?? result.error
            result.skippedMounts = (result.skippedMounts ?? []) + ($0.skippedMounts ?? [])
            return true
        }
        return result
    }

    func stream(_ request: AskFileReadRequest, isCancelled: () -> Bool, receive: (AskFileReadResponse) -> Bool) throws {
        requests.append(request)
        if request.operation == .directory { directories.insert(request.path) }
        do {
            try worker.stream(request, isCancelled: isCancelled) { response in
                if let error = response.error { skips[request.path] = "errno-\(error)" }
                for mount in response.skippedMounts ?? [] { skips[mount] = "non-local-mount" }
                return receive(response)
            }
        } catch {
            skips[request.path] = String(describing: error)
            throw error
        }
    }
}
