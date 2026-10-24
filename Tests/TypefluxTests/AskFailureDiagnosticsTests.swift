import Foundation
import SQLite3
import Testing
@testable import Typeflux

@Suite(.serialized, .exclusiveUIState)
struct AskFailureDiagnosticsTests {
    @Test func persistentFailuresKeepCodesButExcludeContentAndUnknownMethodNames() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let diagnostics = AskFailureDiagnostics(directory: root)
        let secret = "PRIVATE prompt token path SQL content"
        diagnostics.record(.cacheCall, error: AskLocalError.message(secret), method: secret)
        diagnostics.record(.sqliteRead, error: CocoaError(.fileReadUnknown,
            userInfo: [NSLocalizedDescriptionKey: secret, NSUnderlyingErrorKey: NSError(domain: "SQLite", code: 11,
                userInfo: [NSLocalizedDescriptionKey: secret])]), method: "cache.executions.1")
        diagnostics.record(.recoveryRead, error: DecodingError.keyNotFound(
            Field(stringValue: "content"), .init(
                codingPath: [Field(stringValue: "payload"), Field(stringValue: secret)],
                debugDescription: secret)))
        await diagnostics.flush()
        let events = try AskFailureDiagnostics.read(directory: root)
        #expect(events.count == 3)
        #expect(events.contains { $0.decodingPath == "$.payload.*.content" })
        #expect(events.contains { $0.underlyingDomain == "SQLite" && $0.underlyingCode == 11 })
        #expect(events.contains { $0.sqliteReason == "database disk image is malformed" })
        #expect(events.contains { $0.method == "cache.executions.1" })
        #expect(events.contains { $0.method == "other" })
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        let bytes = try Data(contentsOf: #require(files.first))
        #expect(String(data: bytes, encoding: .utf8)?.contains(secret) == false)
        let attributes = try FileManager.default.attributesOfItem(atPath: files[0].path)
        let permissions = attributes[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
        #expect(try AskFailureDiagnostics.read(directory: root).count == 3, "A new reader survives process recreation")
    }

    @Test func failuresRemainDistinguishableAcrossTransportStorageAuthorizationAndCancellation() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let diagnostics = AskFailureDiagnostics(directory: root)
        let errors: [any Error] = [FeatureRPC.Failure.busy, FeatureRPC.Failure.timedOut, CancellationError(),
            ModuleFailure.operationTimeout, ModuleFailure.quarantined, AuthError.unauthorized, AskRecoveryError.storage,
            DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "PRIVATE CONTENT"))]
        for error in errors { diagnostics.record(.recoveryRead, error: error) }
        await diagnostics.flush()
        let kinds = Set(try AskFailureDiagnostics.read(directory: root).map(\.kind))
        #expect(kinds == ["rpc.busy", "rpc.timedOut", "cancelled", "module.operationTimeout", "module.quarantined",
            "authorization", "recovery.storage", "decoding"])
    }

    @Test func retentionIsBoundedAndMalformedLinesDoNotHideValidFailures() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for index in 0..<12 { try Data().write(to: root.appendingPathComponent("failures-\(index).jsonl")) }
        try Data("Keep me".utf8).write(to: root.appendingPathComponent("unrelated.txt"))
        let diagnostics = AskFailureDiagnostics(directory: root)
        diagnostics.record(.rpcRead, error: FeatureRPC.Failure.unavailable)
        await diagnostics.flush()
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        #expect(files.filter { $0.pathExtension == "jsonl" }.count == AskFailureDiagnostics.maximumFiles)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("unrelated.txt").path))
        let file = try #require(files.first {
            (try? Data(contentsOf: $0).isEmpty) == false && $0.pathExtension == "jsonl"
        })
        let line = try Data(contentsOf: file)
        var data = Data("malformed JSON\n".utf8)
        for _ in 0..<150 { data.append(line) }
        try data.write(to: file)
        #expect(try AskFailureDiagnostics.read(directory: root).count == AskFailureDiagnostics.maximumEvents)
        let future = DateInterval(start: Date().addingTimeInterval(60), duration: 10)
        #expect(try AskFailureDiagnostics.read(directory: root, interval: future).isEmpty)
    }

    @Test func sqliteFailuresPreserveTheUnderlyingDatabaseCode() async throws {
        let cache = try AskConversationCache.inMemory()
        do {
            try await cache.execute("INSERT INTO missing_table VALUES ('PRIVATE CONTENT')", strings: [])
            Issue.record("The invalid query must fail")
        } catch {
            let value = error as NSError
            #expect(value.domain == NSCocoaErrorDomain)
            let underlying = try #require(value.userInfo[NSUnderlyingErrorKey] as? NSError)
            #expect(underlying.domain == "SQLite" && underlying.code == Int(SQLITE_ERROR))
            #expect(!value.localizedDescription.contains("PRIVATE CONTENT"))
        }
    }

    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ask-failures-" + UUID().uuidString)
    }

    private struct Field: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
}

@Suite(.exclusiveUIState)
@MainActor
struct AskFailureExportTests {
    @Test func exportedDiagnosticsIncludeFailuresAndReportCollectionErrors() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let diagnostics = AskFailureDiagnostics(directory: root)
        diagnostics.record(.cacheAuthorization, error: AuthError.unauthorized, reason: .generationMismatch)
        await diagnostics.flush()
        var collector = DiagnosticsCollector()
        collector.readShortcuts = { now, _ in .init(events: [], now: now) }
        collector.readHangs = { _ in ([], 0) }
        collector.modules = { [:] }
        collector.resources = { [] }
        collector.readAskFailures = { try AskFailureDiagnostics.read(directory: root, interval: $0) }
        let report = try await collector.collect(interval: nil)
        #expect(report.askFailures?.first?.reason == .generationMismatch)
        #expect(report.collectionFailures.isEmpty)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(DiagnosticsReport.self, from: report.encodedForExport())
        #expect(decoded.askFailures?.count == 1)
        collector.readAskFailures = { _ in throw CocoaError(.fileReadUnknown) }
        let partial = try await collector.collect(interval: nil)
        #expect(partial.collectionFailures == ["askFailures"])
    }
}
