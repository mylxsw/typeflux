import AVKit
import SwiftUI

struct ScreenRecordingPreviewView: View {
    @ObservedObject private var localization = AppLocalization.shared
    @ObservedObject var model: ScreenRecordingCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VideoPlayer(player: model.player).frame(height: 240)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            ScreenRecordingSection(title: L("recording.trim"), symbol: "scissors") {
                HStack {
                    Text(L("recording.selectedDuration", model.selectionDuration))
                        .monospacedDigit().foregroundStyle(StudioTheme.textSecondary)
                    Spacer()
                    Button(L("recording.resetTrim")) { model.resetTrim() }
                }
                trimRow(title: L("recording.from"), value: Binding(get: { model.trimStart }, set: model.setTrimStart))
                trimRow(title: L("recording.to"), value: Binding(get: { model.trimEnd }, set: model.setTrimEnd))
                Picker(L("recording.format"), selection: $model.options.format) {
                    Text(L("recording.mp4Choice")).tag(ScreenRecordingFormat.mp4)
                    Text(L("recording.gifChoice")).tag(ScreenRecordingFormat.gif)
                }.pickerStyle(.segmented).labelsHidden()
                if model.options.format == .gif {
                    Text(L("recording.gifExportHint")).font(.caption).foregroundStyle(StudioTheme.textSecondary)
                }
                if !model.trimIsValid {
                    Label(L("recording.error.invalidRange"), systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(StudioTheme.danger)
                }
            }
            .disabled(model.state == .exporting)
        }
    }

    private func trimRow(title: String, value: Binding<Double>) -> some View {
        HStack(spacing: 10) {
            Text(title).frame(width: 40, alignment: .leading)
            Slider(value: value, in: 0 ... max(0.01, model.duration)).accessibilityLabel(title)
            TextField(title, value: value, format: .number.precision(.fractionLength(2)))
                .textFieldStyle(.roundedBorder).frame(width: 70).accessibilityLabel(title)
            Text(L("recording.secondsUnit")).foregroundStyle(StudioTheme.textSecondary)
        }
    }
}
