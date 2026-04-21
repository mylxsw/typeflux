import Foundation
import os

/// Process-wide registry holding the shared `CloudEndpointSelector` used by
/// every Typeflux Cloud caller (auth, LLM, ASR, updater).
///
/// Existing call sites are static (`AuthService`, `AutoUpdater.shared`), so a
/// global registry keeps the rewrite contained while still allowing tests to
/// override the selector with a stub.
enum CloudEndpointRegistry {
    private static let lock = NSLock()
    private static var override: CloudEndpointSelector?

    nonisolated(unsafe) private static var cached: CloudEndpointSelector?

    static var shared: CloudEndpointSelector {
        lock.lock()
        defer { lock.unlock() }
        if let override { return override }
        if let cached { return cached }
        let urls = AppServerConfiguration.apiBaseURLs.compactMap(URL.init(string:))
        let resolved = urls.isEmpty ? [URL(string: "https://typeflux.gulu.ai")!] : urls
        let selector = CloudEndpointSelector(
            baseURLs: resolved,
            prober: HTTPCloudEndpointProber()
        )
        cached = selector
        return selector
    }

    /// Replaces the shared selector — for use in tests only.
    static func setOverride(_ selector: CloudEndpointSelector?) {
        lock.lock()
        defer { lock.unlock() }
        override = selector
    }
}

/// Drives `CloudEndpointSelector.probeAll()` on a fixed cadence. Owned by the
/// app coordinator so probing starts when the app launches and stops cleanly
/// during teardown / tests.
@MainActor
final class CloudEndpointProbeScheduler {
    private let selector: CloudEndpointSelector
    private let interval: TimeInterval
    private let initialDelay: TimeInterval
    private var task: Task<Void, Never>?
    private let logger = Logger(subsystem: "ai.gulu.app.typeflux", category: "CloudEndpointProbeScheduler")

    init(
        selector: CloudEndpointSelector = CloudEndpointRegistry.shared,
        interval: TimeInterval = CloudEndpointSelectorConfig.default.probeInterval,
        initialDelay: TimeInterval = 1
    ) {
        self.selector = selector
        self.interval = interval
        self.initialDelay = initialDelay
    }

    func start() {
        stop()
        let interval = self.interval
        let initialDelay = self.initialDelay
        let selector = self.selector
        task = Task.detached(priority: .utility) {
            if initialDelay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(initialDelay * 1_000_000_000))
            }
            await selector.probeAll()
            while !Task.isCancelled {
                let nanos = UInt64(interval * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanos)
                if Task.isCancelled { break }
                await selector.probeAll()
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    deinit {
        task?.cancel()
    }
}
