import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@Suite(.serialized, .exclusiveUIState)
@MainActor
struct StudioHistoryRowLayoutTests {
    private func record() -> HistoryPresentationRecord {
        HistoryPresentationRecord(
            id: UUID(),
            date: Date(timeIntervalSince1970: 0),
            timestampText: "19:32",
            sourceName: "Test",
            previewText: Array(
                repeating: "A stable transcription preview",
                count: 6
            ).joined(separator: " "),
            audioFilePath: "/tmp/test.wav",
            transcriptText: "A stable transcription preview",
            personaPrompt: nil,
            personaResultText: nil,
            openCCResultText: nil,
            openCCConfig: nil,
            postProcessedText: nil,
            selectionOriginalText: nil,
            selectionEditedText: nil,
            pipelineTimeline: nil,
            errorMessage: nil,
            applyMessage: nil,
            hasTranscriptToCopy: true,
            canRetry: true,
            hasFailure: false,
            failureMessage: nil,
            accentName: "Test",
            accentColorName: "blue"
        )
    }

    @Test func `long preview keeps room for text when all actions are available`() async throws {
        try await SettingsBehaviorTestSupport.withFixture { _ in
            let sample = record()
            let row = StudioHistoryRow(record: sample, onCopyResult: {}, onCopyTranscript: {},
                                       onDownloadAudio: {}, onPlayAudio: {}, isAudioPlaying: false, onDelete: {},
                                       onRetry: {})
            // ViewThatFits needs a real proposed width; its unconstrained fittingSize
            // reports the fallback stack's ideal size rather than the displayed row.
            try await SettingsBehaviorTestSupport.withWindow(row, width: 1000, height: 240) { _, host in
                let preview = try #require(SettingsBehaviorTestSupport.elements(in: host)
                    .first { $0.text == sample.previewText })
                #expect(preview.frame.width > 700, "Actions leave most of the row available to the preview")
                #expect(preview.frame.height <= 42, "Collapsed previews occupy at most two lines")
                let timestamp = try #require(SettingsBehaviorTestSupport.elements(in: host)
                    .first { $0.text == sample.timestampText })
                #expect(abs(timestamp.frame.maxY - preview.frame.maxY) < 5,
                        "Wide windows keep the time and preview on the same row: time=\(timestamp.frame), preview=\(preview.frame)")
            }
        }
    }

    @Test func `narrow rows keep expansion and transcript copy reachable`() async throws {
        try await SettingsBehaviorTestSupport.withFixture { _ in
            var copied = 0
            let sample = record()
            let row = StudioHistoryRow(record: sample, onCopyResult: {}, onCopyTranscript: { copied += 1 },
                                       onDownloadAudio: {}, onPlayAudio: {}, isAudioPlaying: false, onDelete: {},
                                       onRetry: {})
            try await SettingsBehaviorTestSupport.withWindow(row, width: 320, height: 700) { window, host in
                let bounds = window.convertToScreen(host.convert(host.bounds, to: nil))
                let preview = try #require(SettingsBehaviorTestSupport.elements(in: host)
                    .first { $0.text == sample.previewText })
                #expect(preview.frame.height <= 42)
                #expect(preview.frame.minX >= bounds.minX && preview.frame.maxX <= bounds.maxX)
                let expand = try SettingsBehaviorTestSupport.button(L("common.expand"), in: host)
                #expect(expand.frame.maxX <= bounds.maxX)
                try expand.press()
                try await SettingsBehaviorTestSupport.wait {
                    SettingsBehaviorTestSupport.contains(L("history.detail.rawTranscript"), in: host)
                }
                try SettingsBehaviorTestSupport.button(L("history.action.copyTranscript"), in: host).press()
                #expect(copied == 1)
                try SettingsBehaviorTestSupport.button(L("common.collapse"), in: host).press()
                try await SettingsBehaviorTestSupport.wait {
                    !SettingsBehaviorTestSupport.contains(L("history.detail.rawTranscript"), in: host)
                }
            }
        }
    }
}
