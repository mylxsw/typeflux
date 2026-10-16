// swiftlint:disable file_length
import AppKit
import AVFoundation
import Combine
import TypefluxMediaProtocol
import ScreenCaptureKit

@MainActor
final class ScreenRecordingCoordinator: ObservableObject {
    enum State: Equatable {
        case idle, setup, selecting, countdown, starting, recording, paused, stopping, preview, exporting, completed
    }

    @Published private(set) var state: State = .idle
    @Published var options: ScreenRecordingOptions
    @Published var selectedID = ""
    @Published private(set) var sourceKind: ScreenRecordingSourceKind = .display
    @Published private(set) var isLoadingSources = false
    @Published private(set) var permissionFailure: ScreenRecordingFailure?
    @Published private(set) var choices: [ScreenRecordingChoice] = []
    @Published private(set) var countdown = 0
    @Published private(set) var elapsed: Double = 0
    @Published private(set) var progress: Double = 0
    @Published private(set) var duration: Double = 0
    @Published var trimStart: Double = 0
    @Published var trimEnd: Double = 0
    @Published private(set) var error: String?
    @Published private(set) var savedURL: URL?
    let playback: ClipboardAudioPlayback
    private let previewScope = AskImagePresentationScope()
    private var previewAuthorized = false
    private var previewObservation: AnyCancellable?
    private var accountObservers: [NSObjectProtocol] = []
    @Published private(set) var recovered: [URL] = []
    @Published var fileName = ""
    @Published var outputDirectory: URL? {
        didSet {
            if let outputDirectory {
                defaults.set(outputDirectory.path, forKey: "screenshot.recording.directory")
            }
        }
    }

    var currentTime: Double { playback.elapsed }
    var isPlaying: Bool { playback.isPlaying }
    var canUsePreview: Bool { previewAuthorized }
    @Published private(set) var media = ScreenRecordingPreviewMedia()
    var prepareCapture: () async -> Void = {}
    var liveSession: AVCaptureSession? {
        engine.previewSession
    }

    var liveAudioLevel: Float {
        engine.audioLevel
    }

    private var mediaTask: Task<Void, Never>?
    private var deviceTask: Task<Void, Never>?
    private var countdownWait: Task<Void, Error>?
    private(set) var sourceURL: URL?
    private(set) var pendingTask: Task<Void, Never>?
    var screenPermissionGranted: Bool {
        permission.isGranted
    }

    var defaultDestinationDirectory: URL {
        saveDirectory()
    }

    var isBusy: Bool {
        state != .idle
    }

    /// Finished media owns its editor, but no longer owns the capture pipeline.
    var isCaptureActive: Bool {
        ![.idle, .preview, .exporting, .completed].contains(state)
    }

    var isOtherCaptureActive: () -> Bool = { false }
    var present: (ScreenRecordingCoordinator) -> Void = { _ in }
    var dismiss: () -> Void = {}
    var copyPublishedFile: (URL) -> Void = ScreenRecordingCoordinator.copyFile
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
         waitSecond: @escaping () async throws -> Void = { try await Task.sleep(for: .seconds(1)) },
         playback: ClipboardAudioPlayback? = nil) {
        self.playback = playback ?? ClipboardAudioPlayback(video: true, open: { try await ClipboardPlaybackProcess.open($0, video: true, recording: true) })
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
        previewObservation = self.playback.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        for name in [Notification.Name.authDidLogin, .authDidLogout, .authTokenDidRefresh] {
            accountObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.retirePreview() }
            })
        }
        self.engine.onError = { [weak self] error in
            guard let self else { return }
            if state == .starting {
                startingFailure = error
            } else if state == .recording || state == .paused {
                stop(interruption: error)
            }
        }
    }
    deinit { accountObservers.forEach(NotificationCenter.default.removeObserver); mediaTask?.cancel() }
}

extension ScreenRecordingCoordinator {
    func start() {
        guard canStart, let target = choices.first(where: { $0.id == selectedID })?.target else { return }
        guard permission.isGranted else {
            permissionFailure = .permission
            error = L("recording.error.permission")
            return
        }
        options.save(to: defaults)
        defaults.set(sourceKind.rawValue, forKey: "screenshot.recording.sourceKind")
        pendingTask?.cancel()
        isLoadingSources = false
        state = .countdown
        countdown = max(0, min(10, options.countdown))
        error = nil
        permissionFailure = nil
        startingFailure = nil
        let token = generation
        let options = options
        pendingTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await authorizeDevices(options)
                try Task.checkCancellation()
                try await runCountdown()
                state = .starting
                await prepareCapture()
                try Task.checkCancellation()
                showBorder(target)
                sessionDirectory = try files.createSession(options: options)
                try Data(sourceKind.rawValue.utf8).write(
                    to: sessionDirectory!.appendingPathComponent("source-kind.txt"),
                    options: .atomic
                )
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
            } catch { await handleStartupFailure(error, token: token) }
        }
    }

    private func handleStartupFailure(_ error: Error, token: Int) async {
        await engine.cancel()
        guard generation == token else { return }
        if let sessionDirectory {
            files.discard(sessionDirectory)
        }
        sessionDirectory = nil
        state = .setup
        self.error = error is CancellationError ? nil : error.localizedDescription
        permissionFailure = (error as? ScreenRecordingFailure).flatMap {
            [.permission, .microphonePermission, .cameraPermission].contains($0) ? $0 : nil
        }
        showBorder(nil)
        updateIndicator(nil)
    }

    private func runCountdown() async throws {
        while countdown > 0 {
            updateIndicator(String(countdown))
            let delay = Task { try await waitSecond() }
            countdownWait = delay
            do { try await delay.value } catch {
                if countdown > 0 {
                    throw error
                }
            }
            countdownWait = nil
            try Task.checkCancellation()
            countdown = max(0, countdown - 1)
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
        guard state == .setup || state == .idle else { return }
        pendingTask?.cancel()
        if let data = try? Data(contentsOf: url.deletingLastPathComponent().appendingPathComponent("options.json")),
           let recoveredOptions = try? JSONDecoder()
           .decode(ScreenRecordingOptions.self, from: data) {
            options = recoveredOptions
        }
        if let kind = try? String(
            contentsOf: url.deletingLastPathComponent().appendingPathComponent("source-kind.txt"),
            encoding: .utf8
        ),
            let value = ScreenRecordingSourceKind(rawValue: kind) {
            sourceKind = value
        }
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
        retirePreview()
        sourceURL = url
        previewAuthorized = true
        previewScope.setVisible(true)
        let token = generation
        let access = AskImagePresentationAccess(scope: previewScope, epoch: previewScope.epoch, authorize: { [weak self] in
            self?.previewAuthorized == true && self?.sourceURL == url && self?.generation == token
        })
        duration = 0; trimStart = 0; trimEnd = 0
        do {
            let duration = try await playback.prepare(url, access: access)
            try Task.checkCancellation()
            guard access.allows() else { throw CancellationError() }
            self.duration = duration; trimEnd = duration
        } catch {
            guard !Task.isCancelled, access.allows() else { throw CancellationError() }
            // A successful recording remains recoverable even if its preview cannot decode.
            self.error = L("recording.previewUnavailable")
        }
        if fileName.isEmpty {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
            fileName = L("recording.title") + " " + formatter.string(from: Date())
        }
        mediaTask?.cancel()
        if playback.isLoaded {
            let mediaJob = Task.detached(priority: .userInitiated) { try await ScreenRecordingPreviewMedia.load(url) }
            mediaTask = Task { [weak self] in
                do {
                    let result = try await withTaskCancellationHandler { try await mediaJob.value } onCancel: {
                        mediaJob.cancel()
                    }
                    guard let self, !Task.isCancelled, access.allows(), sourceURL == url else { return }
                    media = result
                } catch { /* The video remains editable even when a damaged audio track cannot be previewed. */ }
            }
        }
        state = .preview
        present(self)
    }

    func seek(_ seconds: Double) {
        guard state == .preview, previewAuthorized, seconds.isFinite, duration > 0 else { return }
        playback.seekPaused(to: min(duration, max(0, seconds)) / duration)
    }

    /// Visibility/account retirement never deletes the original finished recording.
    func retirePreview() {
        previewAuthorized = false; previewScope.invalidate(); playback.stop()
        mediaTask?.cancel(); media = ScreenRecordingPreviewMedia()
        if state == .exporting { pendingTask?.cancel() }
    }

    func revealOriginal() {
        guard previewAuthorized, let sourceURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([sourceURL])
    }

    /// Explicitly reload presentation only; never recapture or repeat export.
    func reloadPreviewPlayback() {
        guard state == .preview, previewAuthorized, !playback.isBusy, let sourceURL else { return }
        let token = generation
        let access = AskImagePresentationAccess(scope: previewScope, epoch: previewScope.epoch, authorize: { [weak self] in
            self?.previewAuthorized == true && self?.generation == token && self?.sourceURL == sourceURL
        })
        playback.stop()
        pendingTask = Task { [weak self] in
            guard let self else { return }
            do {
                let value = try await playback.prepare(sourceURL, access: access)
                guard access.allows(), !Task.isCancelled, state == .preview else { return }
                if duration == 0 { duration = value; trimStart = 0; trimEnd = value }
                error = nil
            } catch {
                if access.allows(), !Task.isCancelled, state == .preview { self.error = L("recording.previewUnavailable") }
            }
        }
    }

    func export(directory: URL? = nil, destinationURL: URL? = nil, copy: Bool = false) {
        guard state == .preview, previewAuthorized, let sourceURL, let sessionDirectory else { return }
        let trim = ScreenRecordingTrim(start: trimStart, end: trimEnd)
        guard trimIsValid else { error = ScreenRecordingFailure.invalidRange.localizedDescription; return }
        pendingTask?.cancel()
        playback.stop()
        state = .exporting
        error = nil
        progress = 0
        let format = options.format
        let output = sessionDirectory.appendingPathComponent(UUID().uuidString + "." + format.rawValue)
        let destination = directory ?? outputDirectory ?? saveDirectory()
        let name = ScreenRecordingLayout.fileName(fileName)
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
                guard let owner = self, owner.generation == token, owner.previewAuthorized else { throw CancellationError() }
                let published = try await Task.detached { try files.publish(
                    output,
                    in: destination,
                    format: format,
                    name: name,
                    destinationURL: destinationURL
                ) }
                .value
                guard let self, generation == token, previewAuthorized, !Task.isCancelled else { throw CancellationError() }
                await completeExport(published, copy: copy, session: sessionDirectory, token: token)
            } catch {
                guard let self, generation == token else { return }
                try? FileManager.default.removeItem(at: output)
                self.error = error is CancellationError ? nil : error.localizedDescription
                state = .preview
            }
        }
    }

    private func completeExport(_ published: URL, copy: Bool, session: URL, token: Int) async {
        savedURL = published
        if copy {
            copyPublishedFile(published)
        }
        playback.stop()
        mediaTask?.cancel()
        await mediaTask?.value
        guard generation == token, previewAuthorized else { return }
        sourceURL = nil
        files.discard(session)
        sessionDirectory = nil
        state = .completed
    }

    func cancelExport() {
        if state == .exporting {
            pendingTask?.cancel()
        }
    }

    func cancel() {
        guard state != .idle else { return }
        generation += 1
        retirePreview()
        let previous = pendingTask
        let previousMedia = mediaTask
        let previousDevices = deviceTask
        previous?.cancel()
        countdownWait?.cancel()
        deviceTask?.cancel()
        mediaTask?.cancel()
        isLoadingSources = false
        stopMonitoring()
        overlay.dismiss()
        state = .stopping
        pendingTask = Task { [weak self] in
            await previous?.value
            await previousMedia?.value
            await previousDevices?.value
            guard let self else { return }
            await engine.cancel()
            playback.stop()
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
        mediaTask?.cancel()
        await mediaTask?.value
        retirePreview()
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
    func show(format: ScreenRecordingFormat? = nil, region: ScreenRecordingTarget? = nil) {
        guard !isBusy else { present(self); return }
        guard !isOtherCaptureActive() else { return }
        generation += 1
        state = .setup
        if let format {
            options.format = format
        }
        error = nil
        permissionFailure = nil
        savedURL = nil
        fileName = ""
        outputDirectory = defaults.string(forKey: "screenshot.recording.directory").map { URL(
            fileURLWithPath: $0,
            isDirectory: true
        ) }
        media = ScreenRecordingPreviewMedia()
        recovered = files.recoverableSources()
        if let region {
            sourceKind = .region
            choices = [ScreenRecordingChoice(
                id: "region",
                title: L("recording.region"),
                target: region,
                frame: {
                    if case let .region(_, rect) = region {
                        return rect
                    }; return .zero
                }(),
                scale: {
                    if case let .region(id, _) = region {
                        let width = CGDisplayBounds(id).width
                        guard width > 0 else { return 1 }
                        return CGFloat(CGDisplayCopyDisplayMode(id)?.pixelWidth ?? Int(width)) / width
                    }; return 1
                }()
            )]
            selectedID = "region"
        } else {
            sourceKind = ScreenRecordingSourceKind(rawValue: defaults
                .string(forKey: "screenshot.recording.sourceKind") ?? "region") ?? .region
            choices = []; selectedID = ""
        }
        present(self)
        reloadChoices()
    }

    func reloadChoices() {
        guard state == .setup else { return }
        pendingTask?.cancel()
        isLoadingSources = false
        guard permission.isGranted else {
            permission.requestOnce()
            permissionFailure = .permission
            error = L("recording.error.permission")
            return
        }
        if permissionFailure == .permission || permissionFailure == nil {
            error = nil; permissionFailure = nil
        }
        isLoadingSources = true
        let token = generation
        pendingTask = Task { [weak self, loadChoices] in
            defer {
                if let self, self.generation == token, !Task.isCancelled {
                    self.isLoadingSources = false
                }
            }
            do {
                let values = try await loadChoices()
                try Task.checkCancellation()
                guard let self, generation == token, state == .setup else { return }
                choices = choices.filter { $0.id == "region" } + values
                if !choices.contains(where: { $0.id == self.selectedID }) {
                    selectedID = sourceKind != .window && visibleSources
                        .count == 1 ? (visibleSources.first?.id ?? "") : ""
                }
            } catch {
                guard let self, generation == token, !(error is CancellationError) else { return }
                self.error = error.localizedDescription
            }
        }
    }

    func openPermissions() {
        if let url = devicePermissionURL {
            NSWorkspace.shared.open(url)
        } else {
            permission.openSystemSettings()
        }
    }

    var destinationDirectory: URL {
        outputDirectory ?? saveDirectory()
    }

    func selectSourceKind(_ kind: ScreenRecordingSourceKind) {
        guard state == .setup else { return }
        sourceKind = kind
        selectedID = kind == .window ? "" :
            (choices.filter { $0.target.kind == kind }
                .count == 1 ? (choices.first(where: { $0.target.kind == kind })?.id ?? "") : "")
    }

    func selectRegion() {
        guard state == .setup, permission.isGranted else { return }
        pendingTask?.cancel()
        isLoadingSources = false
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
                        choices.insert(ScreenRecordingChoice(
                            id: "region",
                            title: L("recording.region"),
                            target: .region(displayID: displayID, rect: rect),
                            frame: rect,
                            scale: 2
                        ), at: 0)
                        selectedID = "region"
                        sourceKind = .region
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

extension ScreenRecordingCoordinator {
    func select(_ choice: ScreenRecordingChoice) {
        guard state == .setup else { return }
        if choice.target.kind == .region {
            choices.removeAll { $0.id == "region" }
        }
        if !choices.contains(where: { $0.id == choice.id }) {
            choices.insert(choice, at: 0)
        }
        selectedID = choice.id
        sourceKind = choice.target.kind
    }

    func skipCountdown() {
        guard state == .countdown else { return }
        countdown = 0
        countdownWait?.cancel()
    }

    func returnToSelection() {
        guard state == .countdown else { return }
        pendingTask?.cancel()
        countdownWait?.cancel()
    }

    func restart() {
        guard state == .recording || state == .paused else { return }
        stopMonitoring()
        state = .stopping
        let token = generation
        pendingTask = Task { [weak self] in
            guard let self else { return }
            await engine.cancel()
            guard !Task.isCancelled, generation == token else { return }
            if let sessionDirectory {
                files.discard(sessionDirectory)
            }
            sessionDirectory = nil
            showBorder(nil)
            state = .setup
            start()
        }
    }

    func reportDevicePermissionFailure(_ type: AVMediaType) {
        guard state == .setup else { return }
        let failure: ScreenRecordingFailure = type == .audio ? .microphonePermission : .cameraPermission
        guard permissionFailure != failure else { return }
        permissionFailure = failure
        error = failure.localizedDescription
    }

    func setDevice(_ type: AVMediaType, enabled: Bool) {
        guard state == .setup else { return }
        if type == .video {
            options.camera = enabled
        } else {
            options.microphone = enabled
        }
        deviceTask?.cancel()
        if !enabled {
            if (type == .audio && permissionFailure == .microphonePermission) ||
                (type == .video && permissionFailure == .cameraPermission) {
                permissionFailure = nil; error = nil
            }
            return
        }
        let requested = options
        deviceTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await authorizeDevices(requested)
                try Task.checkCancellation()
                permissionFailure = nil
                error = nil
            } catch {
                guard !Task.isCancelled else { return }
                permissionFailure = error as? ScreenRecordingFailure
                self.error = error.localizedDescription
            }
        }
    }

    func togglePlayback() {
        guard state == .preview, previewAuthorized, trimIsValid else { return }
        if playback.isPlaying { playback.toggle() }
        else { playback.play(range: .init(start: trimStart, end: trimEnd)) }
    }

    func keepFirstGIFSegment() {
        guard state == .preview else { return }
        trimEnd = min(duration, trimStart + 30)
    }

    func finishSavedPresentation() {
        guard state == .completed else { return }
        state = .idle
        dismiss()
    }

    func findRecoverableSources() -> [URL] {
        files.recoverableSources()
    }

    func discardRecovered(_ url: URL) {
        files.discard(url.deletingLastPathComponent())
        recovered.removeAll { $0 == url }
    }

    static func copyFile(_ url: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([url as NSURL])
    }
}
