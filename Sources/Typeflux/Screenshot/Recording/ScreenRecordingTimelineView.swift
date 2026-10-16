import SwiftUI

struct ScreenRecordingTimelineView: View {
    @ObservedObject var model: ScreenRecordingCoordinator
    var body: some View {
        GeometryReader { geometry in
            let interaction = model.playback.interactionID
            let width = geometry.size.width
            let start = ScreenRecordingLayout.position(time: model.trimStart, width: width, duration: model.duration)
            let end = ScreenRecordingLayout.position(time: model.trimEnd, width: width, duration: model.duration)
            ZStack(alignment: .topLeading) {
                HStack(spacing: 0) {
                    ForEach(0 ..< 5) { tick in
                        Text(ScreenRecordingCoordinator.timeLabel(model.duration * Double(tick) / 4))
                            .font(.system(size: 10, design: .monospaced)).foregroundStyle(StudioTheme.textTertiary)
                        if tick < 4 {
                            Spacer(minLength: 0)
                        }
                    }
                }.frame(width: width, height: 16)
                HStack(spacing: 1) {
                    ForEach(Array(model.media.thumbnails.enumerated()), id: \.offset) { _, image in
                        Image(decorative: image, scale: 1).resizable().scaledToFill()
                            .frame(width: (width - 9) / 10, height: 52).clipped()
                    }
                }.frame(width: width, height: 52, alignment: .leading).background(.black)
                    .clipShape(RoundedRectangle(cornerRadius: 7)).offset(y: 20)
                waveform.frame(width: width, height: 24).background(AskTheme.controlSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 6)).offset(y: 76)
                Rectangle().fill(Color.black.opacity(0.55)).frame(width: max(0, start), height: 80).offset(y: 20)
                Rectangle().fill(Color.black.opacity(0.55)).frame(width: max(0, width - end), height: 80).offset(
                    x: end,
                    y: 20
                )
                Rectangle().stroke(AskTheme.accent, lineWidth: 2).frame(width: max(0, end - start), height: 82).offset(
                    x: start,
                    y: 18
                )
                Rectangle().fill(.clear).contentShape(Rectangle()).frame(width: width, height: 104)
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("recording.timeline"))
                        .onChanged { value in
                            guard model.playback.interactionID == interaction else { return }
                            model.seek(ScreenRecordingLayout.time(
                                at: value.location.x,
                                width: width,
                                duration: model.duration
                            ))
                        })
                handle(start: true, width: width).offset(x: max(0, start - 6), y: 18)
                handle(start: false, width: width).offset(x: min(width - 12, end - 6), y: 18)
                let head = ScreenRecordingLayout.position(
                    time: model.currentTime,
                    width: width,
                    duration: model.duration
                )
                Rectangle().fill(.white).frame(width: 2, height: 90).offset(x: min(width - 2, head), y: 12)
                    .allowsHitTesting(false)
                RoundedRectangle(cornerRadius: 3).fill(.white).frame(width: 12, height: 12).offset(
                    x: min(width - 12, max(0, head - 6)),
                    y: 10
                ).allowsHitTesting(false)
            }.coordinateSpace(name: "recording.timeline").opacity(model.state == .exporting ? 0.5 : 1)
                .allowsHitTesting(model.state == .preview)
        }
    }

    private var waveform: some View {
        ZStack {
            if model.options.format == .gif || model.media.waveform.isEmpty {
                Text(L(model.options.format == .gif ? "recording.gifSilent" : "recording.noAudioTrack"))
                    .font(.system(size: 11)).foregroundStyle(StudioTheme.textTertiary)
            } else {
                Canvas { context, size in
                    let count = model.media.waveform.count
                    for (index, level) in model.media.waveform.enumerated() {
                        let height = max(2, CGFloat(sqrt(level)) * size.height * 0.9)
                        let rect = CGRect(
                            x: CGFloat(index) / CGFloat(count) * size.width,
                            y: (size.height - height) / 2,
                            width: max(1, size.width / CGFloat(count) - 1),
                            height: height
                        )
                        context.fill(
                            Path(roundedRect: rect, cornerRadius: 1),
                            with: .color(AskTheme.accent.opacity(0.55))
                        )
                    }
                }
            }
        }
    }

    private func handle(start: Bool, width: CGFloat) -> some View {
        let interaction = model.playback.interactionID
        return RoundedRectangle(cornerRadius: 6).fill(AskTheme.accent).frame(width: 12, height: 84)
            .overlay(Capsule().fill(.white.opacity(0.85)).frame(width: 2, height: 18))
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("recording.timeline")).onChanged { value in
                guard model.playback.interactionID == interaction else { return }
                let time = ScreenRecordingLayout.time(at: value.location.x, width: width, duration: model.duration)
                if start {
                    model.setTrimStart(time)
                } else {
                    model.setTrimEnd(time)
                }
            })
            .accessibilityElement().accessibilityLabel(L(start ? "recording.from" : "recording.to"))
            .accessibilityValue(ScreenRecordingLayout.preciseTime(start ? model.trimStart : model.trimEnd))
            .accessibilityAdjustableAction { direction in
                let delta = direction == .increment ? 0.1 : -0.1
                if start {
                    model.setTrimStart(model.trimStart + delta)
                } else {
                    model.setTrimEnd(model.trimEnd + delta)
                }
            }
    }
}
