@testable import Typeflux
import XCTest
import AVFoundation

final class SoundEffectPlayerTests: XCTestCase {
    @MainActor
    func testRingHoverResourceIsPlayableAndReplaysWithoutCreatingAnotherPlayer() throws {
        let settingsStore = try makeSettingsStore()
        let playback = MockSoundEffectPlayback()
        var requestedURLs: [URL] = []
        let player = SoundEffectPlayer(settingsStore: settingsStore, isEnabledOverride: { true }, playerFactory: { url in
            requestedURLs.append(url)
            let audio = try AVAudioPlayer(contentsOf: url)
            XCTAssertGreaterThan(audio.duration, 0)
            XCTAssertLessThan(audio.duration, 0.2)
            return playback
        })
        XCTAssertTrue(player.play(.ringHover))
        playback.currentTime = 0.05
        XCTAssertTrue(player.play(.ringHover))
        XCTAssertEqual(requestedURLs.map(\.lastPathComponent), ["ringHover.mp3"])
        XCTAssertEqual(playback.currentTime, 0)
        XCTAssertEqual(playback.playCallCount, 2)
    }

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
    func testInitDoesNotLoadEffectPlayersEvenWhenEnabled() throws {
        let settingsStore = try makeSettingsStore()
        var requestedURLs: [URL] = []

        _ = SoundEffectPlayer(settingsStore: settingsStore, isEnabledOverride: { true }, playerFactory: { url in
            requestedURLs.append(url)
            return MockSoundEffectPlayback()
        })

        XCTAssertTrue(requestedURLs.isEmpty)
    }

    @MainActor
    func testPlayLoadsOnlyRequestedEffectAndReusesPlayer() throws {
        let settingsStore = try makeSettingsStore()
        let playbackByName = PlaybackRegistry()
        var requestedURLs: [URL] = []
        let player = SoundEffectPlayer(settingsStore: settingsStore, isEnabledOverride: { true }, playerFactory: { url in
            requestedURLs.append(url)
            let playback = MockSoundEffectPlayback()
            playbackByName[url.deletingPathExtension().lastPathComponent] = playback
            return playback
        })

        XCTAssertTrue(player.play(.done))
        let playback = try XCTUnwrap(playbackByName["done"])
        XCTAssertEqual(requestedURLs.map(\.lastPathComponent), ["done.mp3"])
        XCTAssertEqual(playback.prepareCallCount, 1)
        playback.currentTime = 1.2
        XCTAssertTrue(player.play(.done))

        XCTAssertEqual(requestedURLs.map(\.lastPathComponent), ["done.mp3"])
        XCTAssertEqual(playback.stopCallCount, 2)
        XCTAssertEqual(playback.currentTime, 0, accuracy: 0.001)
        XCTAssertEqual(playback.prepareCallCount, 2)
        XCTAssertEqual(playback.playCallCount, 2)
        XCTAssertEqual(playback.volume, SoundEffectPlayer.Effect.done.volume, accuracy: 0.001)
    }

    @MainActor
    func testPlayStopsOtherEffectPlayers() throws {
        let settingsStore = try makeSettingsStore()
        let playbackByName = PlaybackRegistry()
        let player = SoundEffectPlayer(settingsStore: settingsStore, isEnabledOverride: { true }, playerFactory: { url in
            let playback = MockSoundEffectPlayback()
            playback.currentTime = 0.8
            playbackByName[url.deletingPathExtension().lastPathComponent] = playback
            return playback
        })

        XCTAssertTrue(player.play(.done))
        let donePlayback = try XCTUnwrap(playbackByName["done"])
        donePlayback.currentTime = 0.8
        player.play(.tip)

        let tipPlayback = try XCTUnwrap(playbackByName["tip"])

        XCTAssertEqual(tipPlayback.playCallCount, 1)
        XCTAssertEqual(donePlayback.stopCallCount, 2)
        XCTAssertEqual(donePlayback.currentTime, 0, accuracy: 0.001)
        XCTAssertNil(playbackByName["error"])
    }

    @MainActor
    func testPlayDoesNothingWhenSoundEffectsAreDisabled() throws {
        let settingsStore = try makeSettingsStore()
        settingsStore.soundEffectsEnabled = false
        var creationCount = 0
        let player = SoundEffectPlayer(settingsStore: settingsStore, playerFactory: { _ in
            creationCount += 1
            return MockSoundEffectPlayback()
        })

        XCTAssertEqual(creationCount, 0)
        for effect in SoundEffectPlayer.Effect.allCases {
            XCTAssertFalse(player.play(effect))
        }
        XCTAssertEqual(creationCount, 0)
    }

    @MainActor
    func testEnablingLoadsOnDemandAndDisablingStopsLoadedPlayers() throws {
        let settingsStore = try makeSettingsStore()
        var enabled = false
        var requestedURLs: [URL] = []
        let playback = MockSoundEffectPlayback()
        let player = SoundEffectPlayer(settingsStore: settingsStore, isEnabledOverride: { enabled }, playerFactory: { url in
            requestedURLs.append(url)
            return playback
        })

        XCTAssertFalse(player.play(.error))
        XCTAssertTrue(requestedURLs.isEmpty)
        enabled = true
        XCTAssertTrue(player.play(.tip))
        XCTAssertEqual(requestedURLs.map(\.lastPathComponent), ["tip.mp3"])

        enabled = false
        playback.currentTime = 0.6
        XCTAssertFalse(player.play(.done))
        XCTAssertEqual(requestedURLs.map(\.lastPathComponent), ["tip.mp3"])
        XCTAssertEqual(playback.stopCallCount, 2)
        XCTAssertEqual(playback.currentTime, 0, accuracy: 0.001)
        XCTAssertEqual(playback.playCallCount, 1)

        enabled = true
        XCTAssertTrue(player.play(.tip))
        XCTAssertEqual(requestedURLs.count, 1)
        XCTAssertEqual(playback.playCallCount, 2)
    }

    @MainActor
    func testFailedPlayerCreationCanBeRetried() throws {
        let settingsStore = try makeSettingsStore()
        var attempts = 0
        let player = SoundEffectPlayer(settingsStore: settingsStore, isEnabledOverride: { true }, playerFactory: { _ in
            attempts += 1
            if attempts == 1 { throw NSError(domain: "SoundEffectPlayerTests", code: 1) }
            return MockSoundEffectPlayback()
        })

        XCTAssertFalse(player.play(.error))
        XCTAssertTrue(player.play(.error))
        XCTAssertEqual(attempts, 2)
    }

    @MainActor
    func testPlayReturnsFalseWhenPlaybackFails() throws {
        let settingsStore = try makeSettingsStore()
        let playback = MockSoundEffectPlayback()
        playback.shouldPlay = false
        let player = SoundEffectPlayer(settingsStore: settingsStore, isEnabledOverride: { true }, playerFactory: { _ in playback })

        XCTAssertFalse(player.play(.done))
        XCTAssertEqual(playback.playCallCount, 1)
    }

    @MainActor
    func testPlayReturnsTrueWhenPlaybackStarts() throws {
        let settingsStore = try makeSettingsStore()
        let playback = MockSoundEffectPlayback()
        let player = SoundEffectPlayer(settingsStore: settingsStore, isEnabledOverride: { true }, playerFactory: { _ in
            playback
        })

        XCTAssertTrue(player.play(.done))
    }

    @MainActor
    func testPlayReturnsFalseWhenSoundEffectsAreDisabled() throws {
        let settingsStore = try makeSettingsStore()
        settingsStore.soundEffectsEnabled = false
        let player = SoundEffectPlayer(settingsStore: settingsStore, isEnabledOverride: { false }, playerFactory: { _ in
            MockSoundEffectPlayback()
        })

        XCTAssertFalse(player.play(.done))
    }

    func testPlayAsyncSchedulesPlaybackOnMainActor() async throws {
        let settingsStore = try makeSettingsStore()
        let playbackByName = PlaybackRegistry()
        let playExpectation = expectation(description: "Async sound effect playback started")
        let player = SoundEffectPlayer(settingsStore: settingsStore, isEnabledOverride: { true }, playerFactory: { url in
            let playback = MockSoundEffectPlayback()
            playbackByName[url.deletingPathExtension().lastPathComponent] = playback
            if url.lastPathComponent == "done.mp3" {
                playback.playExpectation = playExpectation
            }
            return playback
        })

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
    private(set) var prepareCallCount = 0

    func prepareToPlay() -> Bool {
        prepareCallCount += 1
        return true
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
