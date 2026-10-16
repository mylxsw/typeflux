import AVFoundation
import Foundation
import TypefluxMediaProtocol

@MainActor public protocol MediaPlaybackEngine: AnyObject {
    func load(_ url: URL) async throws
    func perform(_ command: MediaPlaybackMessage) async throws -> MediaPlaybackState
    func stop()
}

/// Only this child owns AVPlayer. No periodic observer or unbounded event stream is needed:
/// the host requests one bounded snapshot, with an acknowledgement for each explicit command.
@MainActor public final class MediaPlaybackServer {
    private let engine: any MediaPlaybackEngine
    private let watchdog: @MainActor () -> Void
    private let lifetime: Duration
    public init(engine: any MediaPlaybackEngine, lifetime: Duration = .seconds(MediaPlaybackMessage.lifetime),
                watchdog: @escaping @MainActor () -> Void = {}) {
        self.engine = engine; self.lifetime = lifetime; self.watchdog = watchdog
    }
    public func serve(socket: MediaPlaybackSocket, input: URL) async {
        defer { engine.stop(); socket.stop() }
        var session: UUID?, sequence = 1
        let expires = ContinuousClock.now.advanced(by: lifetime)
        do {
            while !socket.isStopped, ContinuousClock.now < expires {
                watchdog()
                let request = try await Task.detached { try socket.receive(deadline: .now.advanced(by: .seconds(10))) }.value
                try request.validate()
                watchdog()
                guard ContinuousClock.now < expires, request.sequence == sequence, request.kind != .reply,
                      session == nil ? request.kind == .load : (request.id == session && request.kind != .load)
                else { throw MediaFailure.invalidProtocol }
                if session == nil { session = request.id; try await engine.load(input) }
                let state = try await engine.perform(request)
                try state.validate()
                let reply = MediaPlaybackMessage(id: request.id, sequence: sequence, kind: .reply, state: state)
                try await Task.detached { try socket.send(reply, deadline: .now.advanced(by: .seconds(2))) }.value
                sequence += 1
            }
        } catch { /* Never log private file paths, native diagnostics or media. */ }
    }
}

@MainActor public final class MediaAVPlaybackEngine: MediaPlaybackEngine {
    private var player: AVPlayer?
    private var duration: Double = 0
    private var ended = false
    private var endObserver: NSObjectProtocol?
    public init() {}
    public func load(_ url: URL) async throws {
        guard player == nil else { throw MediaFailure.invalidProtocol }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let bytes = values.fileSize, bytes > 0, bytes <= 512 * 1024 * 1024 else { throw MediaFailure.tooLarge }
        // A private single-file lease must never resolve another local file or remote media.
        let asset = AVURLAsset(url: url, options: [AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue])
        let seconds = try await asset.load(.duration).seconds
        guard seconds.isFinite, seconds > 0, seconds <= 86_400,
              !(try await asset.loadTracks(withMediaType: .audio)).isEmpty,
              (try await asset.loadTracks(withMediaType: .video)).isEmpty else { throw MediaFailure.unreadable }
        duration = seconds
        let item = AVPlayerItem(asset: asset)
        let value = AVPlayer(playerItem: item)
        // Loading is silent. Status failures are checked before every acknowledged control.
        player = value
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.ended = true }
        }
        while item.status == .unknown { try await Task.sleep(for: .milliseconds(10)) }
        guard item.status == .readyToPlay else { throw MediaFailure.unreadable }
    }
    public func perform(_ command: MediaPlaybackMessage) async throws -> MediaPlaybackState {
        guard let player, player.currentItem?.status == .readyToPlay, player.error == nil else { throw MediaFailure.unreadable }
        switch command.kind {
        case .play:
            if ended || player.currentTime().seconds >= duration {
                guard await player.seek(to: .zero) else { throw MediaFailure.unavailable }
                ended = false
            }
            player.play()
        case .pause: player.pause()
        case .seek:
            guard let fraction = command.fraction else { throw MediaFailure.invalidProtocol }
            guard await player.seek(to: CMTime(seconds: fraction * duration, preferredTimescale: 600)) else { throw MediaFailure.unavailable }
            ended = fraction == 1
        case .load, .status: break
        case .reply: throw MediaFailure.invalidProtocol
        }
        let time = player.currentTime().seconds
        guard time.isFinite else { throw MediaFailure.unreadable }
        let elapsed = ended ? duration : min(duration, max(0, time))
        return .init(phase: elapsed >= duration ? .ended : player.rate == 0 ? .paused : .playing,
                     elapsed: elapsed, duration: duration)
    }
    public func stop() {
        player?.pause(); player?.replaceCurrentItem(with: nil); player = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil; ended = false
    }
}
