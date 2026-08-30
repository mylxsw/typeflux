import AVFoundation
import Foundation

protocol SoundEffectPlayback: AnyObject {
    var volume: Float { get set }
    var currentTime: TimeInterval { get set }
    func prepareToPlay() -> Bool
    func play() -> Bool
    func stop()
}

extension AVAudioPlayer: SoundEffectPlayback {}

final class SoundEffectPlayer {
    enum Effect: String, CaseIterable {
        case tip
        case done
        case error

        var volume: Float {
            switch self {
            case .tip:
                0.2
            case .done:
                0.22
            case .error:
                0.26
            }
        }
    }

    private let settingsStore: SettingsStore
    private let isEnabledOverride: (() -> Bool)?
    private let playerFactory: (URL) throws -> SoundEffectPlayback
    private var players: [Effect: SoundEffectPlayback] = [:]

    init(
        settingsStore: SettingsStore,
        isEnabledOverride: (() -> Bool)? = nil,
        playerFactory: @escaping (URL) throws -> SoundEffectPlayback = { url in
            try AVAudioPlayer(contentsOf: url)
        }
    ) {
        self.settingsStore = settingsStore
        self.isEnabledOverride = isEnabledOverride
        self.playerFactory = playerFactory

        preloadPlayers()
    }

    @discardableResult
    @MainActor
    func play(_ effect: Effect) -> Bool {
        guard isEnabledOverride?() ?? settingsStore.soundEffectsEnabled else {
            stopPlayers()
            return false
        }
        guard let player = player(for: effect) else { return false }

        stopPlayers(except: effect)
        player.stop()
        player.currentTime = 0
        player.volume = effect.volume
        _ = player.prepareToPlay()

        guard player.play() else {
            ErrorLogStore.shared.log("Failed to play sound effect: \(effect.rawValue)")
            return false
        }

        return true
    }

    private func stopPlayers(except activeEffect: Effect) {
        for (effect, player) in players where effect != activeEffect {
            player.stop()
            player.currentTime = 0
        }
    }

    private func stopPlayers() {
        for player in players.values {
            player.stop()
            player.currentTime = 0
        }
    }

    func playAsync(_ effect: Effect) {
        Task { @MainActor in
            _ = self.play(effect)
        }
    }

    private func preloadPlayers() {
        for effect in Effect.allCases {
            _ = loadPlayer(for: effect)
        }
    }

    private func player(for effect: Effect) -> SoundEffectPlayback? {
        if let player = players[effect] {
            return player
        }

        return loadPlayer(for: effect)
    }

    @discardableResult
    private func loadPlayer(for effect: Effect) -> SoundEffectPlayback? {
        guard let url = resourceURL(for: effect) else {
            ErrorLogStore.shared.log("Missing sound effect resource: \(effect.rawValue).mp3")
            return nil
        }

        do {
            let player = try playerFactory(url)
            player.volume = effect.volume
            _ = player.prepareToPlay()
            players[effect] = player
            return player
        } catch {
            ErrorLogStore.shared
                .log("Failed to initialize sound effect \(effect.rawValue): \(error.localizedDescription)")
            return nil
        }
    }

    private func resourceURL(for effect: Effect) -> URL? {
        Bundle.appResources.url(forResource: effect.rawValue, withExtension: "mp3", subdirectory: "Resources")
            ?? Bundle.appResources.url(forResource: effect.rawValue, withExtension: "mp3")
    }
}
