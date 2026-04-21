import Foundation

extension Notification.Name {
    static let autoModelDownloadStateDidChange = Notification.Name(
        "AutoModelDownloadService.stateDidChange",
    )
}

// MARK: - Download Status

enum AutoModelDownloadStatus: Equatable {
    case disabled
    case notStarted
    case downloading(progress: Double)
    case completed
    case failed
}

// MARK: - Persistent State

private struct AutoModelState: Codable {
    var isCompleted: Bool = false
    var completedStoragePath: String?
    var completedModelType: String?
    var completedModelIdentifier: String?
    var attemptCount: Int = 0
    var lastAttemptDate: Date?
    var nextRetryDate: Date?
}

// MARK: - AutoModelDownloadService

/// Silently downloads and manages the device-appropriate local STT model in the background.
///
/// - All Macs (both Apple Silicon and Intel) use SenseVoice (sensevoice-small-coreml).
///
/// The service maintains its own state independently of the user's local model settings,
/// so it never overwrites the user's manually configured model record.
///
/// Retry strategy:
/// - On every app launch: retry immediately if not completed.
/// - Within a session after failure: exponential backoff (1 min → 3 min → 9 min … capped at 3 h).
final class AutoModelDownloadService {

    // MARK: - Threading
    // All mutable state is protected by stateLock.
    // UI notifications are always dispatched to the main queue.
    private let stateLock = NSLock()

    // MARK: - Public observable state (read on any thread; assigned under stateLock, notified on main)
    private var _status: AutoModelDownloadStatus = .notStarted
    var status: AutoModelDownloadStatus {
        stateLock.withLock { _status }
    }

    /// True when the auto model is ready to use for transcription.
    /// Only ever transitions false → true.
    var isModelReady: Bool {
        stateLock.withLock { _readyStoragePath != nil }
    }

    // MARK: - Private

    private let modelManager: LocalModelManager
    private let settingsStore: SettingsStore
    private let notificationService: LocalNotificationSending

    private var _readyConfig: LocalSTTConfiguration?
    private var _readyStoragePath: String?

    private var downloadTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?

    private static let stateDefaultsKey = "stt.autoModelDownload.state"
    private static let maxBackoffInterval: TimeInterval = 3 * 60 * 60 // 3 hours

    init(
        modelManager: LocalModelManager,
        settingsStore: SettingsStore,
        notificationService: LocalNotificationSending = NoopLocalNotificationService(),
    ) {
        self.modelManager = modelManager
        self.settingsStore = settingsStore
        self.notificationService = notificationService
        NotificationCenter.default.addObserver(
            forName: .localOptimizationDidEnable,
            object: nil,
            queue: .main,
        ) { [weak self] _ in
            self?.triggerIfNeeded()
        }
    }

    // MARK: - Public API

    /// Call once on app start. Starts a download if the model is not yet ready.
    func triggerIfNeeded() {
        guard settingsStore.localOptimizationEnabled else {
            setStatus(.disabled)
            return
        }

        let config = Self.recommendedConfiguration()

        // If already downloaded in a previous session, mark ready immediately.
        let state = loadState()
        if state.isCompleted,
           let path = state.completedStoragePath,
           state.completedModelType == config.model.rawValue,
           state.completedModelIdentifier == config.modelIdentifier,
           modelManager.isStoragePathReady(path, for: config.model) {
            markReady(config: config, storagePath: path)
            return
        }

        // Always attempt download on launch (regardless of retry timer).
        startDownload()
    }

    /// Creates a ready-to-use transcriber, or nil if the model is not yet available.
    /// Safe to call from any thread.
    func makeTranscriberIfReady() -> (any Transcriber)? {
        stateLock.lock()
        let config = _readyConfig
        let path = _readyStoragePath
        stateLock.unlock()

        guard let config, let path else { return nil }

        switch config.model {
        case .whisperLocal, .whisperLocalLarge:
            let modelName = config.modelIdentifier.hasPrefix("whisperkit-")
                ? String(config.modelIdentifier.dropFirst("whisperkit-".count))
                : config.modelIdentifier
            return WhisperKitTranscriber(modelName: modelName, modelFolder: path)
        case .senseVoiceSmall:
            return SenseVoiceTranscriber(modelIdentifier: config.modelIdentifier, modelFolder: path)
        case .qwen3ASR:
            return Qwen3ASRTranscriber(modelIdentifier: config.modelIdentifier, modelFolder: path)
        }
    }

    // MARK: - Device Detection

    static func recommendedConfiguration() -> LocalSTTConfiguration {
        return LocalSTTConfiguration(
            model: .senseVoiceSmall,
            modelIdentifier: LocalSTTModel.senseVoiceSmall.defaultModelIdentifier,
            downloadSource: .huggingFace,
            autoSetup: true,
        )
    }

    // MARK: - Download

    private func startDownload() {
        retryTask?.cancel()
        retryTask = nil
        downloadTask?.cancel()
        downloadTask = Task { [weak self] in
            await self?.performDownload()
        }
    }

    private func performDownload() async {
        let config = Self.recommendedConfiguration()
        setStatus(.downloading(progress: 0))

        var state = loadState()
        state.attemptCount += 1
        state.lastAttemptDate = Date()
        state.completedModelType = config.model.rawValue
        state.completedModelIdentifier = config.modelIdentifier
        saveState(state)

        do {
            let storagePath = try await modelManager.downloadModelFilesOnly(
                configuration: config,
            ) { [weak self] update in
                self?.setStatus(.downloading(progress: update.progress))
            }

            guard modelManager.isStoragePathReady(storagePath, for: config.model) else {
                throw NSError(
                    domain: "AutoModelDownloadService",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Model files not usable after download"],
                )
            }

            markReady(config: config, storagePath: storagePath)

            var completedState = loadState()
            completedState.isCompleted = true
            completedState.completedStoragePath = storagePath
            completedState.nextRetryDate = nil
            saveState(completedState)
            await notifyLocalModelReady()

        } catch {
            guard !Task.isCancelled else { return }
            NetworkDebugLogger.logError(context: "Auto model download failed", error: error)
            setStatus(.failed)

            var failedState = loadState()
            failedState.nextRetryDate = Date().addingTimeInterval(
                Self.backoffInterval(for: failedState.attemptCount),
            )
            saveState(failedState)

            scheduleRetry(after: Self.backoffInterval(for: failedState.attemptCount))
        }
    }

    private func notifyLocalModelReady() async {
        await notificationService.sendLocalNotification(
            title: L("notification.localModelReady.title"),
            body: L("notification.localModelReady.body"),
            identifier: "ai.gulu.app.typeflux.local-model-ready",
        )
    }

    private func markReady(config: LocalSTTConfiguration, storagePath: String) {
        stateLock.withLock {
            _readyConfig = config
            _readyStoragePath = storagePath
            _status = .completed
        }
        notifyStateChanged()
    }

    private func setStatus(_ newStatus: AutoModelDownloadStatus) {
        let needsNotify = stateLock.withLock { () -> Bool in
            let wasDownloading: Bool
            if case .downloading = _status { wasDownloading = true } else { wasDownloading = false }
            let isDownloading: Bool
            if case .downloading = newStatus { isDownloading = true } else { isDownloading = false }
            _status = newStatus
            return wasDownloading != isDownloading
        }
        if needsNotify {
            notifyStateChanged()
        }
    }

    private func notifyStateChanged() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .autoModelDownloadStateDidChange, object: nil)
        }
    }

    // MARK: - Retry Scheduling

    private func scheduleRetry(after interval: TimeInterval) {
        retryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.startDownload()
        }
    }

    private static func backoffInterval(for attemptCount: Int) -> TimeInterval {
        let base: TimeInterval = 60 // 1 minute
        let exponent = max(0, attemptCount - 1)
        return min(base * pow(3.0, Double(exponent)), maxBackoffInterval)
    }

    // MARK: - State Persistence

    private func loadState() -> AutoModelState {
        guard
            let data = settingsStore.defaults.data(forKey: Self.stateDefaultsKey),
            let state = try? JSONDecoder().decode(AutoModelState.self, from: data)
        else {
            return AutoModelState()
        }
        return state
    }

    private func saveState(_ state: AutoModelState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        settingsStore.defaults.set(data, forKey: Self.stateDefaultsKey)
    }
}
