import Foundation

/// A playback session has one ordered command and one reply in flight, never a replay queue.
public struct MediaPlaybackMessage: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case load, play, pause, seek, status, reply }
    public static let maximumBytes = 2048
    public static let maximumSequence = 100_000
    public static let lifetime: Double = 14_400
    public var version = 1
    public var id: UUID
    public var sequence: Int
    public var kind: Kind
    public var fraction: Double?
    public var state: MediaPlaybackState?
    public init(id: UUID, sequence: Int, kind: Kind, fraction: Double? = nil, state: MediaPlaybackState? = nil) {
        self.id = id; self.sequence = sequence; self.kind = kind; self.fraction = fraction; self.state = state
    }
    public func validate() throws {
        guard version == 1, (1...Self.maximumSequence).contains(sequence) else { throw MediaFailure.invalidProtocol }
        if kind == .reply { guard fraction == nil, let state else { throw MediaFailure.invalidProtocol }; try state.validate() }
        else {
            guard state == nil else { throw MediaFailure.invalidProtocol }
            if kind == .seek {
                guard let fraction, fraction.isFinite, (0...1).contains(fraction) else { throw MediaFailure.invalidProtocol }
            } else if fraction != nil { throw MediaFailure.invalidProtocol }
        }
    }
}

public struct MediaPlaybackState: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable { case paused, playing, ended }
    public var phase: Phase
    public var elapsed: Double
    public var duration: Double
    public init(phase: Phase, elapsed: Double, duration: Double) {
        self.phase = phase; self.elapsed = elapsed; self.duration = duration
    }
    public func validate() throws {
        guard duration.isFinite, duration > 0, duration <= 86_400,
              elapsed.isFinite, elapsed >= 0, elapsed <= duration,
              phase != .ended || elapsed == duration else { throw MediaFailure.invalidProtocol }
    }
}
