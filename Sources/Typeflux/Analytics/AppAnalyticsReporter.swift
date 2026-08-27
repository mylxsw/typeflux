import Foundation
import os

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

enum AnalyticsPropertyKeys {
    static let appVersion = "app_version"
    static let osName = "os_name"
    static let osVersion = "os_version"
    static let locale = "locale"
    static let sessionID = "session_id"

    static let allowedEventProperties: Set<String> = [
        "attempt_id", "job_id", "model_kind", "model_type", "model_identifier",
        "download_source", "source_host", "normalized_path", "retry_index",
        "duration_ms", "job_duration_ms", "status", "error_category",
        "launch_type", "flow_id", "recording_mode", "intent", "stt_provider",
        "local_model", "streaming_preview", "audio_seconds", "output_chars",
        "pipeline_duration_ms", "apply_outcome", "injection_method", "target_app_category",
        "stage", "error_kind", "step", "last_step", "skipped", "duration_seconds", "llm_provider",
        "audio_signal", "audio_duration_seconds", "audio_rms_db", "audio_peak_db", "low_energy_retry",
        "permission", "granted", "totalSessions", "successfulSessions", "failedSessions",
        "dictationCount", "personaRewriteCount", "editSelectionCount", "askAnswerCount",
        "totalRecordingSeconds", "totalCharacters"
    ]
}

final class SettingsAwareAnalyticsEventReporter: AnalyticsEventReporting, @unchecked Sendable {
    private let settingsStore: SettingsStore
    private let reporter: AppAnalyticsReporter
    private let lock = NSLock()
    private var isEnabled: Bool
    private var settingsObserver: NSObjectProtocol?

    init(
        settingsStore: SettingsStore,
        reporter: AppAnalyticsReporter? = nil
    ) {
        self.settingsStore = settingsStore
        self.reporter = reporter ?? AppAnalyticsReporter(defaults: settingsStore.defaults)
        isEnabled = settingsStore.analyticsSharingEnabled
        self.reporter.setEnabled(isEnabled)
        settingsObserver = NotificationCenter.default.addObserver(
            forName: .analyticsSharingDidChange,
            object: settingsStore.defaults,
            queue: nil
        ) { [weak self] _ in
            self?.refreshEnabledState()
        }
    }

    deinit {
        if let settingsObserver { NotificationCenter.default.removeObserver(settingsObserver) }
    }

    func report(eventName: String, properties: [String: String]) {
        activeReporter().report(eventName: eventName, properties: properties)
    }

    func reportFirstOpenIfNeeded() {
        activeReporter().reportFirstOpenIfNeeded()
    }

    private func activeReporter() -> AnalyticsEventReporting {
        refreshEnabledState()
        return lock.withLock {
            if isEnabled { return reporter }
            return NoopAnalyticsEventReporter.shared
        }
    }

    private func refreshEnabledState() {
        let nextValue = settingsStore.analyticsSharingEnabled
        let changed = lock.withLock { () -> Bool in
            guard isEnabled != nextValue else { return false }
            isEnabled = nextValue
            return true
        }
        if changed { reporter.setEnabled(nextValue) }
    }
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
    private static let logger = Logger(subsystem: "ai.gulu.app.typeflux", category: "AppAnalyticsReporter")
    private let defaults: UserDefaults
    private let transport: AppAnalyticsTransporting
    private let clientInfoProvider: TypefluxCloudClientInfoProvider
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private let queueKey: String
    private let firstOpenKey: String
    private let maximumQueueSize: Int
    private let retryDelay: Duration
    private let sessionID: String
    private var isEnabled = true
    private var generation = 0
    private var isFlushing = false
    private var retryTask: Task<Void, Never>?
    private var flushTask: Task<Void, Never>?

    init(
        defaults: UserDefaults = .standard,
        transport: AppAnalyticsTransporting = URLSessionAppAnalyticsTransport(),
        clientInfoProvider: TypefluxCloudClientInfoProvider = .live,
        queueKey: String = "analytics.pendingEvents",
        firstOpenKey: String = "analytics.firstOpenReported",
        maximumQueueSize: Int = 100,
        retryDelay: Duration = .seconds(30),
        sessionID: String = UUID().uuidString.lowercased(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.defaults = defaults
        self.transport = transport
        self.clientInfoProvider = clientInfoProvider
        self.queueKey = queueKey
        self.firstOpenKey = firstOpenKey
        self.maximumQueueSize = maximumQueueSize
        self.retryDelay = retryDelay
        self.sessionID = sessionID
        self.now = now
    }

    func setEnabled(_ enabled: Bool) {
        lock.withLock {
            guard isEnabled != enabled else { return }
            isEnabled = enabled
            generation += 1
            guard !enabled else { return }
            retryTask?.cancel()
            retryTask = nil
            flushTask?.cancel()
            flushTask = nil
            isFlushing = false
            defaults.removeObject(forKey: queueKey)
        }
        if enabled { flush() }
    }

    func reportFirstOpenIfNeeded() {
        lock.withLock {
            guard isEnabled else { return }
            guard !defaults.bool(forKey: firstOpenKey) else { return }
            appendToQueue(makeEvent(eventName: "app_first_open", properties: clientProperties()))
            defaults.set(true, forKey: firstOpenKey)
        }
        flush()
    }

    func report(eventName: String, properties: [String: String] = [:]) {
        let filteredProperties = properties.filter { key, _ in
            let allowed = AnalyticsPropertyKeys.allowedEventProperties.contains(key)
            if !allowed { Self.logger.debug("Dropping non-allowlisted analytics property: \(key, privacy: .public)") }
            return allowed
        }
        lock.withLock {
            guard isEnabled else { return }
            appendToQueue(makeEvent(eventName: eventName, properties: filteredProperties))
        }
        flush()
    }

    func flush() {
        let pending = lock.withLock { () -> (events: [AppAnalyticsEvent], generation: Int)? in
            guard isEnabled, !isFlushing else { return nil }
            let events = loadQueue()
            guard !events.isEmpty else { return nil }
            isFlushing = true
            return (Array(events.prefix(20)), generation)
        }
        guard let pending else { return }
        let events = pending.events
        let flushGeneration = pending.generation
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                try await transport.send(events: events)
                let sentIDs = Set(events.map(\.eventID))
                let shouldContinue = self.lock.withLock { () -> Bool in
                    guard self.isEnabled, self.generation == flushGeneration else { return false }
                    self.saveQueue(self.loadQueue().filter { !sentIDs.contains($0.eventID) })
                    self.isFlushing = false
                    self.flushTask = nil
                    self.retryTask?.cancel()
                    self.retryTask = nil
                    return true
                }
                if shouldContinue { self.flush() }
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
                let shouldContinue = self.lock.withLock { () -> Bool in
                    guard self.isEnabled, self.generation == flushGeneration else { return false }
                    self.saveQueue(self.loadQueue().filter { !terminalIDs.contains($0.eventID) })
                    self.isFlushing = false
                    self.flushTask = nil
                    return true
                }
                guard shouldContinue else { return }
                if hasTransientFailure { self.scheduleRetry() } else { self.flush() }
            } catch {
                let shouldRetry = self.lock.withLock { () -> Bool in
                    guard self.isEnabled, self.generation == flushGeneration else { return false }
                    self.isFlushing = false
                    self.flushTask = nil
                    return true
                }
                if shouldRetry { self.scheduleRetry() }
            }
        }
        lock.withLock {
            if isEnabled, isFlushing, generation == flushGeneration { flushTask = task } else { task.cancel() }
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
            guard isEnabled, retryTask == nil else { return }
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
        return [
            AnalyticsPropertyKeys.appVersion: info.appVersion,
            AnalyticsPropertyKeys.osName: info.osName,
            AnalyticsPropertyKeys.osVersion: info.osVersion,
            AnalyticsPropertyKeys.locale: info.localeIdentifier,
            AnalyticsPropertyKeys.sessionID: sessionID
        ]
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
