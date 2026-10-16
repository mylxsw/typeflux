import Foundation

/// A playback session has one ordered command and one reply in flight, never a replay queue.
public struct MediaPlaybackMessage: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case load, loadVideo, play, pause, seek, volume, playRange, seekPaused, status, reply }
    public static let maximumBytes = 2048
    public static let maximumSequence = 100_000
    public static let lifetime: Double = 14_400
    public var version = 1
    public var id: UUID
    public var sequence: Int
    public var kind: Kind
    public var fraction: Double?
    public var state: MediaPlaybackState?
    public var range: MediaPlaybackRange?
    public init(id: UUID, sequence: Int, kind: Kind, fraction: Double? = nil, state: MediaPlaybackState? = nil, range: MediaPlaybackRange? = nil) {
        self.id = id; self.sequence = sequence; self.kind = kind; self.fraction = fraction; self.state = state; self.range = range
    }
    public func validate() throws {
        guard version == 1, (1...Self.maximumSequence).contains(sequence) else { throw MediaFailure.invalidProtocol }
        if kind == .playRange { guard let range else { throw MediaFailure.invalidProtocol }; try range.validate() }
        else if range != nil { throw MediaFailure.invalidProtocol }
        if kind == .reply { guard fraction == nil, let state else { throw MediaFailure.invalidProtocol }; try state.validate() }
        else {
            guard state == nil else { throw MediaFailure.invalidProtocol }
            if kind == .seek || kind == .seekPaused || kind == .volume {
                guard let fraction, fraction.isFinite, (0...1).contains(fraction) else { throw MediaFailure.invalidProtocol }
            } else if fraction != nil { throw MediaFailure.invalidProtocol }
        }
    }
}

public struct MediaPlaybackRange: Codable, Equatable, Sendable {
    public let start: Double, end: Double
    public init(start: Double, end: Double) { self.start = start; self.end = end }
    public func validate() throws {
        guard start.isFinite, end.isFinite, start >= 0, end > start, end <= 86_400 else { throw MediaFailure.invalidProtocol }
    }
}

public struct MediaPlaybackState: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable { case paused, playing, ended }
    public var phase: Phase
    public var elapsed: Double
    public var duration: Double
    public var video = false
    public var volume: Double = 1
    public var frame: MediaPlaybackFrame?
    /// Local transport storage only. Pixel bytes never enter the JSON control envelope.
    public var pixels: Data?
    private enum CodingKeys: String, CodingKey { case phase, elapsed, duration, video, volume, frame }
    public init(phase: Phase, elapsed: Double, duration: Double) {
        self.phase = phase; self.elapsed = elapsed; self.duration = duration
    }
    public func validate() throws {
        guard duration.isFinite, duration > 0, duration <= 86_400,
              elapsed.isFinite, elapsed >= 0, elapsed <= duration,
              phase != .ended || elapsed == duration,
              volume.isFinite, (0...1).contains(volume), video || frame == nil else { throw MediaFailure.invalidProtocol }
        if let frame { try frame.validate(duration: duration) }
    }
}

/// One coalesced RGBA frame, paired with the enclosing session/command sequence.
public struct MediaPlaybackFrame: Codable, Equatable, Sendable {
    public static let maximumEdge = 1280
    public static let maximumPixels = 1024 * 1024
    public static let maximumBytes = maximumPixels * 4
    public var width: Int
    public var height: Int
    public var stride: Int
    public var bytes: Int
    public var time: Double
    public init(width: Int, height: Int, time: Double) {
        self.width = width; self.height = height; self.time = time
        stride = width > 0 && width <= Self.maximumEdge ? width * 4 : 0
        bytes = height > 0 && height <= Self.maximumEdge ? stride * height : 0
    }
    public func validate(duration: Double) throws {
        guard width > 0, height > 0, width <= Self.maximumEdge, height <= Self.maximumEdge,
              width * height <= Self.maximumPixels, stride == width * 4, bytes == stride * height,
              time.isFinite, time >= 0, time <= duration else { throw MediaFailure.invalidProtocol }
    }
}
