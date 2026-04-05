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
}
