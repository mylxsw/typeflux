import AppKit
import AVKit
import ScreenCaptureKit

@MainActor
final class ScreenRecordingCoordinator: ObservableObject {
    enum State: Equatable {
        case idle, setup, selecting, countdown, starting, recording, paused, stopping, preview, exporting, completed
    }

    @Published private(set) var state: State = .idle
    @Published var options: ScreenRecordingOptions
    @Published var selectedID = ""
    @Published private(set) var choices: [ScreenRecordingChoice] = []
    @Published private(set) var countdown = 0
    @Published private(set) var elapsed: Double = 0
    @Published private(set) var progress: Double = 0
    @Published private(set) var duration: Double = 0
    @Published var trimStart: Double = 0
    @Published var trimEnd: Double = 0
    @Published private(set) var error: String?
    @Published private(set) var savedURL: URL?
    @Published private(set) var player: AVPlayer?
    @Published private(set) var recovered: [URL] = []
    private(set) var sourceURL: URL?
    private(set) var pendingTask: Task<Void, Never>?
    var isBusy: Bool {
        state != .idle
    }

    var isOtherCaptureActive: () -> Bool = { false }
    var present: (ScreenRecordingCoordinator) -> Void = { _ in }
    var dismiss: () -> Void = {}
    var updateIndicator: (String?) -> Void = { _ in }
    var showBorder: (ScreenRecordingTarget?) -> Void = { _ in }
    private let permission: any ScreenCapturePermissionProviding
    private let capture: any ScreenCapturing
    private let overlay: any ScreenshotOverlayPresenting
    private let engine: any ScreenRecordingEngine
    private let exporter: any ScreenRecordingExporting
    private let files: ScreenRecordingFiles
    private let defaults: UserDefaults
    private let saveDirectory: () -> URL
    private let authorizeDevices: (ScreenRecordingOptions) async throws -> Void
    private let loadChoices: () async throws -> [ScreenRecordingChoice]
    private let waitSecond: () async throws -> Void
    private var sessionDirectory: URL?
    private var generation = 0
    private var timerTask: Task<Void, Never>?
    private var sleepObserver: NSObjectProtocol?
    private var startingFailure: Error?

    init(permission: any ScreenCapturePermissionProviding, capture: any ScreenCapturing,
         overlay: (any ScreenshotOverlayPresenting)? = nil,
         engine: (any ScreenRecordingEngine)? = nil,
         exporter: any ScreenRecordingExporting = ScreenRecordingExporter(),
         files: ScreenRecordingFiles = .live, defaults: UserDefaults = .standard,
         saveDirectory: @escaping () -> URL,
         authorizeDevices: @escaping (ScreenRecordingOptions) async throws -> Void = ScreenRecordingCoordinator
             .authorize,
         loadChoices: @escaping () async throws -> [ScreenRecordingChoice] = ScreenRecordingCoordinator.catalog,
         waitSecond: @escaping () async throws -> Void = { try await Task.sleep(for: .seconds(1)) }) {
        self.permission = permission
        self.capture = capture
        self.overlay = overlay ?? ScreenshotOverlayController()
        self.engine = engine ?? NativeScreenRecordingEngine()
        self.exporter = exporter
        self.files = files
        self.defaults = defaults
        self.saveDirectory = saveDirectory
        self.authorizeDevices = authorizeDevices
        self.loadChoices = loadChoices
        self.waitSecond = waitSecond
        options = .load(from: defaults)
        self.engine.onError = { [weak self] error in
            guard let self else { return }
            if state == .starting {
                startingFailure = error
            } else if state == .recording || state == .paused {
                stop(interruption: error)
            }
        }
    }

    func show(format: ScreenRecordingFormat = .mp4, region: ScreenRecordingTarget? = nil) {
        guard !isBusy else { present(self); return }
        guard !isOtherCaptureActive() else { return }
        generation += 1
        state = .setup
        options.format = format
        error = nil
        savedURL = nil
        recovered = files.recoverableSources()
        if let region {
            choices = [ScreenRecordingChoice(id: "region", title: L("recording.region"), target: region)]
            selectedID = "region"
        } else {
            choices = []; selectedID = ""
        }
        present(self)
        reloadChoices()
    }

    func reloadChoices() {
        guard state == .setup else { return }
        guard permission.isGranted else {
            permission.requestOnce()
            error = L("recording.error.permission")
            return
        }
        error = nil
        let token = generation
        pendingTask?.cancel()
        pendingTask = Task { [weak self, loadChoices] in
            do {
                let values = try await loadChoices()
                try Task.checkCancellation()
                guard let self, generation == token, state == .setup else { return }
                choices = choices.filter { $0.id == "region" } + values
                if !choices.contains(where: { $0.id == selectedID }) {
                    selectedID = choices.first?.id ?? ""
                }
            } catch {
                guard let self, generation == token, !(error is CancellationError) else { return }
                self.error = error.localizedDescription
            }
        }
    }

    func openPermissions() {
        permission.openSystemSettings()
    }

    func start() {
        guard state == .setup, let target = choices.first(where: { $0.id == selectedID })?.target else { return }
        guard permission.isGranted else { error = L("recording.error.permission"); return }
        options.save(to: defaults)
        pendingTask?.cancel()
        state = .countdown
        countdown = max(0, min(5, options.countdown))
        error = nil
        startingFailure = nil
        let token = generation
        let options = options
        pendingTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await authorizeDevices(options)
                try Task.checkCancellation()
                while countdown > 0 {
                    updateIndicator(String(countdown))
                    try await waitSecond()
                    try Task.checkCancellation()
                    countdown -= 1
                }
                state = .starting
                showBorder(target)
                sessionDirectory = try files.createSession(options: options)
                let url = sessionDirectory!.appendingPathComponent("source.mov")
                try await engine.start(target: target, options: options, url: url)
                try Task.checkCancellation()
                if let startingFailure {
                    throw startingFailure
                }
                guard generation == token else { return }
                state = .recording
                elapsed = 0
                monitor()
            } catch {
                await engine.cancel()
                guard generation == token else { return }
                if let sessionDirectory {
                    files.discard(sessionDirectory)
                }
                sessionDirectory = nil
                state = .setup
                self.error = error is CancellationError ? nil : error.localizedDescription
                showBorder(nil)
                updateIndicator(nil)
            }
        }
    }

    func togglePause() {
        guard state == .recording || state == .paused else { return }
        let paused = state == .recording
        engine.setPaused(paused)
        state = paused ? .paused : .recording
    }

    private func monitor() {
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.stop(interruption: ScreenRecordingFailure.interrupted) } }
        timerTask = Task { [weak self] in
            let started = Date()
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, state == .recording || state == .paused else { return }
                elapsed = await engine.elapsed()
                updateIndicator((state == .paused ? "Ⅱ " : "● ") + Self.timeLabel(elapsed))
                if let limit = options.durationLimit, elapsed >= limit {
                    stop(); return
                }
                if elapsed == 0, Date().timeIntervalSince(started) > 10 {
                    stop(interruption: ScreenRecordingFailure.noFrames)
                    return
                }
            }
        }
    }

    func stop(interruption: Error? = nil) {
        guard state == .recording || state == .paused else { return }
        state = .stopping
        stopMonitoring()
        if let interruption {
            error = interruption.localizedDescription
        }
        let token = generation
        pendingTask = Task { [weak self] in
            guard let self else { return }
            do {
                let url = try await engine.stop()
                try Task.checkCancellation()
                guard generation == token else { return }
                try await preparePreview(url)
            } catch {
                guard generation == token else { return }
                self.error = error.localizedDescription
                state = .setup
            }
            showBorder(nil)
        }
    }

    func recover(_ url: URL) {
        guard state == .setup else { return }
        pendingTask?.cancel()
        state = .stopping
        sessionDirectory = url.deletingLastPathComponent()
        error = nil
        let token = generation
        pendingTask = Task { [weak self] in
            guard let self else { return }
            do { try await preparePreview(url) } catch {
                guard generation == token else { return }
                self.error = error.localizedDescription
                state = .setup
            }
        }
    }

    private func preparePreview(_ url: URL) async throws {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        try Task.checkCancellation()
        guard duration.isFinite, duration > 0 else { throw ScreenRecordingFailure.noFrames }
        sourceURL = url
        self.duration = duration
        trimStart = 0
        trimEnd = options.format == .gif ? min(30, duration) : duration
        player = AVPlayer(url: url)
        state = .preview
        present(self)
    }

    func seek(_ seconds: Double) {
        player?.pause()
        player?.seek(to: CMTime(seconds: max(0, min(duration, seconds)), preferredTimescale: 600))
    }

    func export(directory: URL? = nil) {
        guard state == .preview, let sourceURL, let sessionDirectory else { return }
        let trim = ScreenRecordingTrim(start: trimStart, end: trimEnd)
        do { _ = try trim.validated(duration: duration, format: options.format) } catch { self.error = error.localizedDescription; return }
        player?.pause()
        state = .exporting
        error = nil
        progress = 0
        let format = options.format
        let output = sessionDirectory.appendingPathComponent(UUID().uuidString + "." + format.rawValue)
        let destination = directory ?? saveDirectory()
        let token = generation
        pendingTask = Task { [weak self, exporter, files] in
            do {
                try await exporter
                    .export(source: sourceURL, destination: output, format: format, trim: trim) { [weak self] value in
                        Task { @MainActor in
                            guard let self, self.generation == token, self.state == .exporting else { return }
                            self.progress = value
                        }
                    }
                try Task.checkCancellation()
                let published = try await Task.detached { try files.publish(output, in: destination, format: format) }
                    .value
                guard let self, generation == token else { return }
                savedURL = published
                player = nil
                self.sourceURL = nil
                files.discard(sessionDirectory)
                self.sessionDirectory = nil
                state = .completed
            } catch {
                guard let self, generation == token else { return }
                try? FileManager.default.removeItem(at: output)
                self.error = error is CancellationError ? nil : error.localizedDescription
                state = .preview
            }
        }
    }

    func cancelExport() {
        if state == .exporting {
            pendingTask?.cancel()
        }
    }

    func cancel() {
        guard state != .idle else { return }
        generation += 1
        let previous = pendingTask
        previous?.cancel()
        stopMonitoring()
        overlay.dismiss()
        state = .stopping
        pendingTask = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            await engine.cancel()
            player?.pause()
            player = nil
            sourceURL = nil
            if let sessionDirectory {
                files.discard(sessionDirectory)
            }
            sessionDirectory = nil
            showBorder(nil)
            state = .idle
            dismiss()
        }
    }

    /// A normal quit finishes the container and leaves the source available for recovery.
    func prepareForTermination() async {
        switch state {
        case .recording, .paused: stop()
        case .countdown, .starting, .selecting, .setup: cancel()
        case .exporting: cancelExport()
        default: break
        }
        await pendingTask?.value
        player?.pause()
        stopMonitoring()
    }

    private func stopMonitoring() {
        timerTask?.cancel()
        timerTask = nil
        if let sleepObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver)
        }
        sleepObserver = nil
        updateIndicator(nil)
    }

}

extension ScreenRecordingCoordinator {
    func selectRegion() {
        guard state == .setup, permission.isGranted else { return }
        pendingTask?.cancel()
        state = .selecting
        dismiss()
        pendingTask = Task { [weak self, capture] in
            do {
                let snapshot = try await capture.snapshot(ScreenCaptureRequest(windowExclusion: .screenshotControls))
                try Task.checkCancellation()
                guard let self, state == .selecting else { return }
                overlay.present(snapshot) { [weak self] event in
                    guard let self, state == .selecting else { return }
                    switch event {
                    case .committed: overlay.finish(.copy)
                    case let .finish(_, displayID, rect, _):
                        overlay.dismiss()
                        choices.removeAll { $0.id == "region" }
                        choices.insert(ScreenRecordingChoice(id: "region", title: L("recording.region"),
                                                             target: .region(displayID: displayID, rect: rect)), at: 0)
                        selectedID = "region"
                        state = .setup
                        present(self)
                    case .cancelled:
                        overlay.dismiss()
                        state = .setup
                        present(self)
                    default: break
                    }
                }
            } catch {
                guard let self, state == .selecting else { return }
                state = .setup
                self.error = error.localizedDescription
                present(self)
            }
        }
    }

}
