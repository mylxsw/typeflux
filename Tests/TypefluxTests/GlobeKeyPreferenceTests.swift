@testable import Typeflux
import XCTest

final class GlobeKeyPreferenceTests: XCTestCase {
    func testDoNothingIsReady() {
        let reader = FixedGlobeKeyReader(usage: .doNothing)
        XCTAssertTrue(reader.isReadyForHotkey)
    }

    func testChangeInputSourceIsNotReady() {
        let reader = FixedGlobeKeyReader(usage: .changeInputSource)
        XCTAssertFalse(reader.isReadyForHotkey)
    }

    func testShowEmojiAndSymbolsIsNotReady() {
        let reader = FixedGlobeKeyReader(usage: .showEmojiAndSymbols)
        XCTAssertFalse(reader.isReadyForHotkey)
    }

    func testStartDictationIsNotReady() {
        let reader = FixedGlobeKeyReader(usage: .startDictation)
        XCTAssertFalse(reader.isReadyForHotkey)
    }

    func testGlobeKeyUsageRawValueMapping() {
        XCTAssertEqual(GlobeKeyUsage(rawValue: 0), .doNothing)
        XCTAssertEqual(GlobeKeyUsage(rawValue: 1), .changeInputSource)
        XCTAssertEqual(GlobeKeyUsage(rawValue: 2), .showEmojiAndSymbols)
        XCTAssertEqual(GlobeKeyUsage(rawValue: 3), .startDictation)
        XCTAssertNil(GlobeKeyUsage(rawValue: 99))
    }

    func testSystemReaderPreferenceDomainAndKey() {
        XCTAssertEqual(SystemGlobeKeyPreferenceReader.preferenceDomain, "com.apple.HIToolbox")
        XCTAssertEqual(SystemGlobeKeyPreferenceReader.preferenceKey, "AppleFnUsageType")
    }
}

private struct FixedGlobeKeyReader: GlobeKeyPreferenceReading {
    let usage: GlobeKeyUsage
    func currentUsage() -> GlobeKeyUsage { usage }
}
