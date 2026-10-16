@testable import Typeflux
import XCTest

final class OllamaPullProgressTests: XCTestCase {
    func testAddsUpLayersAndRecognisesSuccess() throws {
        var progress = OllamaPullProgress()

        XCTAssertFalse(try progress.apply(line: #"{"status":"pulling manifest"}"#))
        XCTAssertFalse(try progress.apply(line: "   "))
        XCTAssertTrue(try progress.apply(line: #"{"status":"pulling a","digest":"a","total":100,"completed":40}"#))
        XCTAssertTrue(try progress.apply(line: #"{"status":"pulling b","digest":"b","total":300}"#))
        XCTAssertFalse(try progress.apply(line: #"{"status":"pulling b","digest":"b","total":300}"#))
        XCTAssertFalse(try progress.apply(line: #"{"status":"pulling c","digest":"c","total":0}"#))
        XCTAssertTrue(try progress.apply(line: #"{"digest":"a","total":100,"completed":140}"#))

        XCTAssertEqual(progress.total, 400)
        XCTAssertEqual(progress.completed, 100, "a layer never counts more than its size")
        XCTAssertEqual(progress.status, "pulling c", "the latest line with a status wins")
        XCTAssertFalse(progress.succeeded)

        try progress.apply(line: #"{"status":"success"}"#)
        XCTAssertTrue(progress.succeeded)
        XCTAssertNotEqual(progress, OllamaPullProgress())
    }

    func testThrowsTheServerError() {
        var progress = OllamaPullProgress()
        XCTAssertThrowsError(try progress.apply(line: #"{"error":"model not found"}"#)) { error in
            XCTAssertEqual(error.localizedDescription, "model not found")
        }
        XCTAssertThrowsError(try progress.apply(line: "not json"))
    }

    func testStreamPullReportsProgressAndSucceeds() async throws {
        var reports: [(Int64, Int64)] = []
        try await OllamaLocalModelManager.streamPull(
            model: "m", baseURL: url(.success), session: makeSession()
        ) { reports.append(($0, $1)) }

        XCTAssertEqual(reports.map(\.0), [10, 20])
        XCTAssertEqual(reports.map(\.1), [20, 20])
    }

    func testStreamPullFailsWhenTheStreamEndsEarly() async {
        await assertPullFails(.truncated, message: "The Ollama pull ended before the model was ready.")
    }

    func testStreamPullReportsHTTPErrorsWithTheServerMessage() async {
        await assertPullFails(.httpError, message: "registry unavailable")
        await assertPullFails(.httpErrorWithoutBody, message: "Ollama pull failed with HTTP 500.")
    }

    func testManagerReportsPullLifecycle() async throws {
        let reporter = RecordingPullReporter()
        let suite = "OllamaPullProgressTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults)
        store.ollamaBaseURL = url(.success).absoluteString
        store.ollamaModel = "qwen-test:latest"
        store.ollamaAutoSetup = false
        let manager = OllamaLocalModelManager(commandRunner: WhichOllamaRunner(), session: makeSession(),
                                              pullReporter: reporter)

        try await manager.ensureModelReady(settingsStore: store)

        XCTAssertEqual(reporter.events, ["start qwen-test:latest", "progress 10/20", "progress 20/20",
                                         "finish qwen-test:latest ok"])
    }

    func testNoopReporterAcceptsEveryEvent() {
        let reporter = NoopOllamaPullProgressReporter.shared
        reporter.pullStarted(model: "m", cancel: {})
        reporter.pullProgressed(model: "m", completed: 1, total: 2)
        reporter.pullFinished(model: "m", error: nil)
    }

    private func assertPullFails(_ scenario: PullScenario, message: String,
                                 file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await OllamaLocalModelManager
                .streamPull(model: "m", baseURL: url(scenario), session: makeSession()) { _, _ in }
            XCTFail("Expected failure", file: file, line: line)
        } catch {
            XCTAssertEqual(error.localizedDescription, message, file: file, line: line)
        }
    }

    private func url(_ scenario: PullScenario) -> URL {
        URL(string: "http://\(scenario.rawValue).pull.test:11434")!
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PullURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private enum PullScenario: String {
    case success, truncated, httpError, httpErrorWithoutBody
}

private final class PullURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let host = request.url?.host ?? ""
        let scenario = PullScenario(rawValue: String(host.prefix { $0 != "." })) ?? .success
        let isPull = request.url?.path == "/api/pull"
        let status = isPull && (scenario == .httpError || scenario == .httpErrorWithoutBody) ? 500 : 200
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let body = if !isPull {
            #"{"models":[]}"#
        } else {
            switch scenario {
            case .success:
                """
                {"status":"pulling manifest"}
                {"status":"pulling a","digest":"a","total":20,"completed":10}
                {"status":"pulling a","digest":"a","total":20,"completed":10}
                {"status":"pulling a","digest":"a","total":20,"completed":20}
                {"status":"success"}

                """
            case .truncated: #"{"status":"pulling a","digest":"a","total":20,"completed":10}"# + "\n"
            case .httpError: #"{"error":"registry unavailable"}"# + "\n"
            case .httpErrorWithoutBody: ""
            }
        }
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class RecordingPullReporter: OllamaPullProgressReporting, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    var events: [String] {
        lock.withLock { storage }
    }

    func pullStarted(model: String, cancel _: @escaping @Sendable () -> Void) {
        lock.withLock { storage.append("start \(model)") }
    }

    func pullProgressed(model _: String, completed: Int64, total: Int64) {
        lock.withLock { storage.append("progress \(completed)/\(total)") }
    }

    func pullFinished(model: String, error: Error?) {
        lock.withLock { storage.append("finish \(model) \(error == nil ? "ok" : "failed")") }
    }
}

private struct WhichOllamaRunner: ProcessCommandRunning {
    func run(executablePath _: String, arguments _: [String], environment _: [String: String]?,
             currentDirectoryURL _: URL?) async throws -> ProcessCommandResult {
        ProcessCommandResult(stdout: "/test/ollama\n", stderr: "", exitCode: 0)
    }
}
