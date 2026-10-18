import Foundation

/// One bounded batch for an entire recording, never a request per timeline cell.
public struct MediaRecordingTimeline: Codable, Sendable {
    public static let inputBytes = 8 * 1024 * 1024 * 1024
    public static let pixelBytes = 10 * 200 * 120 * 4
    public static let pcmBytes = 512 * 1024 * 1024
    public enum Audio: String, Codable, Sendable { case absent, available, unavailable }
    public var duration: Double
    public var width: Double
    public var height: Double
    public var fps: Float
    public var rasters: [MediaRaster]
    public var audio: Audio
    public var waveform: [Float]
    /// Per source audio track, in asset order, so the editor can include or mute each one.
    public var tracks: [[Float]]
    public init(duration: Double, width: Double, height: Double, fps: Float,
                rasters: [MediaRaster], audio: Audio, waveform: [Float] = [], tracks: [[Float]] = []) {
        self.duration = duration; self.width = width; self.height = height; self.fps = fps
        self.rasters = rasters; self.audio = audio; self.waveform = waveform; self.tracks = tracks
    }
    public func validate() throws {
        guard duration.isFinite, duration > 0, duration <= 86_400,
              width.isFinite, height.isFinite, width > 0, height > 0,
              width <= 8192, height <= 8192, width * height <= 16_777_216,
              fps.isFinite, fps >= 0, fps <= 240, rasters.count == 10,
              waveform.count == (audio == .available ? 160 : 0),
              waveform.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 }),
              audio == .available || tracks.isEmpty, tracks.count <= MediaRecordingExport.maximumTracks,
              tracks.allSatisfy({ $0.count == 160 && $0.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 } })
        else { throw MediaFailure.invalidProtocol }
        for raster in rasters {
            try raster.validate(for: .init(width: 200, height: 120))
            guard raster.page == nil else { throw MediaFailure.invalidProtocol }
        }
    }
}
