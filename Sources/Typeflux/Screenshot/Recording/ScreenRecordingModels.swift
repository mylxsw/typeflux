import CoreGraphics
import CoreMedia
import Foundation

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
}

struct ScreenRecordingChoice: Identifiable, Equatable {
    var id: String
    var title: String
    var target: ScreenRecordingTarget
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

struct ScreenRecordingTrim: Equatable {
    var start: Double
    var end: Double
    func validated(duration: Double, format: ScreenRecordingFormat) throws -> CMTimeRange {
        guard start.isFinite, end.isFinite, duration.isFinite, start >= 0,
              end > start, end <= duration + 0.01,
              format != .gif || end - start <= 30.01 else { throw ScreenRecordingFailure.invalidRange }
        return CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                           duration: CMTime(seconds: min(end, duration) - start, preferredTimescale: 600))
    }
}
