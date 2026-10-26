import AppKit
import AVFoundation
import ScreenCaptureKit

struct ScreenRecordingCapturePlan {
    let filter: SCContentFilter
    let configuration: SCStreamConfiguration
    let size: CGSize

    @MainActor
    static func make(target: ScreenRecordingTarget, options: ScreenRecordingOptions) async throws -> Self {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let filter: SCContentFilter
        let points: CGSize
        let scale: CGFloat
        var sourceRect: CGRect?
        switch target {
        case let .window(id):
            guard let window = content.windows.first(where: { $0.windowID == id && $0.isOnScreen }) else {
                throw ScreenRecordingFailure.unavailable
            }
            filter = SCContentFilter(desktopIndependentWindow: window)
            points = window.frame.size
            scale = NSScreen.screens.first(where: {
                ScreenCaptureGeometry.flipped($0.frame, primaryDisplayHeight: NSScreen.screens.first?.frame.height ?? 0)
                    .intersects(window.frame)
            })?.backingScaleFactor ?? 2
        case .display, .region:
            let id: CGDirectDisplayID
            if case let .display(displayID) = target {
                id = displayID
            } else if case let .region(displayID, _) = target {
                id = displayID
            } else {
                throw ScreenRecordingFailure.unavailable
            }
            guard let display = content.displays.first(where: { $0.displayID == id }) else {
                throw ScreenRecordingFailure.unavailable
            }
            let controls = Set(ScreenshotCaptureWindowPolicy.excludedWindowIDs())
            filter = SCContentFilter(
                display: display,
                excludingWindows: content.windows.filter { controls.contains($0.windowID) }
            )
            let frame = CGDisplayBounds(id)
            if case let .region(_, rect) = target {
                let local = try ScreenRecordingGeometry.sourceRect(rect, on: frame)
                sourceRect = local
                points = local.size
            } else {
                points = frame.size
            }
            scale = CGFloat(nativePixelWidth(id)) / max(1, frame.width)
        }
        let size = try ScreenRecordingGeometry.outputSize(points: points, scale: max(1, scale),
                                                          maxDimension: options.dimension)
        return Self(
            filter: filter,
            configuration: configuration(size: size, sourceRect: sourceRect, options: options),
            size: size
        )
    }

    static func configuration(size: CGSize, sourceRect: CGRect?,
                              options: ScreenRecordingOptions) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.width = Int(size.width)
        config.height = Int(size.height)
        if let sourceRect {
            config.sourceRect = sourceRect
        }
        config.scalesToFit = true
        if #available(macOS 14.0, *) {
            config.preservesAspectRatio = true
        }
        config.showsCursor = options.showsCursor
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(options.captureFPS))
        config.queueDepth = 4
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        config.capturesAudio = options.systemAudio && options.capturesAudio
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48000
        config.channelCount = 2
        return config
    }

    private static func nativePixelWidth(_ id: CGDirectDisplayID) -> Int {
        CGDisplayCopyDisplayMode(id)?.pixelWidth ?? Int(CGDisplayBounds(id).width)
    }
}

/// ScreenCaptureKit and AVCaptureSession both deliver in a host-clock timebase.
/// Devices are started off the main thread; delegates only submit bounded samples.
final class ScreenRecordingCapture: NSObject, SCStreamOutput, SCStreamDelegate,
    AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let writer: ScreenRecordingWriter
    private let options: ScreenRecordingOptions
    let session = AVCaptureSession()
    private let meter = ScreenRecordingAudioMeter()
    var audioLevel: Float {
        meter.level
    }

    private let deviceQueue = DispatchQueue(label: "Typeflux.Recording.devices", qos: .userInitiated)
    private let sampleQueue = DispatchQueue(label: "Typeflux.Recording.samples", qos: .userInitiated)
    private var stream: SCStream?
    private var observers: [NSObjectProtocol] = []
    private let onError: @Sendable (Error) -> Void

    init(writer: ScreenRecordingWriter, options: ScreenRecordingOptions, onError: @escaping @Sendable (Error) -> Void) {
        self.writer = writer
        self.options = options
        self.onError = onError
    }

    func start(plan: ScreenRecordingCapturePlan) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            deviceQueue.async { [self] in
                do {
                    session.beginConfiguration()
                    do { try configureDevices() } catch { session.commitConfiguration(); throw error }
                    session.commitConfiguration()
                    if !session.inputs.isEmpty {
                        session.startRunning()
                        guard session.isRunning else { throw ScreenRecordingFailure.unavailable }
                    }
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
        try Task.checkCancellation()
        for name in [AVCaptureSession.runtimeErrorNotification, AVCaptureSession.wasInterruptedNotification] {
            observers
                .append(NotificationCenter.default
                    .addObserver(forName: name, object: session, queue: nil) { [onError] _ in
                        onError(ScreenRecordingFailure.interrupted)
                    })
        }
        let stream = SCStream(filter: plan.filter, configuration: plan.configuration, delegate: self)
        self.stream = stream
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        if options.systemAudio, options.capturesAudio {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
        }
        try await stream.startCapture()
        try Task.checkCancellation()
    }

    private func configureDevices() throws {
        for (type, enabled) in [
            (AVMediaType.video, options.camera),
            (.audio, options.microphone && options.capturesAudio)
        ]
            where enabled {
            guard let device = AVCaptureDevice.default(for: type) else { throw ScreenRecordingFailure.unavailable }
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else { throw ScreenRecordingFailure.unavailable }
            session.addInput(input)
            let output: AVCaptureOutput
            if type == .video {
                let video = AVCaptureVideoDataOutput()
                video.alwaysDiscardsLateVideoFrames = true
                video.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                video.setSampleBufferDelegate(self, queue: sampleQueue)
                output = video
            } else {
                let audio = AVCaptureAudioDataOutput()
                audio.setSampleBufferDelegate(self, queue: sampleQueue)
                output = audio
            }
            guard session.canAddOutput(output) else { throw ScreenRecordingFailure.unavailable }
            session.addOutput(output)
        }
        if session.canSetSessionPreset(.medium) {
            session.sessionPreset = .medium
        }
    }

    func stop() async {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        let previous = stream
        stream = nil
        try? await previous?.stopCapture()
        await withCheckedContinuation { continuation in
            deviceQueue.async { [self] in
                if session.isRunning {
                    session.stopRunning()
                }
                continuation.resume()
            }
        }
        // Drain native callbacks before finalizing the writer.
        await withCheckedContinuation { continuation in sampleQueue.async { continuation.resume() } }
    }

    func stream(_: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        if type == .screen {
            guard let metadata = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]], let raw = metadata.first?[.status] as? Int,
                let status = SCFrameStatus(rawValue: raw) else { return }
            receiveScreenSample(sample, status: status)
            return
        }
        guard type == .audio else { return }
        writer.offer(sample, track: .systemAudio, hostTime: sample.presentationTimeStamp.seconds)
    }

    func receiveScreenSample(_ sample: CMSampleBuffer, status: SCFrameStatus) {
        if status == .stopped {
            onError(ScreenRecordingFailure.interrupted)
            return
        }
        // Suspended updates can resume; only complete frames contain writable video.
        guard status == .complete else { return }
        writer.offer(sample, track: .screen, hostTime: sample.presentationTimeStamp.seconds)
    }

    func stream(_: SCStream, didStopWithError error: Error) {
        onError(error)
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sample: CMSampleBuffer, from _: AVCaptureConnection) {
        receiveDeviceSample(sample, video: output is AVCaptureVideoDataOutput)
    }

    func receiveDeviceSample(_ sample: CMSampleBuffer, video: Bool) {
        if !video {
            meter.update(sample)
        }
        let stamp = session.synchronizationClock.map {
            CMSyncConvertTime(sample.presentationTimeStamp, from: $0, to: CMClockGetHostTimeClock())
        } ?? sample.presentationTimeStamp
        writer.offer(sample, track: video ? .camera : .microphone, hostTime: stamp.seconds)
    }
}

@MainActor
protocol ScreenRecordingEngine: AnyObject {
    var onError: (@MainActor (Error) -> Void)? { get set }
    var previewSession: AVCaptureSession? { get }
    var audioLevel: Float { get }
    func start(target: ScreenRecordingTarget, options: ScreenRecordingOptions, url: URL) async throws
    func setPaused(_ paused: Bool)
    func elapsed() async -> Double
    func stop() async throws -> URL
    func cancel() async
}

extension ScreenRecordingEngine {
    var previewSession: AVCaptureSession? {
        nil
    }

    var audioLevel: Float {
        0
    }
}

@MainActor
final class NativeScreenRecordingEngine: ScreenRecordingEngine {
    var onError: (@MainActor (Error) -> Void)?
    var previewSession: AVCaptureSession? {
        source?.session
    }

    var audioLevel: Float {
        source?.audioLevel ?? 0
    }

    private var source: ScreenRecordingCapture?
    private var writer: ScreenRecordingWriter?
    private var generation = 0
    static var hostTime: Double {
        CMClockGetTime(CMClockGetHostTimeClock()).seconds
    }

    func start(target: ScreenRecordingTarget, options: ScreenRecordingOptions, url: URL) async throws {
        generation += 1
        let token = generation
        let plan = try await ScreenRecordingCapturePlan.make(target: target, options: options)
        try Task.checkCancellation()
        let writer = try ScreenRecordingWriter(url: url, size: plan.size, options: options)
        self.writer = writer
        let handler: @Sendable (Error) -> Void = { [weak self] error in
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                self.onError?(error)
            }
        }
        writer.onFailure = handler
        let source = ScreenRecordingCapture(writer: writer, options: options, onError: handler)
        self.source = source
        do {
            try await source.start(plan: plan)
            try await writer.waitForFirstFrame()
        } catch { await cancel(); throw error }
    }

    func setPaused(_ paused: Bool) {
        writer?.setPaused(paused, at: Self.hostTime)
    }

    func elapsed() async -> Double {
        await writer?.elapsed(at: Self.hostTime) ?? 0
    }

    func stop() async throws -> URL {
        generation += 1
        let end = Self.hostTime
        await source?.stop()
        source = nil
        guard let writer else { throw ScreenRecordingFailure.noFrames }
        self.writer = nil
        return try await writer.finish(at: end)
    }

    func cancel() async {
        generation += 1
        await source?.stop()
        source = nil
        await writer?.cancel()
        writer = nil
    }
}
