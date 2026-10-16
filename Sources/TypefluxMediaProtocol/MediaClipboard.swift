import Foundation

/// Fixed clipboard contracts, independent of the shorter file-preview waveform.
public struct MediaClipboardOptions: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable { case pdf, duration, waveform }
    public static let scanSeconds: Double = 600
    public static let sampleRate: Double = 8000
    public static let buckets = 180
    public static let pcmBytes = 24 * 1024 * 1024
    public var kind: Kind
    public var container: MediaAVContainer?
    public init(kind: Kind, container: MediaAVContainer? = nil) { self.kind = kind; self.container = container }
    public func validate() throws {
        guard kind != .pdf || container == nil else { throw MediaFailure.invalidProtocol }
    }
}

public struct MediaClipboardResult: Codable, Sendable, Equatable {
    public var duration: Double?
    public var pages: Int?
    public var waveform: [Float]?
    public init(duration: Double? = nil, pages: Int? = nil, waveform: [Float]? = nil) {
        self.duration = duration; self.pages = pages; self.waveform = waveform
    }
    public func validate(for options: MediaClipboardOptions) throws {
        try options.validate()
        if options.kind == .pdf {
            guard duration == nil, waveform == nil, let pages, pages > 0, pages <= 1_000_000 else { throw MediaFailure.invalidProtocol }
        } else {
            guard pages == nil, let duration, duration.isFinite, duration > 0,
                  duration <= MediaAVLimits.maximumDuration else { throw MediaFailure.invalidProtocol }
            if options.kind == .waveform {
                guard let waveform, waveform.count == MediaClipboardOptions.buckets,
                      waveform.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 }) else { throw MediaFailure.invalidProtocol }
            } else if waveform != nil { throw MediaFailure.invalidProtocol }
        }
    }
}
