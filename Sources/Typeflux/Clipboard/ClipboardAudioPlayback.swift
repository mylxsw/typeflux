import AVFoundation
import Combine

/// Plays one copied audio file for the selected clipboard row and publishes its progress.
final class ClipboardAudioPlayback: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?

    deinit {
        stop()
    }

    var isLoaded: Bool {
        player != nil
    }

    /// Prepares `url` without starting playback. `duration` may be unknown yet; the item reports it.
    func load(_ url: URL, duration: TimeInterval?) {
        stop()
        let player = AVPlayer(url: url)
        self.player = player
        self.duration = duration ?? 0
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            self?.update(time.seconds)
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: player.currentItem, queue: .main
        ) { [weak self] _ in
            self?.finish()
        }
    }

    func updateDuration(_ duration: TimeInterval?) {
        if let duration, duration > 0 { self.duration = duration }
    }

    func toggle() {
        guard let player else { return }
        if isPlaying {
            player.pause()
        } else {
            if progress >= 1 { seek(to: 0) }
            player.play()
        }
        isPlaying.toggle()
    }

    /// Jumps to `fraction` of the recording, e.g. after a click on the waveform.
    func seek(to fraction: Double) {
        guard let player, duration > 0 else { return }
        let clamped = min(max(fraction, 0), 1)
        player.seek(to: CMTime(seconds: clamped * duration, preferredTimescale: 600))
        progress = clamped
        elapsed = clamped * duration
    }

    /// Stops and releases the player; called when the row collapses.
    func stop() {
        player?.pause()
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        timeObserver = nil
        endObserver = nil
        player = nil
        isPlaying = false
        progress = 0
        elapsed = 0
    }

    func update(_ seconds: TimeInterval) {
        if duration <= 0, let itemDuration = player?.currentItem?.duration.seconds,
           itemDuration.isFinite, itemDuration > 0 {
            duration = itemDuration
        }
        guard seconds.isFinite else { return }
        elapsed = max(seconds, 0)
        progress = duration > 0 ? min(elapsed / duration, 1) : 0
    }

    func finish() {
        isPlaying = false
        progress = 1
        elapsed = duration
    }
}
