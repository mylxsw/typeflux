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
                guard ContinuousClock.now < expires, request.sequence == sequence, request.kind != .reply, request.kind != .failed,
                      session == nil ? [.load, .loadVideo].contains(request.kind) : (request.id == session && ![.load, .loadVideo].contains(request.kind))
                else { throw MediaFailure.invalidProtocol }
                let state: MediaPlaybackState
                do {
                    if session == nil { session = request.id; try await engine.load(input) }
                    state = try await engine.perform(request)
                } catch {
                    // A controlled native refusal is distinct from corrupt transport.
                    // It can follow partial control effects and must never be replayed.
                    let failure = MediaPlaybackMessage(id: request.id, sequence: sequence, kind: .failed)
                    try await Task.detached { try socket.send(failure, deadline: .now.advanced(by: .seconds(2))) }.value
                    return
                }
                try state.validate()
                guard state.frame?.bytes == state.pixels?.count else { throw MediaFailure.invalidProtocol }
                let reply = MediaPlaybackMessage(id: request.id, sequence: sequence, kind: .reply, state: state)
                try await Task.detached {
                    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
                    try socket.send(reply, deadline: deadline)
                    if let pixels = state.pixels { try socket.sendPixels(pixels, deadline: deadline) }
                }.value
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
    private let video: Bool
    private let recording: Bool
    private var rangeEnd: Double?
    private var frames: MediaVideoFrames?
    private var audioTracks: [AVAssetTrack] = []
    private var rate: Float = 1
    public init(video: Bool = false, recording: Bool = false) { self.video = video; self.recording = recording }
    public func load(_ url: URL) async throws {
        guard player == nil else { throw MediaFailure.invalidProtocol }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let bytes = values.fileSize, bytes > 0,
              bytes <= (recording ? 8 * 1024 * 1024 * 1024 : 512 * 1024 * 1024) else { throw MediaFailure.tooLarge }
        // A private single-file lease must never resolve another local file or remote media.
        let asset = AVURLAsset(url: url, options: [AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue])
        let seconds = try await asset.load(.duration).seconds
        guard seconds.isFinite, seconds > 0, seconds <= 86_400 else { throw MediaFailure.unreadable }
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        guard video ? tracks.count == 1 : (tracks.isEmpty && !audio.isEmpty)
        else { throw MediaFailure.unreadable }
        duration = seconds
        audioTracks = audio
        let item = AVPlayerItem(asset: asset)
        // Speed changes keep voices at their natural pitch, matching export.
        item.audioTimePitchAlgorithm = .spectral
        if video { frames = try await MediaVideoFrames(item: item, track: tracks[0], duration: seconds) }
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
        try command.validate()
        guard let player, player.currentItem?.status == .readyToPlay, player.error == nil else { throw MediaFailure.unreadable }
        var refresh = [.loadVideo, .seek, .seekPaused].contains(command.kind)
        switch command.kind {
        case .playRange:
            guard recording, let range = command.range, range.end <= duration else { throw MediaFailure.invalidProtocol }
            player.pause()
            player.currentItem?.forwardPlaybackEndTime = CMTime(seconds: range.end, preferredTimescale: 600)
            rangeEnd = range.end
            let current = player.currentTime().seconds
            if ended || current < range.start || current >= range.end {
                guard await player.seek(to: CMTime(seconds: range.start, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) else { throw MediaFailure.unavailable }
                refresh = true
            }
            ended = false; player.play(); player.rate = rate
        case .play:
            player.currentItem?.forwardPlaybackEndTime = .invalid; rangeEnd = nil
            if ended || player.currentTime().seconds >= duration {
                guard await player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) else { throw MediaFailure.unavailable }
                refresh = true; ended = false
            }
            player.play(); player.rate = rate
        case .pause: player.pause()
        case .seek, .seekPaused:
            if command.kind == .seekPaused { player.pause() }
            player.currentItem?.forwardPlaybackEndTime = .invalid; rangeEnd = nil
            guard let fraction = command.fraction else { throw MediaFailure.invalidProtocol }
            guard await player.seek(to: CMTime(seconds: fraction * duration, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) else { throw MediaFailure.unavailable }
            ended = fraction == 1
        case .volume:
            guard video, let fraction = command.fraction else { throw MediaFailure.invalidProtocol }
            player.volume = Float(fraction)
        case .mix: try apply(command.mix, to: player)
        case .load, .loadVideo:
            guard (command.kind == .loadVideo) == video else { throw MediaFailure.invalidProtocol }
        case .status: break
        case .reply, .failed: throw MediaFailure.invalidProtocol
        }
        let time = player.currentTime().seconds
        guard time.isFinite else { throw MediaFailure.unreadable }
        let elapsed = ended ? (rangeEnd ?? duration) : min(duration, max(0, time))
        var state = MediaPlaybackState(phase: elapsed >= duration ? .ended : ended || player.rate == 0 ? .paused : .playing,
                                       elapsed: elapsed, duration: duration)
        state.video = video; state.volume = Double(player.volume)
        if let frames {
            let frame = try await frames.snapshot(at: CMTime(seconds: min(elapsed, max(0, duration - 0.001)), preferredTimescale: 600), refresh: refresh)
            guard let frame else { throw MediaFailure.unavailable }
            state.frame = frame.0; state.pixels = frame.1
        }
        return state
    }
    /// Recording previews only. An empty volume list changes speed alone, for recordings whose
    /// tracks the host could not list.
    private func apply(_ mix: MediaPlaybackMix?, to player: AVPlayer) throws {
        guard recording, let mix, mix.volumes.isEmpty || mix.volumes.count == audioTracks.count,
              let item = player.currentItem else { throw MediaFailure.invalidProtocol }
        rate = Float(mix.rate)
        if player.rate != 0 { player.rate = rate }
        guard !mix.volumes.isEmpty else { item.audioMix = nil; return }
        let audioMix = AVMutableAudioMix()
        audioMix.inputParameters = zip(audioTracks, mix.volumes).map { track, volume in
            let parameter = AVMutableAudioMixInputParameters(track: track)
            parameter.setVolume(Float(volume), at: .zero)
            return parameter
        }
        item.audioMix = audioMix
    }
    public func stop() {
        player?.pause(); player?.replaceCurrentItem(with: nil); player = nil; frames = nil; audioTracks = []; rate = 1
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil; ended = false
    }
}
