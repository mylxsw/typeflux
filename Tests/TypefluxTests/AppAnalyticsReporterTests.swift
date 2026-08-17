import XCTest
@testable import Typeflux

final class AppAnalyticsReporterTests: XCTestCase {
    func testFirstOpenIsQueuedOnlyOnce() throws {
        let suite = "AppAnalyticsReporterTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let transport = FailingAnalyticsTransport()
        let reporter = makeReporter(defaults: defaults, transport: transport)

        reporter.reportFirstOpenIfNeeded()
        reporter.reportFirstOpenIfNeeded()

        let events = queuedEvents(defaults: defaults)
        XCTAssertEqual(events.map(\.eventName), ["app_first_open"])
        XCTAssertEqual(events[0].clientID, "test-client")
        XCTAssertEqual(events[0].properties["app_version"], "0.4.0")
    }

    func testQueueDropsOldestEventsAtConfiguredLimit() throws {
        let suite = "AppAnalyticsReporterTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let reporter = makeReporter(defaults: defaults, transport: FailingAnalyticsTransport(), maximumQueueSize: 3)

        for index in 0..<5 { reporter.report(eventName: "model_download_started", properties: ["index": "\(index)"]) }

        let events = queuedEvents(defaults: defaults)
        XCTAssertEqual(events.count, 3)
        XCTAssertEqual(events.map { $0.properties["index"] }, ["2", "3", "4"])
    }

    func testSuccessfulFlushRemovesPersistedEvent() async throws {
        let suite = "AppAnalyticsReporterTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let delivered = expectation(description: "event delivered")
        let transport = ClosureAnalyticsTransport { events in
            XCTAssertEqual(events.first?.eventName, "app_login")
            delivered.fulfill()
        }
        let reporter = makeReporter(defaults: defaults, transport: transport)
        reporter.report(eventName: "app_login", properties: [:])
        await fulfillment(of: [delivered], timeout: 1)

        for _ in 0..<20 where !queuedEvents(defaults: defaults).isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(queuedEvents(defaults: defaults).isEmpty)
    }

    func testPermanentBatchFailureIsolatesInvalidEventWithoutDroppingValidEvent() async throws {
        let suite = "AppAnalyticsReporterTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try store(events: [event(named: "invalid"), event(named: "app_login")], defaults: defaults)
        let transport = IsolatingAnalyticsTransport()
        let reporter = makeReporter(defaults: defaults, transport: transport)

        reporter.flush()

        for _ in 0..<100 where !queuedEvents(defaults: defaults).isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(queuedEvents(defaults: defaults).isEmpty)
        XCTAssertEqual(transport.deliveredEventNames, ["app_login"])
    }

    func testTransientFailureRetriesPersistedEvent() async throws {
        let suite = "AppAnalyticsReporterTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let transport = RetryOnceAnalyticsTransport()
        let reporter = AppAnalyticsReporter(
            defaults: defaults,
            transport: transport,
            clientInfoProvider: TypefluxCloudClientInfoProvider { Self.clientInfo },
            retryDelay: .milliseconds(10),
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )

        reporter.report(eventName: "app_login", properties: [:])

        for _ in 0..<100 where !queuedEvents(defaults: defaults).isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(queuedEvents(defaults: defaults).isEmpty)
        XCTAssertGreaterThanOrEqual(transport.attemptCount, 2)
    }

    func testQueueLimitPreservesFirstOpenEvent() throws {
        let suite = "AppAnalyticsReporterTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let reporter = makeReporter(defaults: defaults, transport: FailingAnalyticsTransport(), maximumQueueSize: 2)
        reporter.reportFirstOpenIfNeeded()
        reporter.report(eventName: "model_download_started", properties: ["index": "1"])
        reporter.report(eventName: "model_download_started", properties: ["index": "2"])

        XCTAssertEqual(queuedEvents(defaults: defaults).map(\.eventName), ["app_first_open", "model_download_started"])
    }

    func testTransportRetriesWithoutInvalidAuthorization() async throws {
        let requests = AnalyticsRequestRecorder()
        AnalyticsTransportURLProtocol.handler = { request in
            requests.append(request)
            let status = request.value(forHTTPHeaderField: "Authorization") == nil ? 202 : 401
            return HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        }
        defer { AnalyticsTransportURLProtocol.handler = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AnalyticsTransportURLProtocol.self]
        let transport = URLSessionAppAnalyticsTransport(
            baseURLs: ["https://api.typeflux.test"],
            session: URLSession(configuration: configuration),
            clientInfoProvider: TypefluxCloudClientInfoProvider { Self.clientInfo },
            accessTokenProvider: { "invalid-token" }
        )

        try await transport.send(events: [event(named: "app_login")])

        XCTAssertEqual(requests.values.count, 2)
        XCTAssertEqual(requests.values[0].value(forHTTPHeaderField: "Authorization"), "Bearer invalid-token")
        XCTAssertNil(requests.values[1].value(forHTTPHeaderField: "Authorization"))
    }

    private func makeReporter(
        defaults: UserDefaults,
        transport: AppAnalyticsTransporting,
        maximumQueueSize: Int = 100
    ) -> AppAnalyticsReporter {
        AppAnalyticsReporter(
            defaults: defaults,
            transport: transport,
            clientInfoProvider: TypefluxCloudClientInfoProvider { Self.clientInfo },
            maximumQueueSize: maximumQueueSize,
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
    }

    private func queuedEvents(defaults: UserDefaults) -> [AppAnalyticsEvent] {
        guard let data = defaults.data(forKey: "analytics.pendingEvents") else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([AppAnalyticsEvent].self, from: data)) ?? []
    }

    private func store(events: [AppAnalyticsEvent], defaults: UserDefaults) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        defaults.set(try encoder.encode(events), forKey: "analytics.pendingEvents")
    }

    private func event(named name: String) -> AppAnalyticsEvent {
        AppAnalyticsEvent(
            eventID: UUID().uuidString.lowercased(), eventName: name, source: "app",
            occurredAt: Date(timeIntervalSince1970: 1_700_000_000), clientID: "test-client",
            architecture: "arm64", properties: [:]
        )
    }

    private static let clientInfo = TypefluxCloudClientInfo(
        appName: "Typeflux", appVersion: "0.4.0", clientID: "test-client",
        localeIdentifier: "en", preferredLanguages: ["en"], osName: "macOS",
        osVersion: "15.0", architecture: "arm64"
    )
}

private struct FailingAnalyticsTransport: AppAnalyticsTransporting {
    func send(events _: [AppAnalyticsEvent]) async throws { throw URLError(.notConnectedToInternet) }
}

private struct ClosureAnalyticsTransport: AppAnalyticsTransporting {
    let handler: @Sendable ([AppAnalyticsEvent]) -> Void
    init(handler: @escaping @Sendable ([AppAnalyticsEvent]) -> Void) { self.handler = handler }
    func send(events: [AppAnalyticsEvent]) async throws { handler(events) }
}

private final class IsolatingAnalyticsTransport: AppAnalyticsTransporting, @unchecked Sendable {
    private let lock = NSLock()
    private var delivered: [String] = []
    var deliveredEventNames: [String] { lock.withLock { delivered } }

    func send(events: [AppAnalyticsEvent]) async throws {
        if events.count > 1 { throw AppAnalyticsTransportError.permanent(statusCode: 400) }
        guard let event = events.first else { return }
        if event.eventName == "invalid" { throw AppAnalyticsTransportError.permanent(statusCode: 400) }
        lock.withLock { delivered.append(event.eventName) }
    }
}

private final class RetryOnceAnalyticsTransport: AppAnalyticsTransporting, @unchecked Sendable {
    private let lock = NSLock()
    private var attempts = 0
    var attemptCount: Int { lock.withLock { attempts } }

    func send(events _: [AppAnalyticsEvent]) async throws {
        let attempt = lock.withLock { () -> Int in
            attempts += 1
            return attempts
        }
        if attempt == 1 { throw URLError(.notConnectedToInternet) }
    }
}

private final class AnalyticsRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URLRequest] = []
    var values: [URLRequest] { lock.withLock { storage } }
    func append(_ request: URLRequest) { lock.withLock { storage.append(request) } }
}

private final class AnalyticsTransportURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> HTTPURLResponse)?
    override class func canInit(with _: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let response = Self.handler?(request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data())
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
