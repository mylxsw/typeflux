import AVFoundation
import Foundation

final class SoundEffectPlayer {
    enum Effect: String {
        case start
        case done
        case error

        var volume: Float {
            switch self {
            case .start:
                0.18
            case .done:
                0.22
            case .error:
                0.26
            }
        }
    }

    private let settingsStore: SettingsStore
    private var activePlayers: [UUID: AVAudioPlayer] = [:]

    init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
    }

    @MainActor
    func play(_ effect: Effect) {
        guard settingsStore.soundEffectsEnabled else { return }
        guard let url = resourceURL(for: effect) else {
            ErrorLogStore.shared.log("Missing sound effect resource: \(effect.rawValue).mp3")
            return
        }

        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.volume = effect.volume
            player.prepareToPlay()

            guard player.play() else {
                ErrorLogStore.shared.log("Failed to play sound effect: \(effect.rawValue)")
                return
            }

            let id = UUID()
            activePlayers[id] = player
            scheduleCleanup(for: id, player: player)
        } catch {
            ErrorLogStore.shared.log("Failed to initialize sound effect \(effect.rawValue): \(error.localizedDescription)")
        }
    }

    private func resourceURL(for effect: Effect) -> URL? {
        Bundle.module.url(forResource: effect.rawValue, withExtension: "mp3", subdirectory: "Resources")
            ?? Bundle.module.url(forResource: effect.rawValue, withExtension: "mp3")
    }

    @MainActor
    private func scheduleCleanup(for id: UUID, player: AVAudioPlayer) {
        let duration = max(player.duration, 0.1)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000) + 100_000_000)
            self?.activePlayers.removeValue(forKey: id)
        }
    }
}
