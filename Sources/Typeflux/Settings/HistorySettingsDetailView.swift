import SwiftUI

struct HistorySettingsDetailView: View {
    let record: HistoryPresentationRecord
    @ObservedObject var viewModel: StudioViewModel

    var body: some View {
        TypefluxForm {
            TypefluxFormSection(L("history.detail.title")) {
                LabeledContent(L("history.table.timestamp")) { Text(record.date.formatted(
                    date: .abbreviated,
                    time: .shortened
                )) }
                LabeledContent(L("history.table.sourceFile"), value: record.sourceName)
                Menu(L("history.action.more")) { HistorySettingsActions(record: record, viewModel: viewModel) }
                    .accessibilityIdentifier("history.detail.actions")
            }
            TypefluxFormSection(L("history.detail.audioPath")) {
                Text(record.audioFilePath.flatMap { $0.isEmpty ? nil : $0 } ?? L("history.detail.noAudioFile"))
                    .textSelection(.enabled).font(.subheadline)
                if let audioPath = record.audioFilePath, !audioPath.isEmpty {
                    TypefluxButton(viewModel.playingAudioRecordID == record.id
                        ? L("history.action.stopAudio") : L("history.action.playAudio")) {
                            viewModel.playAudio(id: record.id)
                        }
                }
            }
            textSection("history.detail.rawTranscript", content: record.transcriptText)
            textSection("history.detail.personaPrompt", content: record.personaPrompt)
            textSection("history.detail.personaResult", content: record.personaResultText)
            if let content = record.openCCResultText {
                TypefluxFormSection(openCCTitle) { Text(content).textSelection(.enabled) }
            }
            textSection("history.detail.postProcessedResult", content: record.postProcessedText)
            textSection("history.detail.selectionOriginal", content: record.selectionOriginalText)
            textSection("history.detail.selectionEdited", content: record.selectionEditedText)
            if let timeline = record.pipelineTimeline {
                HistoryPipelineTimelineView(title: L("history.detail.pipelineStats"), timeline: timeline)
            }
            textSection("history.detail.error", content: record.errorMessage, isError: true)
            textSection("history.detail.applyMessage", content: record.applyMessage)
        }
        .accessibilityIdentifier("history.detail")
    }

    private var openCCTitle: String {
        let key = "settings.output.opencc.config."
        let known = ["s2twp", "s2tw", "s2hk", "t2s"]
        guard let config = record.openCCConfig, known.contains(config) else { return L("history.detail.openCCResult") }
        return "\(L("history.detail.openCCResult")) (\(L(key + config)))"
    }

    @ViewBuilder
    private func textSection(_ key: String, content: String?, isError: Bool = false) -> some View {
        if let content, !content.isEmpty {
            TypefluxFormSection(L(key)) {
                Text(content).textSelection(.enabled)
                    .foregroundStyle(isError ? TypefluxColor.danger.color : TypefluxColor.label.color)
            }
        }
    }
}
