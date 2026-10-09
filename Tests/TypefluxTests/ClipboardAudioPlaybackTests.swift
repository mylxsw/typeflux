@testable import Typeflux
import XCTest

final class ClipboardAudioPlaybackTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = ClipboardTestSupport.temporaryDirectory("ClipboardAudioPlaybackTests")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    func testControlsWithoutALoadedFileDoNothing() {
        let playback = ClipboardAudioPlayback()
        playback.toggle()
        playback.seek(to: 0.5)
        XCTAssertFalse(playback.isLoaded)
        XCTAssertFalse(playback.isPlaying)
        XCTAssertEqual(playback.progress, 0)
    }

    func testPlayPauseSeekFinishAndStop() throws {
        let url = try ClipboardTestSupport.makeAudioFile(named: "tone.wav", in: directory, seconds: 2)
        let playback = ClipboardAudioPlayback()
        playback.load(url, duration: nil)
        XCTAssertTrue(playback.isLoaded)
        XCTAssertEqual(playback.duration, 0)

        // The duration arrives from the row's media info after loading.
        playback.updateDuration(nil)
        playback.updateDuration(0)
        XCTAssertEqual(playback.duration, 0)
        playback.seek(to: 0.5)
        XCTAssertEqual(playback.progress, 0, "Seeking needs a known duration")
        playback.updateDuration(2)
        XCTAssertEqual(playback.duration, 2)

        playback.seek(to: 1.5)
        XCTAssertEqual(playback.progress, 1)
        XCTAssertEqual(playback.elapsed, 2)
        playback.seek(to: 0.25)
        XCTAssertEqual(playback.progress, 0.25)
        XCTAssertEqual(playback.elapsed, 0.5)

        playback.update(1)
        XCTAssertEqual(playback.progress, 0.5)
        playback.update(.nan)
        XCTAssertEqual(playback.progress, 0.5)

        playback.toggle()
        XCTAssertTrue(playback.isPlaying)
        playback.toggle()
        XCTAssertFalse(playback.isPlaying)

        playback.finish()
        XCTAssertEqual(playback.progress, 1)
        XCTAssertEqual(playback.elapsed, 2)
        // Playing a finished recording starts over.
        playback.toggle()
        XCTAssertTrue(playback.isPlaying)
        XCTAssertEqual(playback.progress, 0)

        playback.stop()
        XCTAssertFalse(playback.isLoaded)
        XCTAssertFalse(playback.isPlaying)
        XCTAssertEqual(playback.progress, 0)
        XCTAssertEqual(playback.elapsed, 0)
    }

    func testProgressStaysZeroWhileTheLengthIsUnknown() throws {
        let playback = ClipboardAudioPlayback()
        playback.update(3)
        XCTAssertEqual(playback.elapsed, 3)
        XCTAssertEqual(playback.progress, 0)

        let url = try ClipboardTestSupport.makeAudioFile(named: "tone.wav", in: directory, seconds: 1)
        playback.load(url, duration: 1)
        XCTAssertEqual(playback.duration, 1)
        XCTAssertEqual(playback.elapsed, 0, "Loading another file resets the position")
    }
}
