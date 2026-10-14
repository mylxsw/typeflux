import Foundation

/// What the settings card and the management sheet say about content search right now.
struct SemanticFileSearchStatus: Equatable {
    enum Tone: Equatable { case off, busy, ready, warning }
    enum Progress: Equatable { case download(Double), indexing }
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
            return .init(tone: .busy, text: L("semantic.indexing", files), progress: .indexing)
        case .paused:
            return .init(tone: .busy, text: L("semantic.paused", files))
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
                  files: files, chunks: chunks, blocked: blocked))
    }
}
