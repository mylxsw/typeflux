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
    /// Playback speed applied to the kept range; the output lasts `(end - start) / rate`.
    public let rate: Double
    /// One volume per source audio track, in asset order. Zero leaves the track out entirely;
    /// `nil` keeps every track at full volume.
    public let volumes: [Double]?
    public static let rates: ClosedRange<Double> = 0.5 ... 4
    public static let maximumTracks = 8
    public init(id: UUID = UUID(), format: Format, start: Double, end: Double, rate: Double = 1,
                volumes: [Double]? = nil) {
        version = 1; self.id = id; self.format = format; self.start = start; self.end = end
        self.rate = rate; self.volumes = volumes
    }
    private enum CodingKeys: String, CodingKey { case version, id, format, start, end, rate, volumes }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        id = try values.decode(UUID.self, forKey: .id)
        format = try values.decode(Format.self, forKey: .format)
        start = try values.decode(Double.self, forKey: .start)
        end = try values.decode(Double.self, forKey: .end)
        rate = try values.decodeIfPresent(Double.self, forKey: .rate) ?? 1
        volumes = try values.decodeIfPresent([Double].self, forKey: .volumes)
    }
    public static func validVolumes(_ values: [Double]) -> Bool {
        values.count <= maximumTracks && values.allSatisfy { $0.isFinite && (0 ... 1).contains($0) }
    }
    public var outputName: String { "output." + format.rawValue }
    public var outputLimit: Int { format == .gif ? 50_000_000 : Self.inputBytes }
    /// Seconds of exported media after the speed change.
    public var outputDuration: Double { (end - start) / rate }
    public func validate() throws {
        guard version == 1, start.isFinite, end.isFinite, start >= 0, end > start, end <= 86_400.01,
              rate.isFinite, Self.rates.contains(rate),
              volumes.map(Self.validVolumes) ?? true,
              format != .gif || outputDuration <= 30.01 else { throw MediaFailure.invalidProtocol }
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
