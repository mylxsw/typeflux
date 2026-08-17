import Foundation
import XCTest
@testable import Typeflux

final class LocalModelDownloadAnalyticsTests: XCTestCase {
    func testSuccessfulDownloadReportsLifecycleWithSharedAttemptID() async throws {
        let reporter = RecordingAnalyticsReporter()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalModelDownloadAnalyticsTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = LocalModelManager(
            sherpaOnnxInstaller: AnalyticsTestInstaller(),
            applicationSupportURL: root,
            downloadSourceResolver: FixedLocalModelDownloadSourceResolver(sources: [.huggingFace]),
            analyticsReporter: reporter
        )
        let configuration = LocalSTTConfiguration(
            model: .senseVoiceSmall,
            modelIdentifier: LocalSTTModel.senseVoiceSmall.defaultModelIdentifier,
            downloadSource: .huggingFace,
            autoSetup: true
        )

        _ = try await manager.downloadModelFilesOnly(configuration: configuration)

        let events = reporter.events
        XCTAssertEqual(events.map(\.name), ["model_download_started", "model_download_succeeded"])
        XCTAssertEqual(events[0].properties["attempt_id"], events[1].properties["attempt_id"])
        XCTAssertEqual(events[0].properties["job_id"], events[1].properties["job_id"])
        XCTAssertEqual(events[1].properties["status"], "succeeded")
        XCTAssertNotNil(events[1].properties["duration_ms"])
        XCTAssertEqual(events[1].properties["model_kind"], "stt")
        XCTAssertFalse(events[1].properties["source_host", default: ""].isEmpty)
    }

    func testCancelledDownloadReportsCancellation() async throws {
        let reporter = RecordingAnalyticsReporter()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalModelDownloadAnalyticsTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = LocalModelManager(
            sherpaOnnxInstaller: CancellingAnalyticsTestInstaller(), applicationSupportURL: root,
            downloadSourceResolver: FixedLocalModelDownloadSourceResolver(sources: [.huggingFace]),
            analyticsReporter: reporter
        )
        let configuration = LocalSTTConfiguration(
            model: .senseVoiceSmall, modelIdentifier: LocalSTTModel.senseVoiceSmall.defaultModelIdentifier,
            downloadSource: .huggingFace, autoSetup: true
        )

        do {
            _ = try await manager.downloadModelFilesOnly(configuration: configuration)
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            XCTAssertEqual(reporter.events.map(\.name), ["model_download_started", "model_download_cancelled"])
        }
    }
}

final class OllamaModelDownloadAnalyticsTests: XCTestCase {
    func testSuccessfulPullReportsLifecycle() async throws {
        let reporter = RecordingAnalyticsReporter()
        let manager = OllamaLocalModelManager(
            analyticsReporter: reporter,
            commandRunner: AnalyticsOllamaCommandRunner(result: .success),
            session: makeOllamaSession()
        )
        let (store, defaults, suite) = makeOllamaSettings()
        defer { defaults.removePersistentDomain(forName: suite) }

        try await manager.ensureModelReady(settingsStore: store)

        XCTAssertEqual(reporter.events.map(\.name), ["model_download_started", "model_download_succeeded"])
        XCTAssertEqual(reporter.events[0].properties["attempt_id"], reporter.events[1].properties["attempt_id"])
        XCTAssertEqual(reporter.events[1].properties["model_kind"], "llm")
        XCTAssertNotNil(reporter.events[1].properties["duration_ms"])
    }

    func testFailedPullReportsFailureBeforeRethrowing() async throws {
        let reporter = RecordingAnalyticsReporter()
        let manager = OllamaLocalModelManager(
            analyticsReporter: reporter,
            commandRunner: AnalyticsOllamaCommandRunner(result: .failure),
            session: makeOllamaSession()
        )
        let (store, defaults, suite) = makeOllamaSettings()
        defer { defaults.removePersistentDomain(forName: suite) }

        do {
            try await manager.ensureModelReady(settingsStore: store)
            XCTFail("Expected pull failure")
        } catch {
            XCTAssertEqual(reporter.events.map(\.name), ["model_download_started", "model_download_failed"])
            XCTAssertEqual(reporter.events[1].properties["error_category"], "ollama_pull_failed")
        }
    }

    func testCancelledPullReportsCancellation() async throws {
        let reporter = RecordingAnalyticsReporter()
        let manager = OllamaLocalModelManager(
            analyticsReporter: reporter,
            commandRunner: AnalyticsOllamaCommandRunner(result: .cancelled),
            session: makeOllamaSession()
        )
        let (store, defaults, suite) = makeOllamaSettings()
        defer { defaults.removePersistentDomain(forName: suite) }

        do {
            try await manager.ensureModelReady(settingsStore: store)
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            XCTAssertEqual(reporter.events.map(\.name), ["model_download_started", "model_download_cancelled"])
        }
    }

    private func makeOllamaSettings() -> (SettingsStore, UserDefaults, String) {
        let suite = "OllamaModelDownloadAnalyticsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = SettingsStore(defaults: defaults)
        store.ollamaBaseURL = "http://ollama.test:11434"
        store.ollamaModel = "qwen-test:latest"
        store.ollamaAutoSetup = false
        return (store, defaults, suite)
    }

    private func makeOllamaSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AnalyticsOllamaURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private final class RecordingAnalyticsReporter: AnalyticsEventReporting, @unchecked Sendable {
    struct Event { let name: String; let properties: [String: String] }
    private let lock = NSLock()
    private var storage: [Event] = []
    var events: [Event] { lock.withLock { storage } }
    func report(eventName: String, properties: [String: String]) {
        lock.withLock { storage.append(Event(name: eventName, properties: properties)) }
    }
    func reportFirstOpenIfNeeded() {}
}

private struct AnalyticsTestInstaller: SherpaOnnxModelInstalling {
    func prepareModel(
        _: LocalSTTModel,
        at storageURL: URL,
        downloadSource _: ModelDownloadSource,
        onUpdate _: (@Sendable (LocalSTTPreparationUpdate) -> Void)?
    ) async throws -> String { storageURL.path }
}

private struct CancellingAnalyticsTestInstaller: SherpaOnnxModelInstalling {
    func prepareModel(
        _: LocalSTTModel,
        at _: URL,
        downloadSource _: ModelDownloadSource,
        onUpdate _: (@Sendable (LocalSTTPreparationUpdate) -> Void)?
    ) async throws -> String { throw CancellationError() }
}

private enum AnalyticsOllamaPullResult: Sendable { case success, failure, cancelled }

private struct AnalyticsOllamaCommandRunner: ProcessCommandRunning {
    let result: AnalyticsOllamaPullResult

    func run(
        executablePath: String,
        arguments: [String],
        environment _: [String: String]?,
        currentDirectoryURL _: URL?
    ) async throws -> ProcessCommandResult {
        if executablePath == "/usr/bin/env" && arguments == ["which", "ollama"] {
            return ProcessCommandResult(stdout: "/test/ollama\n", stderr: "", exitCode: 0)
        }
        if arguments.first == "pull" {
            switch result {
            case .success: break
            case .failure: throw NSError(domain: "OllamaModelDownloadAnalyticsTests", code: 1)
            case .cancelled: throw CancellationError()
            }
        }
        return ProcessCommandResult(stdout: "", stderr: "", exitCode: 0)
    }
}

private final class AnalyticsOllamaURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with _: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"models":[]}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
