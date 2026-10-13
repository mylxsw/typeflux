import SwiftUI

struct HistorySettingsActions: View {
    let record: HistoryPresentationRecord
    @ObservedObject var viewModel: StudioViewModel

    var body: some View {
        Button(L("history.action.copyResult"), systemImage: "doc.on.doc") {
            viewModel.copyHistoryResult(id: record.id)
        }.disabled(!record.hasTranscriptToCopy)
        Button(L("history.action.copyTranscript"), systemImage: "doc.on.doc") {
            viewModel.copyTranscript(id: record.id)
        }.disabled(record.transcriptText?.isEmpty ?? true)
        Divider()
        Button(L("common.retry"), systemImage: "arrow.clockwise") {
            viewModel.retryHistoryRecord(id: record.id)
        }.disabled(!record.canRetry)
        Button(L("history.action.downloadAudio"), systemImage: "arrow.down.circle") {
            viewModel.downloadAudio(id: record.id)
        }.disabled(record.audioFilePath?.isEmpty ?? true)
        Divider()
        Button(L("history.action.deleteTranscript"), systemImage: "trash", role: .destructive) {
            viewModel.deleteHistoryRecord(id: record.id)
        }
    }
}
