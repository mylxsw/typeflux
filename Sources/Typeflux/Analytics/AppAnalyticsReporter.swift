import Foundation

protocol AnalyticsEventReporting: AnyObject, Sendable {
    func report(eventName: String, properties: [String: String])
    func reportFirstOpenIfNeeded()
}

final class NoopAnalyticsEventReporter: AnalyticsEventReporting, @unchecked Sendable {
    static let shared = NoopAnalyticsEventReporter()
    private init() {}
    func report(eventName _: String, properties _: [String: String]) {}
    func reportFirstOpenIfNeeded() {}
}

struct AppAnalyticsEvent: Codable, Equatable, Sendable {
    let eventID: String
    let eventName: String
    let source: String
    let occurredAt: Date
    let clientID: String
    let architecture: String
    let properties: [String: String]

    enum CodingKeys: String, CodingKey {
        case eventID = "event_id"
        case eventName = "event_name"
        case source
        case occurredAt = "occurred_at"
        case clientID = "client_id"
        case architecture
        case properties
    }
}

protocol AppAnalyticsTransporting: Sendable {
    func send(events: [AppAnalyticsEvent]) async throws
}

enum AppAnalyticsTransportError: Error, Equatable {
    case permanent(statusCode: Int)
    case transient(statusCode: Int)
}

struct URLSessionAppAnalyticsTransport: AppAnalyticsTransporting {
    let baseURLs: [String]
    let session: URLSession
    let clientInfoProvider: TypefluxCloudClientInfoProvider
    let accessTokenProvider: @Sendable () -> String?

    init(
        baseURLs: [String] = AppServerConfiguration.apiBaseURLs,
        session: URLSession = .shared,
        clientInfoProvider: TypefluxCloudClientInfoProvider = .live,
        accessTokenProvider: @escaping @Sendable () -> String? = {
            guard let stored = KeychainTokenStore.loadToken(),
                  stored.expiresAt > Int(Date().timeIntervalSince1970)
            else { return nil }
            return stored.token
        }
    ) {
        self.baseURLs = baseURLs
        self.session = session
        self.clientInfoProvider = clientInfoProvider
        self.accessTokenProvider = accessTokenProvider
    }

    func send(events: [AppAnalyticsEvent]) async throws {
        let body = try JSONEncoder.analyticsEncoder.encode(EventBatch(events: events))
        var lastError: Error = URLError(.badURL)
        for rawBaseURL in baseURLs {
            guard let baseURL = URL(string: rawBaseURL) else { continue }
            var request = URLRequest(
                url: AuthEndpointResolver.resolve(baseURL: baseURL, path: "/api/v1/analytics/events/batch")
            )
            request.httpMethod = "POST"
            request.httpBody = body
            request.timeoutInterval = 8
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if let token = accessTokenProvider() {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            TypefluxCloudRequestHeaders.applyClientInfo(to: &request, provider: clientInfoProvider)
            do {
                let initialResponse = try await session.data(for: request)
                var response = initialResponse.1
                if (response as? HTTPURLResponse)?.statusCode == 401, request.value(forHTTPHeaderField: "Authorization") != nil {
                    request.setValue(nil, forHTTPHeaderField: "Authorization")
                    (_, response) = try await session.data(for: request)
                }
                guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
                if (200..<300).contains(http.statusCode) { return }
                if (400..<500).contains(http.statusCode), http.statusCode != 408, http.statusCode != 429 {
                    throw AppAnalyticsTransportError.permanent(statusCode: http.statusCode)
                }
                throw AppAnalyticsTransportError.transient(statusCode: http.statusCode)
            } catch {
                if case AppAnalyticsTransportError.permanent = error { throw error }
                lastError = error
            }
        }
        throw lastError
    }

    private struct EventBatch: Encodable {
        let events: [AppAnalyticsEvent]
    }
}

final class AppAnalyticsReporter: AnalyticsEventReporting, @unchecked Sendable {
    private let defaults: UserDefaults
    private let transport: AppAnalyticsTransporting
    private let clientInfoProvider: TypefluxCloudClientInfoProvider
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private let queueKey: String
    private let firstOpenKey: String
    private let maximumQueueSize: Int
    private let retryDelay: Duration
    private var isFlushing = false
    private var retryTask: Task<Void, Never>?

    init(
        defaults: UserDefaults = .standard,
        transport: AppAnalyticsTransporting = URLSessionAppAnalyticsTransport(),
        clientInfoProvider: TypefluxCloudClientInfoProvider = .live,
        queueKey: String = "analytics.pendingEvents",
        firstOpenKey: String = "analytics.firstOpenReported",
        maximumQueueSize: Int = 100,
        retryDelay: Duration = .seconds(30),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.defaults = defaults
        self.transport = transport
        self.clientInfoProvider = clientInfoProvider
        self.queueKey = queueKey
        self.firstOpenKey = firstOpenKey
        self.maximumQueueSize = maximumQueueSize
        self.retryDelay = retryDelay
        self.now = now
    }

    func reportFirstOpenIfNeeded() {
        lock.withLock {
            guard !defaults.bool(forKey: firstOpenKey) else { return }
            appendToQueue(makeEvent(eventName: "app_first_open", properties: clientProperties()))
            defaults.set(true, forKey: firstOpenKey)
        }
        flush()
    }

    func report(eventName: String, properties: [String: String] = [:]) {
        lock.withLock { appendToQueue(makeEvent(eventName: eventName, properties: properties)) }
        flush()
    }

    func flush() {
        let events = lock.withLock { () -> [AppAnalyticsEvent] in
            guard !isFlushing else { return [] }
            let events = loadQueue()
            guard !events.isEmpty else { return [] }
            isFlushing = true
            return Array(events.prefix(20))
        }
        guard !events.isEmpty else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await transport.send(events: events)
                let sentIDs = Set(events.map(\.eventID))
                self.lock.withLock {
                    self.saveQueue(self.loadQueue().filter { !sentIDs.contains($0.eventID) })
                    self.isFlushing = false
                    self.retryTask?.cancel()
                    self.retryTask = nil
                }
                self.flush()
            } catch AppAnalyticsTransportError.permanent {
                var terminalIDs = Set<String>()
                var hasTransientFailure = false
                for event in events {
                    do {
                        try await self.transport.send(events: [event])
                        terminalIDs.insert(event.eventID)
                    } catch AppAnalyticsTransportError.permanent {
                        terminalIDs.insert(event.eventID)
                    } catch {
                        hasTransientFailure = true
                        break
                    }
                }
                self.lock.withLock {
                    self.saveQueue(self.loadQueue().filter { !terminalIDs.contains($0.eventID) })
                    self.isFlushing = false
                }
                if hasTransientFailure { self.scheduleRetry() } else { self.flush() }
            } catch {
                self.lock.withLock { self.isFlushing = false }
                self.scheduleRetry()
            }
        }
    }

    private func makeEvent(eventName: String, properties: [String: String]) -> AppAnalyticsEvent {
        let info = clientInfoProvider.info()
        return AppAnalyticsEvent(
            eventID: UUID().uuidString.lowercased(), eventName: eventName, source: "app",
            occurredAt: now(), clientID: info.clientID, architecture: info.architecture,
            properties: properties.merging(clientProperties(), uniquingKeysWith: { _, clientValue in clientValue })
        )
    }

    private func appendToQueue(_ event: AppAnalyticsEvent) {
        var events = loadQueue()
        events.append(event)
        if events.count > maximumQueueSize {
            let firstOpen = events.first { $0.eventName == "app_first_open" }
            events = Array(events.suffix(maximumQueueSize))
            if let firstOpen, !events.contains(where: { $0.eventID == firstOpen.eventID }), !events.isEmpty {
                events[0] = firstOpen
            }
        }
        saveQueue(events)
    }

    private func scheduleRetry() {
        let delay = retryDelay
        lock.withLock {
            guard retryTask == nil else { return }
            retryTask = Task { [weak self] in
                try? await Task.sleep(for: delay)
                guard let self, !Task.isCancelled else { return }
                self.lock.withLock { self.retryTask = nil }
                self.flush()
            }
        }
    }

    private func clientProperties() -> [String: String] {
        let info = clientInfoProvider.info()
        return ["app_version": info.appVersion, "os_name": info.osName, "os_version": info.osVersion,
                "locale": info.localeIdentifier]
    }

    private func loadQueue() -> [AppAnalyticsEvent] {
        guard let data = defaults.data(forKey: queueKey) else { return [] }
        return (try? JSONDecoder.analyticsDecoder.decode([AppAnalyticsEvent].self, from: data)) ?? []
    }

    private func saveQueue(_ events: [AppAnalyticsEvent]) {
        if events.isEmpty { defaults.removeObject(forKey: queueKey); return }
        if let data = try? JSONEncoder.analyticsEncoder.encode(events) { defaults.set(data, forKey: queueKey) }
    }
}

private extension JSONEncoder {
    static var analyticsEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var analyticsDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
