@testable import Typeflux
import XCTest

final class SoundEffectPlayerTests: XCTestCase {
    // MARK: - Effect Raw Values

    func testEffectRawValues() {
        XCTAssertEqual(SoundEffectPlayer.Effect.start.rawValue, "start")
        XCTAssertEqual(SoundEffectPlayer.Effect.done.rawValue, "done")
        XCTAssertEqual(SoundEffectPlayer.Effect.error.rawValue, "error")
    }

    // MARK: - Volume Values

    func testStartVolume() {
        XCTAssertEqual(SoundEffectPlayer.Effect.start.volume, 0.18, accuracy: 0.001)
    }

    func testDoneVolume() {
        XCTAssertEqual(SoundEffectPlayer.Effect.done.volume, 0.22, accuracy: 0.001)
    }

    func testErrorVolume() {
        XCTAssertEqual(SoundEffectPlayer.Effect.error.volume, 0.26, accuracy: 0.001)
    }

    func testEachEffectHasDistinctVolume() {
        let volumes: Set<Float> = [
            SoundEffectPlayer.Effect.start.volume,
            SoundEffectPlayer.Effect.done.volume,
            SoundEffectPlayer.Effect.error.volume,
        ]
        XCTAssertEqual(volumes.count, 3)
    }

    @MainActor
    func testInitPreloadsAllEffectPlayers() throws {
        let settingsStore = try makeSettingsStore()
        var requestedURLs: [URL] = []

        _ = SoundEffectPlayer(settingsStore: settingsStore) { url in
            requestedURLs.append(url)
            return MockSoundEffectPlayback()
        }

        XCTAssertEqual(requestedURLs.count, SoundEffectPlayer.Effect.allCases.count)
        XCTAssertEqual(Set(requestedURLs.map(\.lastPathComponent)), Set(["start.mp3", "done.mp3", "error.mp3"]))
    }

    @MainActor
    func testPlayReusesPreloadedPlayerAndRestartsFromBeginning() throws {
        let settingsStore = try makeSettingsStore()
        let playback = MockSoundEffectPlayback()
        var requestedURLs: [URL] = []
        let player = SoundEffectPlayer(settingsStore: settingsStore) { url in
            requestedURLs.append(url)
            return playback
        }

        playback.currentTime = 1.2
        player.play(.start)

        XCTAssertEqual(requestedURLs.count, SoundEffectPlayer.Effect.allCases.count)
        XCTAssertEqual(playback.stopCallCount, 1)
        XCTAssertEqual(playback.currentTime, 0, accuracy: 0.001)
        XCTAssertEqual(playback.playCallCount, 1)
        XCTAssertEqual(playback.volume, SoundEffectPlayer.Effect.start.volume, accuracy: 0.001)
    }

    @MainActor
    func testPlayDoesNothingWhenSoundEffectsAreDisabled() throws {
        let settingsStore = try makeSettingsStore()
        settingsStore.soundEffectsEnabled = false
        let playback = MockSoundEffectPlayback()
        let player = SoundEffectPlayer(settingsStore: settingsStore) { _ in
            playback
        }

        player.play(.start)

        XCTAssertEqual(playback.playCallCount, 0)
        XCTAssertEqual(playback.stopCallCount, 0)
    }

    @MainActor
    func testPlayReturnsTrueWhenPlaybackStarts() throws {
        let settingsStore = try makeSettingsStore()
        let playback = MockSoundEffectPlayback()
        let player = SoundEffectPlayer(settingsStore: settingsStore) { _ in
            playback
        }

        XCTAssertTrue(player.play(.start))
    }

    @MainActor
    func testPlayReturnsFalseWhenSoundEffectsAreDisabled() throws {
        let settingsStore = try makeSettingsStore()
        settingsStore.soundEffectsEnabled = false
        let player = SoundEffectPlayer(settingsStore: settingsStore) { _ in
            MockSoundEffectPlayback()
        }

        XCTAssertFalse(player.play(.start))
    }

    private func makeSettingsStore() throws -> SettingsStore {
        let suiteName = "SoundEffectPlayerTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        return SettingsStore(defaults: defaults)
    }
}

private final class MockSoundEffectPlayback: SoundEffectPlayback {
    var volume: Float = 0
    var currentTime: TimeInterval = 0
    var shouldPlay = true
    private(set) var playCallCount = 0
    private(set) var stopCallCount = 0

    func prepareToPlay() -> Bool {
        true
    }

    func play() -> Bool {
        playCallCount += 1
        return shouldPlay
    }

    func stop() {
        stopCallCount += 1
    }
}
