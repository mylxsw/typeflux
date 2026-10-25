import SwiftUI

struct ScreenRecordingTimelineView: View {
    @ObservedObject var model: ScreenRecordingCoordinator
    @State private var dragging: Bool?
    @State private var hover: CGFloat?

    static let rulerHeight: CGFloat = 18
    static let stripHeight: CGFloat = 52
    static let laneHeight: CGFloat = 24
    static let laneSpacing: CGFloat = 4

    /// Lanes: one per audio track; a single notice lane while the timeline audio is loading or unreadable.
    static func laneCount(_ model: ScreenRecordingCoordinator) -> Int {
        if !model.edit.tracks.isEmpty { return model.edit.tracks.count }
        switch model.media.audio {
        case .absent: return 0
        case nil, .available, .unavailable: return model.options.format == .gif ? 0 : 1
        }
    }

    static func height(_ model: ScreenRecordingCoordinator) -> CGFloat {
        rulerHeight + stripHeight + CGFloat(laneCount(model)) * (laneHeight + laneSpacing)
    }

    /// Picks a label step that keeps ruler labels at least ~70 points apart.
    static func rulerStep(width: CGFloat, duration: Double) -> Double {
        guard width > 0, duration > 0 else { return 1 }
        return [0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600].first { Double(width) / (duration / $0) >= 70 } ?? 600
    }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let trackHeight = geometry.size.height - Self.rulerHeight
            let start = ScreenRecordingLayout.position(time: model.trimStart, width: width, duration: model.duration)
            let end = ScreenRecordingLayout.position(time: model.trimEnd, width: width, duration: model.duration)
            let head = ScreenRecordingLayout.position(time: model.currentTime, width: width, duration: model.duration)
            let overflow = model.gifTooLong ? ScreenRecordingLayout.position(
                time: model.edit.gifSourceEnd(from: model.trimStart), width: width, duration: model.duration
            ) : nil
            ZStack(alignment: .topLeading) {
                ruler(width: width)
                VStack(spacing: Self.laneSpacing) {
                    strip(width: width)
                    lanes(width: width)
                }
                .offset(y: Self.rulerHeight)
                Rectangle().fill(Color.clear).contentShape(Rectangle())
                    .frame(width: width, height: geometry.size.height)
                    .gesture(seekGesture(width: width))
                Group {
                    Rectangle().fill(Color.black.opacity(0.55)).frame(width: max(0, start), height: trackHeight)
                    Rectangle().fill(Color.black.opacity(0.55)).frame(width: max(0, width - end), height: trackHeight)
                        .offset(x: end)
                    if let overflow, overflow < end {
                        ScreenRecordingOverflowStripes().frame(width: end - overflow, height: trackHeight)
                            .offset(x: overflow)
                    }
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(model.gifTooLong ? StudioTheme.warning : AskTheme.accent, lineWidth: 2)
                        .frame(width: max(0, end - start), height: trackHeight + 2).offset(x: start, y: -1)
                }
                .offset(y: Self.rulerHeight).allowsHitTesting(false)
                handle(start: true, width: width, height: trackHeight)
                    .offset(x: max(0, start - 12), y: Self.rulerHeight - 1)
                handle(start: false, width: width, height: trackHeight)
                    .offset(x: min(width - 12, end), y: Self.rulerHeight - 1)
                if let hover, dragging == nil {
                    Rectangle().fill(StudioTheme.textTertiary).frame(width: 1, height: geometry.size.height)
                        .offset(x: hover).allowsHitTesting(false)
                    bubble(ScreenRecordingLayout.preciseTime(
                        ScreenRecordingLayout.time(at: hover, width: width, duration: model.duration)
                    ))
                    .position(x: min(max(hover, 30), width - 30), y: -12).allowsHitTesting(false)
                }
                playhead(height: geometry.size.height).offset(x: min(width - 1, max(0, head)) - 5)
                    .allowsHitTesting(false)
            }
            .coordinateSpace(name: "recording.timeline")
            .onContinuousHover { phase in
                if case let .active(point) = phase, point.x >= 0, point.x <= width {
                    hover = point.x
                } else {
                    hover = nil
                }
            }
            .opacity(model.state == .exporting ? 0.5 : 1)
            .allowsHitTesting(model.state == .preview)
        }
        .frame(height: Self.height(model))
    }

    private func ruler(width: CGFloat) -> some View {
        let step = Self.rulerStep(width: width, duration: model.duration)
        let marks = model.duration > 0 ? Array(stride(from: 0, through: model.duration, by: step / 2)) : []
        return ZStack(alignment: .topLeading) {
            ForEach(marks.indices, id: \.self) { index in
                let value = marks[index], major = index.isMultiple(of: 2)
                let tick = ScreenRecordingLayout.position(time: value, width: width, duration: model.duration)
                Rectangle().fill(StudioTheme.textTertiary.opacity(0.6)).frame(width: 1, height: major ? 5 : 3)
                    .offset(x: tick, y: Self.rulerHeight - (major ? 5 : 3) - 2)
                if major, tick > 18, tick < width - 30 {
                    Text(step < 1 ? ScreenRecordingLayout.preciseTime(value)
                        : ScreenRecordingCoordinator.timeLabel(value))
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(StudioTheme.textTertiary)
                        .fixedSize().position(x: tick, y: 5)
                }
            }
        }
        .frame(width: width, height: Self.rulerHeight, alignment: .topLeading)
    }

    private func strip(width: CGFloat) -> some View {
        HStack(spacing: 1) {
            ForEach(Array(model.media.thumbnails.enumerated()), id: \.offset) { _, image in
                Image(decorative: image, scale: 1).resizable().scaledToFill()
                    .frame(width: max(0, (width - 9) / 10), height: Self.stripHeight).clipped()
            }
        }
        .frame(width: width, height: Self.stripHeight, alignment: .leading).background(.black)
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }

    @ViewBuilder private func lanes(width: CGFloat) -> some View {
        let gif = model.options.format == .gif
        if model.edit.tracks.isEmpty {
            if Self.laneCount(model) == 1 {
                Text(L(model.media.audioNoticeKey)).font(.system(size: 11)).foregroundStyle(StudioTheme.textTertiary)
                    .frame(width: width, height: Self.laneHeight).background(AskTheme.controlSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        } else {
            ForEach(model.edit.tracks) { track in
                ZStack(alignment: .leading) {
                    ScreenRecordingWaveform(levels: track.waveform, scale: track.volume)
                        .opacity(gif ? 0.2 : track.included ? 1 : 0.18)
                        .saturation(gif || !track.included ? 0 : 1)
                    if gif {
                        if track.id == model.edit.tracks.first?.id {
                            Label(L("recording.gifSilent"), systemImage: "speaker.slash")
                                .font(.system(size: 11)).foregroundStyle(StudioTheme.textSecondary)
                                .frame(maxWidth: .infinity)
                        }
                    } else {
                        trackTag(track).padding(.leading, 16)
                    }
                }
                .frame(width: width, height: Self.laneHeight).background(AskTheme.controlSurface)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    private func trackTag(_ track: ScreenRecordingAudioTrack) -> some View {
        Button { model.setTrack(track.id, included: !track.included) } label: {
            HStack(spacing: 5) {
                Image(systemName: track.included ? "checkmark.square.fill" : "square")
                    .foregroundStyle(track.included ? AskTheme.accent : StudioTheme.textSecondary)
                Text(track.title).strikethrough(!track.included)
            }
            .font(.system(size: 11, weight: .medium)).padding(.horizontal, 6).frame(height: 18)
            .styledGlassBackground(in: RoundedRectangle(cornerRadius: 5), cornerRadius: 5)
        }
        .buttonStyle(.plain).foregroundStyle(StudioTheme.textPrimary)
        .accessibilityLabel(L("recording.includeTrack", track.title))
        .accessibilityAddTraits(track.included ? .isSelected : [])
        .accessibilityIdentifier("recording.track.\(track.id)")
    }

    private func seekGesture(width: CGFloat) -> some Gesture {
        let interaction = model.playback.interactionID
        return DragGesture(minimumDistance: 0, coordinateSpace: .named("recording.timeline")).onChanged { value in
            guard model.playback.interactionID == interaction else { return }
            model.seek(ScreenRecordingLayout.time(at: value.location.x, width: width, duration: model.duration))
        }
    }

    private func handle(start: Bool, width: CGFloat, height: CGFloat) -> some View {
        let interaction = model.playback.interactionID
        let color = model.gifTooLong ? StudioTheme.warning : AskTheme.accent
        return RoundedRectangle(cornerRadius: 5)
        .fill(color).frame(width: 12, height: height + 2)
        .overlay(Capsule().fill(.white.opacity(0.9)).frame(width: 2, height: 18))
        .overlay(alignment: .top) {
            if dragging == start {
                bubble(ScreenRecordingLayout.preciseTime(start ? model.trimStart : model.trimEnd))
                    .fixedSize().offset(y: -26)
            }
        }
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("recording.timeline")).onChanged { value in
            guard model.playback.interactionID == interaction else { return }
            dragging = start
            let time = ScreenRecordingLayout.time(at: value.location.x, width: width, duration: model.duration)
            if start { model.setTrimStart(time) } else { model.setTrimEnd(time) }
        }.onEnded { _ in dragging = nil })
        .accessibilityElement().accessibilityLabel(L(start ? "recording.from" : "recording.to"))
        .accessibilityValue(ScreenRecordingLayout.preciseTime(start ? model.trimStart : model.trimEnd))
        .accessibilityAdjustableAction { direction in
            let delta = direction == .increment ? 0.1 : -0.1
            if start { model.setTrimStart(model.trimStart + delta) } else { model.setTrimEnd(model.trimEnd + delta) }
        }
    }

    private func playhead(height: CGFloat) -> some View {
        VStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 3).frame(width: 11, height: 11)
            Rectangle().frame(width: 2, height: max(0, height - 11))
        }
        .foregroundStyle(StudioTheme.textPrimary).shadow(color: .black.opacity(0.35), radius: 2)
    }

    private func bubble(_ text: String) -> some View {
        Text(text).font(.system(size: 10.5, weight: .semibold, design: .monospaced)).foregroundStyle(.white)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 5))
    }
}

/// Peaks drawn as centred bars; `scale` previews the track volume.
struct ScreenRecordingWaveform: View {
    var levels: [Float]
    var scale: Double = 1
    var body: some View {
        Canvas { context, size in
            let count = levels.count
            guard count > 0 else { return }
            for (index, level) in levels.enumerated() {
                let height = max(2, CGFloat(sqrt(level)) * size.height * 0.85 * CGFloat(min(1, max(0, scale))))
                let rect = CGRect(x: CGFloat(index) / CGFloat(count) * size.width, y: (size.height - height) / 2,
                                  width: max(1, size.width / CGFloat(count) - 1), height: height)
                context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(AskTheme.accent.opacity(0.6)))
            }
        }
    }
}

/// Marks the part of a GIF selection that exceeds the length limit and will not be exported.
struct ScreenRecordingOverflowStripes: View {
    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(StudioTheme.warning.opacity(0.16)))
            var left: CGFloat = -size.height
            while left < size.width {
                var stripe = Path()
                stripe.move(to: CGPoint(x: left, y: size.height))
                stripe.addLine(to: CGPoint(x: left + size.height, y: 0))
                stripe.addLine(to: CGPoint(x: left + size.height + 5, y: 0))
                stripe.addLine(to: CGPoint(x: left + 5, y: size.height))
                context.fill(stripe, with: .color(StudioTheme.warning.opacity(0.45)))
                left += 12
            }
        }
    }
}
