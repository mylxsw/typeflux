import Foundation

/// A separate, bounded long-job stream. Extraction and playback contracts stay unchanged.
public struct MediaRecordingExport: Codable, Equatable, Sendable {
    public enum Format: String, Codable, Sendable { case mp4, gif }
    public static let inputBytes = 8 * 1024 * 1024 * 1024
    public static let streamBytes = 256 * 1024
    public let version: Int
    public let id: UUID
    public let format: Format
    public let start: Double
    public let end: Double
    public init(id: UUID = UUID(), format: Format, start: Double, end: Double) {
        version = 1; self.id = id; self.format = format; self.start = start; self.end = end
    }
    public var outputName: String { "output." + format.rawValue }
    public var outputLimit: Int { format == .gif ? 50_000_000 : Self.inputBytes }
    public func validate() throws {
        guard version == 1, start.isFinite, end.isFinite, start >= 0, end > start, end <= 86_400.01,
              format != .gif || end - start <= 30.01 else { throw MediaFailure.invalidProtocol }
    }
}

public struct MediaRecordingExportEvent: Codable, Sendable {
    public enum Kind: String, Codable, Sendable { case progress, completed, failed }
    public let version: Int
    public let id: UUID
    public let sequence: Int
    public let kind: Kind
    public let progress: Double
    public let bytes: Int?
    public init(id: UUID, sequence: Int, kind: Kind, progress: Double, bytes: Int? = nil) {
        version = 1; self.id = id; self.sequence = sequence; self.kind = kind; self.progress = progress; self.bytes = bytes
    }
    public func validate(for request: MediaRecordingExport, sequence: Int) throws {
        guard version == 1, id == request.id, self.sequence == sequence, (1...604).contains(sequence),
              progress.isFinite, (0...1).contains(progress),
              kind == .completed ? (progress == 1 && (bytes ?? 0) > 0 && bytes! <= request.outputLimit) : bytes == nil
        else { throw MediaFailure.invalidProtocol }
    }
}
