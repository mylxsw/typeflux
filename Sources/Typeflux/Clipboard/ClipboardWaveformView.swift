import SwiftUI

/// Peak bars of an audio file. Played bars take the accent color; a click seeks when `onSeek` is set.
struct ClipboardWaveformView: View {
    let url: URL?
    let bars: Int
    var progress: Double = 0
    var onSeek: ((Double) -> Void)?
    @State private var levels: [Float]?

    /// Bars drawn before the waveform is decoded, or when it cannot be.
    static let placeholderLevel: CGFloat = 0.12

    var body: some View {
        Canvas { context, size in
            let count = max(bars, 1)
            let gap: CGFloat = 2
            let width = max((size.width - gap * CGFloat(count - 1)) / CGFloat(count), 1)
            for index in 0 ..< count {
                let level = levels.flatMap { $0.indices.contains(index) ? CGFloat($0[index]) : nil }
                    ?? Self.placeholderLevel
                let height = max(size.height * level, 2)
                let rect = CGRect(
                    x: CGFloat(index) * (width + gap), y: (size.height - height) / 2, width: width, height: height
                )
                let played = Double(index) / Double(count) < progress
                context.fill(
                    Path(roundedRect: rect, cornerRadius: width / 2),
                    with: .color(played ? Color.accentColor : Color.secondary.opacity(0.55))
                )
            }
        }
        .overlay {
            if let onSeek {
                GeometryReader { proxy in
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0).onEnded { value in
                            guard proxy.size.width > 0 else { return }
                            onSeek(value.location.x / proxy.size.width)
                        })
                }
            }
        }
        .task(id: "\(url?.path ?? "")#\(bars)") {
            guard let url else {
                levels = nil
                return
            }
            levels = ClipboardMediaInfoProvider.shared.cachedWaveform(for: url, bars: bars)
            if levels == nil {
                levels = await ClipboardMediaInfoProvider.shared.waveform(for: url, bars: bars)
            }
        }
        .accessibilityHidden(true)
    }
}

/// The selected audio row: play / pause, a seekable waveform and the elapsed time.
struct ClipboardAudioPlayerView: View {
    let url: URL
    let duration: TimeInterval?
    @StateObject private var playback = ClipboardAudioPlayback()

    var body: some View {
        HStack(spacing: 8) {
            Button {
                playback.toggle()
            } label: {
                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(StudioTheme.textPrimary)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Color.primary.opacity(0.1)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            ClipboardWaveformView(url: url, bars: 90, progress: playback.progress, onSeek: playback.seek(to:))
                .frame(height: 28)
            Text(verbatim: timeLabel)
                .font(.system(size: 10.5).monospacedDigit())
                .foregroundStyle(StudioTheme.textSecondary)
        }
        .padding(.leading, 8)
        .padding(.trailing, 10)
        .frame(maxWidth: .infinity)
        .frame(height: 48)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .onAppear { playback.load(url, duration: duration) }
        .onChange(of: duration) { playback.updateDuration($0) }
        .onDisappear { playback.stop() }
    }

    private var timeLabel: String {
        let total = playback.duration > 0 ? ClipboardEntryFormatter.duration(playback.duration) : ""
        guard playback.isPlaying || playback.progress > 0 else { return total }
        let elapsed = ClipboardEntryFormatter.duration(playback.elapsed)
        return total.isEmpty ? elapsed : "\(elapsed) / \(total)"
    }
}
