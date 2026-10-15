import Foundation
import Testing
@testable import Typeflux

@Suite("Semantic settings status", .serialized, .exclusiveUIState)
@MainActor
struct SemanticFileSearchStatusTests {
    typealias Status = SemanticFileSearchStatus

    func status(_ phase: SemanticFileSearchService.Phase, enabled: Bool = true, filesEnabled: Bool = true,
                modelReady: Bool = true, blocked: [String] = [],
                indexProgress: SemanticFileIndexer.Summary? = nil) -> Status {
        .of(.init(phase: phase, enabled: enabled, filesEnabled: filesEnabled, modelReady: modelReady,
                  files: 1248, blocked: blocked, indexProgress: indexProgress))
    }

    @Test func `off and suspended states explain themselves without actions`() {
        #expect(status(.ready, enabled: false) == .init(tone: .off, text: L("semantic.offDetail")))
        #expect(status(.ready, filesEnabled: false) == .init(tone: .warning, text: L("semantic.filesOff")))
        #expect(status(.off).tone == .busy && status(.preparing).text == L("semantic.preparing"))
    }

    @Test func `work in progress carries its progress`() {
        let download = status(.downloading(0.4), modelReady: false)
        #expect(download == .init(tone: .busy, text: L("semantic.downloading"), progress: .download(0.4)))
        let indexing = status(.indexing)
        #expect(indexing.progress == .scanning(0, 0) && indexing.text == L("semantic.indexing", 1248.formatted()))
        var measured = SemanticFileIndexer.Summary()
        measured.scanned = 3_000; measured.discovered = 220
        #expect(status(.indexing, indexProgress: measured).progress == .scanning(3_000, 220))
        measured.total = 220; measured.processed = 55
        #expect(status(.indexing, indexProgress: measured).progress == .indexing(55, 220))
        measured.waitingForIdle = true
        let waiting = status(.indexing, indexProgress: measured)
        #expect(waiting.isPassiveWaiting && waiting.progress == nil)
        #expect(!status(.paused, indexProgress: measured).isPassiveWaiting)
        #expect(status(.paused, indexProgress: measured).progress == .indexing(55, 220))
        #expect(status(.paused) == .init(tone: .busy, text: L("semantic.paused", 1248.formatted())))
    }

    @Test func `finished and failed states offer the matching recovery`() {
        #expect(status(.ready) == .init(tone: .ready, text: L("semantic.ready")))
        #expect(status(.ready, blocked: ["/Users/me/Documents"]).action == .permission)
        #expect(status(.modelRequired, modelReady: false).action == .download)
        #expect(status(.failed, modelReady: false) == .init(tone: .warning, text: L("semantic.failed.download"),
                                                            action: .retryDownload))
        #expect(status(.failed) == .init(tone: .warning, text: L("semantic.failed.index"), action: .retry))
    }

    @Test func `download size is clamped and formatted`() {
        let total: Int64 = 300_000_000
        #expect(Status.downloaded(0.5, total: total) == L("semantic.downloadBytes", Status.size(150_000_000),
                                                           Status.size(total)))
        #expect(Status.downloaded(2, total: total) == L("semantic.downloadBytes", Status.size(total),
                                                         Status.size(total)))
        #expect(Status.downloaded(-1, total: total).hasPrefix(Status.size(0)))
    }
}
