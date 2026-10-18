import CoreGraphics
import CoreMedia
import Foundation
import TypefluxMediaProtocol

enum ScreenRecordingFormat: String, Codable, CaseIterable, Sendable {
    case mp4, gif
}

struct ScreenRecordingOptions: Codable, Equatable, Sendable {
    enum CameraCorner: String, Codable, CaseIterable { case topLeft, topRight, bottomLeft, bottomRight }
    var format: ScreenRecordingFormat = .mp4
    var framesPerSecond = 30
    var maxDimension = 1920
    var showsCursor = true
    var systemAudio = false
    var microphone = false
    var camera = false
    var cameraCorner: CameraCorner = .bottomRight
    var cameraFraction = 0.22
    var countdown = 3

    var capturesAudio: Bool {
        format == .mp4
    }

    var captureFPS: Int {
        format == .gif ? 10 : min(60, max(10, framesPerSecond))
    }

    var dimension: Int {
        format == .gif ? min(960, max(320, maxDimension)) : min(3840, max(320, maxDimension))
    }

    var durationLimit: Double? {
        format == .gif ? 30 : nil
    }

    static func load(from defaults: UserDefaults) -> Self {
        guard let data = defaults.data(forKey: "screenshot.recording.options"),
              let options = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return options
    }

    func save(to defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: "screenshot.recording.options")
        }
    }
}

enum ScreenRecordingTarget: Equatable {
    case display(CGDirectDisplayID)
    case region(displayID: CGDirectDisplayID, rect: CGRect)
    case window(CGWindowID)

    var kind: ScreenRecordingSourceKind {
        switch self {
        case .display: .display
        case .region: .region
        case .window: .window
        }
    }
}

enum ScreenRecordingSourceKind: String, CaseIterable {
    case region, display, window
    var symbol: String {
        switch self {
        case .region: "viewfinder"
        case .display: "display"
        case .window: "macwindow"
        }
    }
}

struct ScreenRecordingChoice: Identifiable, Equatable {
    var id: String
    var title: String
    var target: ScreenRecordingTarget
    var frame: CGRect = .zero
    var scale: CGFloat = 1
}

enum ScreenRecordingFailure: String, Error, LocalizedError {
    case permission, microphonePermission, cameraPermission, unavailable, noFrames, encoding, invalidRange, interrupted
    var errorDescription: String? {
        L("recording.error." + rawValue)
    }
}

/// All coordinates are Quartz points until the final, even-sized pixel output.
enum ScreenRecordingGeometry {
    static func sourceRect(_ rect: CGRect, on display: CGRect) throws -> CGRect {
        guard !rect.isInfinite, !rect.isNull else { throw ScreenRecordingFailure.unavailable }
        let clipped = rect.intersection(display)
        guard !clipped.isNull, clipped.width >= 2, clipped.height >= 2 else {
            throw ScreenRecordingFailure.unavailable
        }
        return clipped.offsetBy(dx: -display.minX, dy: -display.minY)
    }

    static func outputSize(points: CGSize, scale: CGFloat, maxDimension: Int) throws -> CGSize {
        guard points.width.isFinite, points.height.isFinite, scale.isFinite,
              points.width >= 2, points.height >= 2, scale > 0, maxDimension >= 2 else {
            throw ScreenRecordingFailure.unavailable
        }
        let width = points.width * scale, height = points.height * scale
        let factor = min(1, CGFloat(maxDimension) / max(width, height))
        return CGSize(width: max(2, floor(width * factor / 2) * 2),
                      height: max(2, floor(height * factor / 2) * 2))
    }

    static func cameraRect(in size: CGSize, fraction: Double,
                           corner: ScreenRecordingOptions.CameraCorner) -> CGRect {
        let width = size.width * min(0.4, max(0.12, fraction))
        let height = min(size.height * 0.4, width * 0.75)
        let margin = min(size.width, size.height) * 0.025
        let right = corner == .topRight || corner == .bottomRight
        let top = corner == .topRight || corner == .topLeft
        // Core Image has a bottom-left origin.
        return CGRect(x: right ? size.width - width - margin : margin,
                      y: top ? size.height - height - margin : margin, width: width, height: height)
    }
}

/// Uses host-clock seconds for every source. Pause boundaries also reject callbacks
/// queued before resume, instead of shifting those samples into the active segment.
struct ScreenRecordingTimeline {
    private(set) var origin: Double?
    private(set) var pauses: [ClosedRange<Double>] = []
    private(set) var pausedAt: Double?

    mutating func start(at time: Double) {
        if origin == nil, time.isFinite {
            origin = time
        }
    }

    mutating func pause(at time: Double) {
        guard pausedAt == nil, time.isFinite else { return }
        pausedAt = time
    }

    mutating func resume(at time: Double) {
        guard let start = pausedAt, time >= start, time.isFinite else { return }
        pauses.append(start ... time)
        pausedAt = nil
    }

    func position(at time: Double) -> Double? {
        guard let origin, time.isFinite, time >= origin else { return nil }
        let end = min(time, pausedAt ?? time)
        let removed = pauses.reduce(0.0) { total, range in
            total + max(0, min(end, range.upperBound) - max(origin, range.lowerBound))
        }
        return max(0, end - origin - removed)
    }

    func sampleTime(at time: Double) -> Double? {
        guard !(pausedAt.map { time >= $0 } ?? false),
              !pauses.contains(where: { $0.contains(time) }) else { return nil }
        return position(at: time)
    }
}

/// The kept source range plus how it is played back: speed, and one volume per source audio track.
struct ScreenRecordingTrim: Equatable {
    var start: Double
    var end: Double
    var rate = 1.0
    /// Zero leaves a track out of the export; `nil` keeps every track at full volume.
    var volumes: [Double]?
    func validated(duration: Double, format: ScreenRecordingFormat) throws -> CMTimeRange {
        guard start.isFinite, end.isFinite, duration.isFinite, start >= 0,
              end > start, end <= duration + 0.01, rate.isFinite, rate > 0,
              format != .gif || (end - start) / rate <= ScreenRecordingEdit.gifLimit + 0.01
        else { throw ScreenRecordingFailure.invalidRange }
        return CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                           duration: CMTime(seconds: min(end, duration) - start, preferredTimescale: 600))
    }
}

/// One recorded audio source as shown in the editor, addressed by its position in the source file.
struct ScreenRecordingAudioTrack: Equatable, Identifiable {
    enum Kind: String { case systemAudio, microphone, other }
    let id: Int
    var kind: Kind
    var waveform: [Float]
    var included = true
    var volume = 1.0

    var title: String {
        switch kind {
        case .systemAudio: L("recording.systemAudio")
        case .microphone: L("recording.microphone")
        case .other: L("recording.trackNumber", id + 1)
        }
    }

    /// The writer adds system audio before the microphone, each only when it was enabled.
    static func tracks(waveforms: [[Float]], options: ScreenRecordingOptions) -> [Self] {
        let kinds: [Kind] = [(options.systemAudio, Kind.systemAudio), (options.microphone, .microphone)]
            .filter { $0.0 && options.capturesAudio }.map(\.1)
        return waveforms.enumerated().map { index, waveform in
            Self(id: index, kind: kinds.count == waveforms.count ? kinds[index] : .other, waveform: waveform)
        }
    }
}

/// Speed and audio choices that apply to both the preview and the exported file.
struct ScreenRecordingEdit: Equatable {
    static let rates: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 2, 3, 4]
    static let gifLimit = 30.0
    var rate = 1.0
    var tracks: [ScreenRecordingAudioTrack] = []

    var volumes: [Double]? {
        tracks.isEmpty ? nil : tracks.map { $0.included ? min(1, max(0, $0.volume)) : 0 }
    }

    var includedTracks: [ScreenRecordingAudioTrack] {
        tracks.filter(\.included)
    }

    var isDefault: Bool {
        rate == 1 && tracks.allSatisfy { $0.included && $0.volume == 1 }
    }

    var playbackMix: MediaPlaybackMix {
        MediaPlaybackMix(rate: rate, volumes: volumes ?? [])
    }

    func outputDuration(_ selection: Double) -> Double {
        max(0, selection) / rate
    }

    /// Last source second a GIF starting at `start` can include at this speed.
    func gifSourceEnd(from start: Double) -> Double {
        start + Self.gifLimit * rate
    }

    /// The slowest faster preset that fits `selection` into a GIF, if any.
    func fittingGIFRate(selection: Double) -> Double? {
        Self.rates.first { $0 > rate && selection / $0 <= Self.gifLimit + 0.01 }
    }

    static func rateTitle(_ rate: Double) -> String {
        (rate == rate.rounded() ? String(Int(rate)) : String(rate)) + "×"
    }
}
