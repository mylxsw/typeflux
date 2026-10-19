import SwiftUI

/// In and out points with "set to playhead" buttons, plus the kept and exported lengths.
struct ScreenRecordingTrimBar: View {
    @ObservedObject var model: ScreenRecordingCoordinator
    var showsShortcutHints = false

    var body: some View {
        let trimmed = model.trimStart > 0.001 || model.trimEnd < model.duration - 0.001
        return HStack(spacing: 8) {
            trimField(L("recording.inPoint"), time: model.trimStart, key: "I",
                      jump: { model.seek(model.trimStart) }, set: { model.setTrimStart(model.currentTime) })
            trimField(L("recording.outPoint"), time: model.trimEnd, key: "O",
                      jump: { model.seek(model.trimEnd) }, set: { model.setTrimEnd(model.currentTime) })
            Group {
                Text(L("recording.keptSeconds", model.selectionDuration)).fontWeight(.semibold)
                    + Text(" " + (trimmed ? L("recording.ofTotal", model.duration) : L("recording.fullLength")))
                    .foregroundColor(StudioTheme.textSecondary)
                if model.edit.rate != 1 {
                    Text(L("recording.exportsAs", model.outputDuration, ScreenRecordingEdit.rateTitle(model.edit.rate)))
                        .foregroundStyle(StudioTheme.textSecondary)
                }
            }
            .font(.system(size: 12)).monospacedDigit().lineLimit(1)
            if trimmed {
                Button(L("recording.resetTrim"), action: model.resetTrim)
                    .buttonStyle(AskWorkflowActionStyle(kind: .ghost, small: true))
            }
            Spacer(minLength: 0)
        }
        .disabled(model.state != .preview)
    }

    private func trimField(_ title: String, time: Double, key: String,
                           jump: @escaping () -> Void, set: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.system(size: 11.5)).foregroundStyle(StudioTheme.textTertiary)
            Button(action: jump) {
                Text(ScreenRecordingLayout.preciseTime(time))
                    .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
            }
            .buttonStyle(.plain)
            Button(action: set) {
                HStack(spacing: 4) {
                    Text(L("recording.setToPlayhead"))
                    Text(key).font(.system(size: 10.5, weight: .semibold)).padding(.horizontal, 4)
                        .background(AskTheme.controlSurface, in: RoundedRectangle(cornerRadius: 4))
                }
                .font(.system(size: 11)).foregroundStyle(StudioTheme.textSecondary)
            }
            .buttonStyle(.plain).help(L(key == "I" ? "recording.key.in" : "recording.key.out"))
            .modifier(EditorShortcutHint(key: key, visible: showsShortcutHints && model.state == .preview))
        }
        .padding(.leading, 9).padding(.trailing, 6).frame(height: 28)
        .background(AskTheme.controlSurface.opacity(0.7), in: RoundedRectangle(cornerRadius: 7))
    }
}

/// Shown when a GIF would exceed its length limit: speed it up, cut it, or save MP4 instead.
struct ScreenRecordingGIFLimitBanner: View {
    @ObservedObject var model: ScreenRecordingCoordinator

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(StudioTheme.warning)
            Text(L("recording.gifTooLong")).fontWeight(.semibold)
                + Text(" · " + L("recording.gifTooLongDetail", model.outputDuration))
            Spacer(minLength: 4)
            if let rate = model.edit.fittingGIFRate(selection: model.selectionDuration) {
                Button(L("recording.fitSpeed", ScreenRecordingEdit.rateTitle(rate), model.selectionDuration / rate),
                       action: model.fitGIFBySpeed)
            }
            Button(L("recording.keep30"), action: model.keepFirstGIFSegment)
            Button(L("recording.switchMP4")) { model.options.format = .mp4 }
        }
        .buttonStyle(ModelActionStyle()).font(.system(size: 12)).lineLimit(1).padding(8)
        .background(AskTheme.warningSoft, in: RoundedRectangle(cornerRadius: 8))
    }
}
