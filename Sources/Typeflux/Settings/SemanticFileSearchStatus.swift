import Foundation

/// What the inline content-index row says about content search right now.
struct SemanticFileSearchStatus: Equatable {
    enum Tone: Equatable { case off, busy, ready, warning }
    enum Progress: Equatable { case download(Double), scanning(Int, Int), indexing(Int, Int) }
    enum Action: Equatable { case none, download, retryDownload, retry, permission }

    var tone: Tone
    var text: String
    var progress: Progress?
    var action: Action = .none

    struct Input: Equatable {
        var phase: SemanticFileSearchService.Phase
        var enabled: Bool
        var filesEnabled: Bool
        var modelReady: Bool
        var files = 0
        var chunks = 0
        var blocked: [String] = []
        var indexProgress: SemanticFileIndexer.Summary?
    }

    // One branch per lifecycle phase keeps the copy beside the state it describes.
    // swiftlint:disable:next cyclomatic_complexity
    static func of(_ input: Input) -> Self {
        guard input.enabled else { return .init(tone: .off, text: L("semantic.offDetail")) }
        guard input.filesEnabled else { return .init(tone: .warning, text: L("semantic.filesOff")) }
        let files = input.files.formatted()
        switch input.phase {
        case .off, .preparing:
            return .init(tone: .busy, text: L("semantic.preparing"))
        case .modelRequired:
            return .init(tone: .warning, text: L("semantic.modelRequired"), action: .download)
        case let .downloading(fraction):
            return .init(tone: .busy, text: L("semantic.downloading"), progress: .download(fraction))
        case .indexing:
            return .init(tone: .busy, text: L("semantic.indexing", files),
                         progress: indexProgress(input.indexProgress))
        case .paused:
            return .init(tone: .busy, text: L("semantic.paused", files),
                         progress: input.indexProgress.map { indexProgress($0) })
        case .ready where !input.blocked.isEmpty:
            return .init(tone: .warning, text: L("semantic.permissionNeeded"), action: .permission)
        case .ready:
            return .init(tone: .ready, text: L("semantic.ready", files, input.chunks.formatted()))
        case .failed where input.modelReady:
            return .init(tone: .warning, text: L("semantic.failed.index"), action: .retry)
        case .failed:
            return .init(tone: .warning, text: L("semantic.failed.download"), action: .retryDownload)
        }
    }

    private static func indexProgress(_ summary: SemanticFileIndexer.Summary?) -> Progress {
        guard let summary, let total = summary.total else {
            return .scanning(summary?.scanned ?? 0, summary?.discovered ?? 0)
        }
        return .indexing(summary.processed, total)
    }

    /// "120 MB / 310 MB" for a download in progress.
    static func downloaded(_ fraction: Double, total: Int64 = SemanticModel.bytes) -> String {
        let received = Int64((Double(total) * min(1, max(0, fraction))).rounded())
        return L("semantic.downloadBytes", Self.size(received), Self.size(total))
    }

    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

extension SemanticFileSearchService {
    func status(filesEnabled: Bool? = nil) -> SemanticFileSearchStatus {
        .of(.init(phase: phase, enabled: supported && preferences.enabled,
                  filesEnabled: filesEnabled ?? settings.askQuickFileSearchEnabled, modelReady: modelReady,
                  files: files, chunks: chunks, blocked: blocked, indexProgress: indexProgress))
    }
}
