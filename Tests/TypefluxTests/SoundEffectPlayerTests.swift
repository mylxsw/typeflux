@testable import Typeflux
import XCTest

final class SoundEffectPlayerTests: XCTestCase {
    // MARK: - Effect Raw Values

    func testEffectRawValues() {
        XCTAssertEqual(SoundEffectPlayer.Effect.tip.rawValue, "tip")
        XCTAssertEqual(SoundEffectPlayer.Effect.done.rawValue, "done")
        XCTAssertEqual(SoundEffectPlayer.Effect.error.rawValue, "error")
    }

    // MARK: - Volume Values

    func testDoneVolume() {
        XCTAssertEqual(SoundEffectPlayer.Effect.done.volume, 0.22, accuracy: 0.001)
    }

    func testTipVolume() {
        XCTAssertEqual(SoundEffectPlayer.Effect.tip.volume, 0.2, accuracy: 0.001)
    }

    func testErrorVolume() {
        XCTAssertEqual(SoundEffectPlayer.Effect.error.volume, 0.26, accuracy: 0.001)
    }

    func testEachEffectHasDistinctVolume() {
        let volumes: Set<Float> = [
            SoundEffectPlayer.Effect.tip.volume,
            SoundEffectPlayer.Effect.done.volume,
            SoundEffectPlayer.Effect.error.volume
        ]
        XCTAssertEqual(volumes.count, 3)
    }

    @MainActor
    func testInitPreloadsAllEffectPlayers() throws {
        let settingsStore = try makeSettingsStore()
        var requestedURLs: [URL] = []

        _ = SoundEffectPlayer(settingsStore: settingsStore, isEnabledOverride: { true }) { url in
            requestedURLs.append(url)
            return MockSoundEffectPlayback()
        }

        XCTAssertEqual(requestedURLs.count, SoundEffectPlayer.Effect.allCases.count)
        XCTAssertEqual(Set(requestedURLs.map(\.lastPathComponent)), Set(["tip.mp3", "done.mp3", "error.mp3"]))
    }

    @MainActor
    func testPlayReusesPreloadedPlayerAndRestartsFromBeginning() throws {
        let settingsStore = try makeSettingsStore()
        let playbackByName = PlaybackRegistry()
        var requestedURLs: [URL] = []
        let player = SoundEffectPlayer(settingsStore: settingsStore, isEnabledOverride: { true }) { url in
            requestedURLs.append(url)
            let playback = MockSoundEffectPlayback()
            playbackByName[url.deletingPathExtension().lastPathComponent] = playback
            return playback
        }

        let playback = try XCTUnwrap(playbackByName["done"])
        playback.currentTime = 1.2
        player.play(.done)

        XCTAssertEqual(requestedURLs.count, SoundEffectPlayer.Effect.allCases.count)
        XCTAssertEqual(playback.stopCallCount, 1)
        XCTAssertEqual(playback.currentTime, 0, accuracy: 0.001)
        XCTAssertEqual(playback.playCallCount, 1)
        XCTAssertEqual(playback.volume, SoundEffectPlayer.Effect.done.volume, accuracy: 0.001)
    }

    @MainActor
    func testPlayStopsOtherEffectPlayers() throws {
        let settingsStore = try makeSettingsStore()
        let playbackByName = PlaybackRegistry()
        let player = SoundEffectPlayer(settingsStore: settingsStore, isEnabledOverride: { true }) { url in
            let playback = MockSoundEffectPlayback()
            playback.currentTime = 0.8
            playbackByName[url.deletingPathExtension().lastPathComponent] = playback
            return playback
        }

        player.play(.tip)

        let tipPlayback = try XCTUnwrap(playbackByName["tip"])
        let donePlayback = try XCTUnwrap(playbackByName["done"])

        XCTAssertEqual(tipPlayback.playCallCount, 1)
        XCTAssertEqual(donePlayback.stopCallCount, 1)
        XCTAssertEqual(donePlayback.currentTime, 0, accuracy: 0.001)
    }

    @MainActor
    func testPlayDoesNothingWhenSoundEffectsAreDisabled() throws {
        let settingsStore = try makeSettingsStore()
        settingsStore.soundEffectsEnabled = false
        let playbackByName = PlaybackRegistry()
        let player = SoundEffectPlayer(settingsStore: settingsStore, isEnabledOverride: { false }) { url in
            let playback = MockSoundEffectPlayback()
            playback.currentTime = 0.6
            playbackByName[url.deletingPathExtension().lastPathComponent] = playback
            return playback
        }

        player.play(.done)

        let donePlayback = try XCTUnwrap(playbackByName["done"])
        let tipPlayback = try XCTUnwrap(playbackByName["tip"])
        XCTAssertEqual(donePlayback.playCallCount, 0)
        XCTAssertEqual(donePlayback.stopCallCount, 1)
        XCTAssertEqual(donePlayback.currentTime, 0, accuracy: 0.001)
        XCTAssertEqual(tipPlayback.stopCallCount, 1)
        XCTAssertEqual(tipPlayback.currentTime, 0, accuracy: 0.001)
    }

    @MainActor
    func testPlayReturnsTrueWhenPlaybackStarts() throws {
        let settingsStore = try makeSettingsStore()
        let playback = MockSoundEffectPlayback()
        let player = SoundEffectPlayer(settingsStore: settingsStore, isEnabledOverride: { true }) { _ in
            playback
        }

        XCTAssertTrue(player.play(.done))
    }

    @MainActor
    func testPlayReturnsFalseWhenSoundEffectsAreDisabled() throws {
        let settingsStore = try makeSettingsStore()
        settingsStore.soundEffectsEnabled = false
        let player = SoundEffectPlayer(settingsStore: settingsStore, isEnabledOverride: { false }) { _ in
            MockSoundEffectPlayback()
        }

        XCTAssertFalse(player.play(.done))
    }

    func testPlayAsyncSchedulesPlaybackOnMainActor() async throws {
        let settingsStore = try makeSettingsStore()
        let playbackByName = PlaybackRegistry()
        let playExpectation = expectation(description: "Async sound effect playback started")
        let player = SoundEffectPlayer(settingsStore: settingsStore, isEnabledOverride: { true }) { url in
            let playback = MockSoundEffectPlayback()
            playbackByName[url.deletingPathExtension().lastPathComponent] = playback
            if url.lastPathComponent == "done.mp3" {
                playback.playExpectation = playExpectation
            }
            return playback
        }

        player.playAsync(.done)

        await fulfillment(of: [playExpectation], timeout: 1.0)

        let playback = try XCTUnwrap(playbackByName["done"])
        XCTAssertEqual(playback.playCallCount, 1)
        XCTAssertEqual(playback.stopCallCount, 1)
        XCTAssertEqual(playback.volume, SoundEffectPlayer.Effect.done.volume, accuracy: 0.001)
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
    var playExpectation: XCTestExpectation?
    private(set) var playCallCount = 0
    private(set) var stopCallCount = 0

    func prepareToPlay() -> Bool {
        true
    }

    func play() -> Bool {
        playCallCount += 1
        playExpectation?.fulfill()
        return shouldPlay
    }

    func stop() {
        stopCallCount += 1
    }
}

private final class PlaybackRegistry {
    private var storage: [String: MockSoundEffectPlayback] = [:]

    subscript(key: String) -> MockSoundEffectPlayback? {
        get { storage[key] }
        set { storage[key] = newValue }
    }
}
