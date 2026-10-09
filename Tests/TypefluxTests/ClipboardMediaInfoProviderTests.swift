@testable import Typeflux
import XCTest

final class ClipboardMediaInfoProviderTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = ClipboardTestSupport.temporaryDirectory("ClipboardMediaInfoProviderTests")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    // MARK: - Accumulator

    func testAccumulatorKeepsThePeakOfEachBar() {
        var accumulator = ClipboardWaveformAccumulator(bars: 4, expectedSamples: 8)
        accumulator.add([0.1, -0.2, 0.4, 0.3])
        accumulator.add([-0.8, 0.1, 0, 0.2])
        XCTAssertEqual(accumulator.peaks, [0.2, 0.4, 0.8, 0.2])
        XCTAssertEqual(accumulator.levels(), [0.25, 0.5, 1, 0.25])
    }

    func testAccumulatorPutsOverflowInTheLastBarAndKeepsSilenceFlat() {
        var accumulator = ClipboardWaveformAccumulator(bars: 2, expectedSamples: 2)
        accumulator.add([0, 0, 0, 0])
        XCTAssertEqual(accumulator.levels(), [0, 0])
        accumulator.add([0.5])
        XCTAssertEqual(accumulator.levels(), [0, 1])
    }

    func testAccumulatorToleratesDegenerateSizes() {
        var accumulator = ClipboardWaveformAccumulator(bars: 0, expectedSamples: 0)
        accumulator.add([0.3, -0.6])
        XCTAssertEqual(accumulator.levels(), [1])
    }

    func testResampleKeepsPeaks() {
        XCTAssertEqual(ClipboardMediaInfoProvider.resample([0.1, 0.9, 0.2, 0.4], to: 2), [0.9, 0.4])
        XCTAssertEqual(ClipboardMediaInfoProvider.resample([0.1, 0.9, 0.2], to: 3), [0.1, 0.9, 0.2])
        XCTAssertEqual(ClipboardMediaInfoProvider.resample([0.2, 0.8], to: 4), [0.2, 0.2, 0.8, 0.8])
        XCTAssertEqual(ClipboardMediaInfoProvider.resample([], to: 4), [])
        XCTAssertEqual(ClipboardMediaInfoProvider.resample([0.5], to: 0), [])
    }

    func testCancelledWaveformDecodeReturnsNothingAndCachesNothing() async throws {
        let url = try ClipboardTestSupport.makeAudioFile(named: "long.wav", in: directory, seconds: 30)
        let provider = ClipboardMediaInfoProvider()
        let task = Task { await provider.waveform(for: url, bars: 8) }
        task.cancel()
        _ = await task.value
        // A cancelled decode may finish before it notices; either way the cache stays consistent.
        if let cached = provider.cachedWaveform(for: url, bars: 8) {
            XCTAssertEqual(cached.count, 8)
        }
        let levels = await provider.waveform(for: url, bars: 8)
        XCTAssertEqual(levels?.count, 8)
    }

    // MARK: - Provider

    func testAudioDurationAndWaveform() async throws {
        let url = try ClipboardTestSupport.makeAudioFile(named: "tone.wav", in: directory, seconds: 1)
        let provider = ClipboardMediaInfoProvider()

        XCTAssertNil(provider.cachedInfo(for: url))
        let info = await provider.info(for: url, kind: .audio)
        XCTAssertEqual(info?.duration ?? 0, 1, accuracy: 0.05)
        XCTAssertNil(info?.pageCount)
        XCTAssertEqual(provider.cachedInfo(for: url), info)

        XCTAssertNil(provider.cachedWaveform(for: url, bars: 10))
        let waveform = await provider.waveform(for: url, bars: 10)
        let levels = try XCTUnwrap(waveform)
        XCTAssertEqual(levels.count, 10)
        XCTAssertEqual(levels.max() ?? 0, 1, accuracy: 0.001)
        XCTAssertLessThan(levels[0], levels[9], "The tone gets louder towards the end")
        XCTAssertEqual(provider.cachedWaveform(for: url, bars: 10), levels)
        XCTAssertEqual(provider.cachedWaveform(for: url, bars: 5)?.count, 5, "One decode serves every bar count")
        XCTAssertNil(provider.cachedWaveform(for: url, bars: 0))
    }

    func testPDFPageCount() async {
        let url = ClipboardTestSupport.makePDF(named: "doc.pdf", in: directory, pages: 3)
        let info = await ClipboardMediaInfoProvider().info(for: url, kind: .pdf)
        XCTAssertEqual(info, ClipboardMediaInfo(duration: nil, pageCount: 3))
    }

    func testUnreadableMissingOrOtherFilesHaveNoInfo() async {
        let provider = ClipboardMediaInfoProvider()
        let missing = directory.appendingPathComponent("gone.m4a")
        let garbage = ClipboardTestSupport.makeFile(named: "broken.m4a", in: directory)
        let brokenPDF = ClipboardTestSupport.makeFile(named: "broken.pdf", in: directory)
        let note = ClipboardTestSupport.makeFile(named: "note.txt", in: directory)

        let missingInfo = await provider.info(for: missing, kind: .audio)
        let garbageInfo = await provider.info(for: garbage, kind: .audio)
        let brokenPDFInfo = await provider.info(for: brokenPDF, kind: .pdf)
        let noteInfo = await provider.info(for: note, kind: .document)
        XCTAssertNil(missingInfo)
        XCTAssertNil(garbageInfo)
        XCTAssertNil(brokenPDFInfo)
        XCTAssertNil(noteInfo)

        let missingWave = await provider.waveform(for: missing, bars: 8)
        let garbageWave = await provider.waveform(for: garbage, bars: 8)
        let noBars = await provider.waveform(for: garbage, bars: 0)
        XCTAssertNil(missingWave)
        XCTAssertNil(garbageWave)
        XCTAssertNil(noBars)
    }
}
