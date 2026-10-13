import Foundation

enum HistorySettingsFilter: String, CaseIterable, Identifiable {
    case all, failures, audio, text

    var id: String {
        rawValue
    }

    var title: String {
        L("history.filter." + rawValue)
    }

    func matches(_ record: HistoryRecord) -> Bool {
        switch self {
        case .all: true
        case .failures: record.hasFailure
        case .audio: !(record.audioFilePath?.isEmpty ?? true)
        case .text: !(record.finalText?.isEmpty ?? true)
        }
    }
}
