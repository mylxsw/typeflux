import AVFoundation
import Foundation

/// The disposable file worker has a synchronous, paced protocol. Load AVFoundation metadata
/// asynchronously on another executor before entering its synchronous reader/generator loop.
enum SemanticAssetMetadata {
    struct Audio {
        let track: AVAssetTrack
        let start: Double
        let end: Double
    }

    struct Video {
        let start: Double
        let end: Double
    }

    static func audio(_ asset: AVAsset) throws -> Audio? {
        try wait {
            guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return nil }
            let segments = try await track.load(.segments)
            let range = try await track.load(.timeRange)
            let start = segments.first(where: { !$0.isEmpty })?.timeMapping.target.start.seconds
                ?? range.start.seconds
            return Audio(track: track, start: start, end: range.end.seconds)
        }
    }

    static func video(_ asset: AVAsset) throws -> Video? {
        try wait {
            guard let track = try await asset.loadTracks(withMediaType: .video).first else { return nil }
            let range = try await track.load(.timeRange)
            let duration = try await asset.load(.duration)
            return Video(start: max(0, range.start.seconds),
                         end: min(duration.seconds, range.end.seconds))
        }
    }

    private static func wait<Value>(_ operation: @escaping @Sendable () async throws -> Value) throws -> Value {
        let completion = Completion<Value>()
        Task.detached {
            do { completion.resolve(.success(try await operation())) }
            catch { completion.resolve(.failure(error)) }
        }
        return try completion.wait()
    }

    private final class Completion<Value>: @unchecked Sendable {
        private let condition = NSCondition()
        private var result: Result<Value, Error>?

        func resolve(_ value: Result<Value, Error>) {
            condition.lock()
            result = value
            condition.signal()
            condition.unlock()
        }

        func wait() throws -> Value {
            condition.lock()
            while result == nil { condition.wait() }
            let value = result!
            condition.unlock()
            return try value.get()
        }
    }
}
