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

    func testHistoryPipelineTimelineIncludesASRAndLLMNetworkStages() {
        let base = Date(timeIntervalSince1970: 2_000)
        let recordID = UUID()
        var transport = NetworkTransportDiagnosticsSnapshot(endpoint: "wss://asr.example.com/realtime")
        transport.credentialLookupStartedAt = base.addingTimeInterval(-5.0)
        transport.credentialLookupCompletedAt = base.addingTimeInterval(-4.95)
        transport.routeLookupStartedAt = base.addingTimeInterval(-4.95)
        transport.routeLookupCompletedAt = base.addingTimeInterval(-4.10)
        transport.serverSelectionStartedAt = base.addingTimeInterval(-4.10)
        transport.serverSelectionCompletedAt = base.addingTimeInterval(-4.05)
        transport.webSocketTaskResumedAt = base.addingTimeInterval(-4.01)
        transport.domainLookupStartedAt = base.addingTimeInterval(-4.0)
        transport.domainLookupCompletedAt = base.addingTimeInterval(-3.99)
        transport.connectionStartedAt = base.addingTimeInterval(-3.99)
        transport.secureConnectionStartedAt = base.addingTimeInterval(-3.96)
        transport.secureConnectionCompletedAt = base.addingTimeInterval(-3.90)
        transport.connectionCompletedAt = base.addingTimeInterval(-3.90)
        transport.requestStartedAt = base.addingTimeInterval(-3.899)
        transport.requestCompletedAt = base.addingTimeInterval(-3.89)
        transport.firstResponseByteAt = base.addingTimeInterval(-3.82)

        var attempt = LLMRequestAttemptDiagnostics(
            id: UUID(),
            provider: "typefluxCloud",
            endpoint: "https://api.example.com/chat/completions",
            model: "default",
            requestStartedAt: base.addingTimeInterval(0.8)
        )
        attempt.domainLookupStartedAt = base.addingTimeInterval(0.80)
        attempt.domainLookupCompletedAt = base.addingTimeInterval(0.82)
        attempt.connectionStartedAt = base.addingTimeInterval(0.82)
        attempt.secureConnectionStartedAt = base.addingTimeInterval(0.86)
        attempt.secureConnectionCompletedAt = base.addingTimeInterval(0.94)
        attempt.connectionCompletedAt = base.addingTimeInterval(0.94)
        attempt.requestUploadStartedAt = base.addingTimeInterval(0.95)
        attempt.requestUploadCompletedAt = base.addingTimeInterval(0.97)
        attempt.firstResponseByteAt = base.addingTimeInterval(1.27)
        attempt.networkResponseCompletedAt = base.addingTimeInterval(1.77)

        let record = HistoryRecord(
            id: recordID,
            date: base,
            transcriptText: "hello",
            pipelineTiming: HistoryPipelineTiming(
                recordingStoppedAt: base,
                audioFileReadyAt: base.addingTimeInterval(0.1),
                transcriptionStartedAt: base,
                transcriptionCompletedAt: base.addingTimeInterval(0.8),
                realtimeSessionStartedAt: base.addingTimeInterval(-5.0),
                realtimeConnectionReadyAt: base.addingTimeInterval(-3.8),
                realtimeFirstAudioSubmittedAt: base.addingTimeInterval(-4.8),
                realtimeFinalResultReceivedAt: base.addingTimeInterval(0.79),
                realtimeFinishStartedAt: base,
                realtimeFinishCompletedAt: base.addingTimeInterval(0.8),
                realtimeTransport: transport,
                llmProcessingStartedAt: base.addingTimeInterval(0.8),
                llmProcessingCompletedAt: base.addingTimeInterval(1.8),
                llmRequestAttempts: [attempt]
            )
        )
        let viewModel = makeViewModel(
            records: [record],
            audioPreviewPlayer: FakeHistoryAudioPreviewPlayer(playResult: true)
        )
        waitForHistoryRecord(recordID, in: viewModel)

        let timeline = viewModel.displayedHistory.first?.pipelineTimeline
        let laneIDs = Set(timeline?.lanes.map(\.id) ?? [])
        XCTAssertTrue(laneIDs.contains("asr-dns"))
        XCTAssertTrue(laneIDs.contains("asr-tls"))
        XCTAssertTrue(laneIDs.contains("asr-route"))
        XCTAssertTrue(laneIDs.contains("asr-server-selection"))
        XCTAssertTrue(laneIDs.contains("asr-socket-preparation"))
        XCTAssertTrue(laneIDs.contains("asr-network-queue"))
        XCTAssertTrue(laneIDs.contains("asr-first-audio-queue"))
        XCTAssertTrue(laneIDs.contains("asr-upload"))
        XCTAssertTrue(laneIDs.contains("asr-streaming"))
        XCTAssertTrue(laneIDs.contains("asr-final-wait"))
        XCTAssertTrue(laneIDs.contains("asr-cleanup"))
        XCTAssertTrue(laneIDs.contains("llm-request-\(attempt.id.uuidString)-upload"))
        XCTAssertTrue(laneIDs.contains("llm-request-\(attempt.id.uuidString)-wait"))
        XCTAssertTrue(laneIDs.contains("llm-request-\(attempt.id.uuidString)-download"))
        XCTAssertEqual(timeline?.lanes.first(where: { $0.id == "asr-first-audio-queue" })?.isSlowest, true)
        XCTAssertEqual(timeline?.lanes.first(where: { $0.id == "asr-streaming" })?.isSlowest, false)
        XCTAssertEqual(timeline?.lanes.first(where: { $0.id == "llm" })?.isSlowest, false)
        XCTAssertEqual(timeline?.lanes.first(where: { $0.id == "realtime" })?.offsetFraction ?? -1, 0, accuracy: 0.001)
        XCTAssertEqual(
            timeline?.lanes.first(where: { $0.id == "asr-dns" })?.offsetFraction ?? -1,
            1.0 / 6.8,
            accuracy: 0.001
        )
        XCTAssertEqual(timeline?.totalDurationText, "1.80 s")
        XCTAssertEqual(timeline?.timelineSpanDurationText, "6.80 s")
        XCTAssertEqual(
            timeline?.keyMetrics.first(where: { $0.id == "asr-first-audio-queue" })?.value,
            "1.00 s"
        )
        XCTAssertEqual(timeline?.requestDetails.map(\.id), ["asr-request", "llm-request-\(attempt.id.uuidString)"])
        XCTAssertFalse(timeline?.keyMetrics.contains(where: { $0.id.hasSuffix("-endpoint") }) ?? true)
        XCTAssertFalse(timeline?.keyMetrics.contains(where: { $0.id.hasSuffix("-connection-metadata") }) ?? true)
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
