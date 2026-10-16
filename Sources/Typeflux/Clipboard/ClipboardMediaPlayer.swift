import SwiftUI

/// Native media stays in the helper. This view only presents bounded RGBA and explicit controls.
struct ClipboardMediaPlayer: View {
    let url: URL
    @Environment(\.askContextImageAccess) private var access
    @StateObject private var playback: ClipboardAudioPlayback
    @State private var position = 0.0
    @State private var volume = 1.0
    @State private var editingPosition = false
    @State private var editingVolume = false
    @State private var seekInteraction: UUID?
    @State private var volumeInteraction: UUID?
    init(url: URL, playback: ClipboardAudioPlayback? = nil) {
        self.url = url
        _playback = StateObject(wrappedValue: playback ?? ClipboardAudioPlayback(video: true))
    }
    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                if let image = playback.image {
                    Image(nsImage: image).resizable().scaledToFit()
                } else if playback.failed {
                    Label(L("clipboard.video.unavailable"), systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.white)
                } else {
                    Image(systemName: "film").foregroundStyle(.white.opacity(0.6))
                }
            }
            Slider(value: $position, in: 0...1) { editing in
                editingPosition = editing
                if editing { seekInteraction = playback.interactionID }
                else if let interaction = seekInteraction {
                    seekInteraction = nil
                    playback.seek(to: position, interactionID: interaction)
                }
            }.accessibilityLabel(L("clipboard.video.position"))
            .disabled(!playback.isLoaded || playback.isBusy).controlSize(.mini).padding(.horizontal, 8)
            HStack(spacing: 8) {
                Button { playback.toggle() } label: {
                    Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                }
                .accessibilityLabel(L(playback.isPlaying ? "clipboard.video.pause" : "clipboard.video.play"))
                Text(verbatim: "\(ClipboardEntryFormatter.duration(playback.elapsed)) / \(ClipboardEntryFormatter.duration(playback.duration))")
                    .font(.system(size: 10).monospacedDigit())
                Image(systemName: volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                Slider(value: $volume, in: 0...1) { editing in
                    editingVolume = editing
                    if editing { volumeInteraction = playback.interactionID }
                    else if let interaction = volumeInteraction {
                        volumeInteraction = nil
                        playback.setVolume(volume, interactionID: interaction)
                    }
                }.frame(width: 55).accessibilityLabel(L("clipboard.video.volume"))
            }
            .buttonStyle(.plain).controlSize(.mini).foregroundStyle(.white)
            .padding(8).background(Color.black.opacity(0.85))
            .disabled(!playback.isLoaded || playback.isBusy)
        }
        .onChange(of: playback.progress) { value in if !editingPosition { position = value } }
        .onChange(of: playback.volume) { value in if !editingVolume { volume = value } }
        .task(id: ClipboardAudioPlayback.Identity(url: url, epoch: access.epoch)) { playback.load(url, access: access) }
        .onDisappear { playback.stop() }
    }
}
