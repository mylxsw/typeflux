@testable import Typeflux
import XCTest

@MainActor
final class SettingsViewModelHistoryAudioTests: XCTestCase {
    func testHistoryPipelineTimelinePreservesStageOffsetsAndHighlightsSlowestLane() {
        let base = Date(timeIntervalSince1970: 1000)
        let recordID = UUID()
        let record = HistoryRecord(
            id: recordID,
            date: base,
            audioFilePath: "/tmp/timeline.wav",
            transcriptText: "hello",
            pipelineTiming: HistoryPipelineTiming(
                recordingStoppedAt: base,
                audioFileReadyAt: base.addingTimeInterval(0.1),
                transcriptionStartedAt: base.addingTimeInterval(0.1),
                transcriptionCompletedAt: base.addingTimeInterval(0.8),
                llmProcessingStartedAt: base.addingTimeInterval(0.8),
                llmProcessingCompletedAt: base.addingTimeInterval(2.8),
                applyStartedAt: base.addingTimeInterval(2.8),
                applyCompletedAt: base.addingTimeInterval(3.0)
            )
        )
        let viewModel = makeViewModel(
            records: [record],
            audioPreviewPlayer: FakeHistoryAudioPreviewPlayer(playResult: true)
        )
        waitForHistoryRecord(recordID, in: viewModel)

        let timeline = viewModel.displayedHistory.first?.pipelineTimeline
        let llmLane = timeline?.lanes.first { $0.id == "llm" }

        XCTAssertEqual(timeline?.lanes.count, 4)
        XCTAssertEqual(llmLane?.offsetFraction ?? -1, 0.8 / 3.0, accuracy: 0.001)
        XCTAssertEqual(llmLane?.widthFraction ?? -1, 2.0 / 3.0, accuracy: 0.001)
        XCTAssertEqual(llmLane?.isSlowest, true)
        XCTAssertNotNil(timeline?.totalDurationText)
    }

    func testPlayAudioStartsPreviewForExistingHistoryFile() throws {
        let audioURL = try makeTemporaryAudioPlaceholder()
        let recordID = UUID()
        let audioPreviewPlayer = FakeHistoryAudioPreviewPlayer(playResult: true)
        let viewModel = makeViewModel(
            records: [
                makeRecord(id: recordID, audioFilePath: audioURL.path)
            ],
            audioPreviewPlayer: audioPreviewPlayer
        )
        waitForHistoryRecord(recordID, in: viewModel)

        viewModel.playAudio(id: recordID)

        XCTAssertEqual(audioPreviewPlayer.playedURLs, [audioURL])
        XCTAssertEqual(viewModel.playingAudioRecordID, recordID)
        XCTAssertNil(viewModel.toastMessage)
    }

    func testPlayAudioStopsCurrentPreviewWhenSameRecordIsSelectedAgain() throws {
        let audioURL = try makeTemporaryAudioPlaceholder()
        let recordID = UUID()
        let audioPreviewPlayer = FakeHistoryAudioPreviewPlayer(playResult: true)
        let viewModel = makeViewModel(
            records: [
                makeRecord(id: recordID, audioFilePath: audioURL.path)
            ],
            audioPreviewPlayer: audioPreviewPlayer
        )
        waitForHistoryRecord(recordID, in: viewModel)

        viewModel.playAudio(id: recordID)
        viewModel.playAudio(id: recordID)

        XCTAssertEqual(audioPreviewPlayer.playedURLs, [audioURL])
        XCTAssertEqual(audioPreviewPlayer.stopCallCount, 1)
        XCTAssertNil(viewModel.playingAudioRecordID)
    }

    func testPlayAudioClearsPlayingRecordWhenPreviewFinishes() throws {
        let audioURL = try makeTemporaryAudioPlaceholder()
        let recordID = UUID()
        let audioPreviewPlayer = FakeHistoryAudioPreviewPlayer(playResult: true)
        let viewModel = makeViewModel(
            records: [
                makeRecord(id: recordID, audioFilePath: audioURL.path)
            ],
            audioPreviewPlayer: audioPreviewPlayer
        )
        waitForHistoryRecord(recordID, in: viewModel)

        viewModel.playAudio(id: recordID)
        audioPreviewPlayer.onPlaybackFinished?()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertNil(viewModel.playingAudioRecordID)
    }

    func testPlayAudioShowsInfoToastWhenFileIsMissing() {
        let recordID = UUID()
        let missingURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("typeflux-missing-\(UUID().uuidString).wav")
        let audioPreviewPlayer = FakeHistoryAudioPreviewPlayer(playResult: true)
        let viewModel = makeViewModel(
            records: [
                makeRecord(id: recordID, audioFilePath: missingURL.path)
            ],
            audioPreviewPlayer: audioPreviewPlayer
        )
        waitForHistoryRecord(recordID, in: viewModel)

        viewModel.playAudio(id: recordID)

        XCTAssertTrue(audioPreviewPlayer.playedURLs.isEmpty)
        XCTAssertEqual(viewModel.toastMessage, L("history.toast.audioUnavailable"))
    }

    func testPlayAudioShowsInfoToastWhenPlaybackFails() throws {
        let audioURL = try makeTemporaryAudioPlaceholder()
        let recordID = UUID()
        let audioPreviewPlayer = FakeHistoryAudioPreviewPlayer(playResult: false)
        let viewModel = makeViewModel(
            records: [
                makeRecord(id: recordID, audioFilePath: audioURL.path)
            ],
            audioPreviewPlayer: audioPreviewPlayer
        )
        waitForHistoryRecord(recordID, in: viewModel)

        viewModel.playAudio(id: recordID)

        XCTAssertEqual(audioPreviewPlayer.playedURLs, [audioURL])
        XCTAssertNil(viewModel.playingAudioRecordID)
        XCTAssertEqual(viewModel.toastMessage, L("history.toast.audioPlaybackFailed"))
    }

    private func makeViewModel(
        records: [HistoryRecord],
        audioPreviewPlayer: HistoryAudioPreviewPlaying
    ) -> StudioViewModel {
        let suiteName = "SettingsViewModelHistoryAudioTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        return StudioViewModel(
            settingsStore: SettingsStore(defaults: defaults),
            historyStore: FixedHistoryStore(records: records),
            initialSection: .history,
            audioPreviewPlayer: audioPreviewPlayer
        )
    }

    private func makeRecord(id: UUID, audioFilePath: String) -> HistoryRecord {
        HistoryRecord(
            id: id,
            date: Date(),
            audioFilePath: audioFilePath,
            transcriptText: "hello"
        )
    }

    private func makeTemporaryAudioPlaceholder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("typeflux-audio-preview-\(UUID().uuidString).wav")
        try Data("audio".utf8).write(to: url)
        return url
    }

    private func waitForHistoryRecord(_ id: UUID, in viewModel: StudioViewModel) {
        let deadline = Date().addingTimeInterval(1)
        while viewModel.historyRecords.first(where: { $0.id == id }) == nil, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }
}

private final class FakeHistoryAudioPreviewPlayer: HistoryAudioPreviewPlaying {
    var onPlaybackFinished: (() -> Void)?

    private let playResult: Bool
    private(set) var playedURLs: [URL] = []
    private(set) var stopCallCount = 0

    init(playResult: Bool) {
        self.playResult = playResult
    }

    func play(fileURL: URL) throws -> Bool {
        playedURLs.append(fileURL)
        return playResult
    }

    func stop() {
        stopCallCount += 1
    }
}

private final class FixedHistoryStore: HistoryStore {
    private let records: [HistoryRecord]

    init(records: [HistoryRecord]) {
        self.records = records
    }

    func save(record _: HistoryRecord) {}

    func list() -> [HistoryRecord] {
        records
    }

    func list(limit _: Int, offset _: Int, searchQuery _: String?) -> [HistoryRecord] {
        records
    }

    func record(id: UUID) -> HistoryRecord? {
        records.first { $0.id == id }
    }

    func delete(id _: UUID) {}
    func purge(olderThanDays _: Int) {}
    func clear() {}

    func exportMarkdown() throws -> URL {
        URL(fileURLWithPath: "/tmp/typeflux-history.md")
    }
}
