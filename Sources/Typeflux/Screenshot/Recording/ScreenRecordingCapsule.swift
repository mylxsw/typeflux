import SwiftUI

struct ScreenRecordingCapsule: View {
    @ObservedObject private var localization = AppLocalization.shared
    @ObservedObject var model: ScreenRecordingCoordinator
    var levelProvider: () -> Float = { 0 }
    var close: () -> Void
    @State private var confirmation: String?
    var body: some View {
        VStack(spacing: 6) {
            if model.options.format == .gif, model.elapsed >= 25 {
                Text(L("recording.remaining", Int(ceil(max(0, 30 - model.elapsed)))))
                    .font(.system(size: 12)).foregroundStyle(StudioTheme.warning)
                    .padding(6).recordingSurface(corner: 8)
            }
            HStack(spacing: 2) {
                Circle().fill(model.state == .paused ? StudioTheme.warning : ScreenRecordingAppearance.record).frame(
                    width: 10,
                    height: 10
                )
                .padding(.leading, 8).padding(.trailing, 6)
                Text(ScreenRecordingCoordinator.timeLabel(model.elapsed)).font(.system(
                    size: 14,
                    weight: .semibold,
                    design: .monospaced
                ))
                if model.options
                    .format ==
                    .gif {
                    Text("/ 00:30").foregroundStyle(StudioTheme.textTertiary).font(.system(size: 12))
                }
                if model
                    .state ==
                    .paused {
                    Text(L("recording.paused")).foregroundStyle(StudioTheme.warning).font(.system(size: 12))
                }
                if model.options.microphone, model.options.capturesAudio {
                    TimelineView(.periodic(
                        from: .now,
                        by: 0.1
                    )) { _ in ScreenRecordingMeterView(level: levelProvider()) }.padding(.horizontal, 8)
                }
                Divider().frame(height: 18).padding(.horizontal, 5)
                control(
                    model.state == .paused ? "play.fill" : "pause.fill",
                    title: L(model.state == .paused ? "recording.resume" : "recording.pause"),
                    action: model.togglePause
                )
                control("arrow.counterclockwise", title: L("recording.restart")) { confirmation = "restart" }
                control("trash", title: L("recording.discard")) { confirmation = "discard" }
                Button { model.stop() } label: {
                    Label(L("recording.stop"), systemImage: "stop.fill").font(.system(size: 12.5, weight: .semibold))
                        .padding(.horizontal, 10).frame(height: 30).foregroundStyle(.white)
                        .background(ScreenRecordingAppearance.record, in: RoundedRectangle(cornerRadius: 9))
                }.padding(.leading, 4)
            }.padding(4).buttonStyle(.plain).recordingSurface(corner: 14)
                .overlay(alignment: .bottom) {
                    if model.options.format == .gif {
                        GeometryReader { geometry in
                            Rectangle().fill(model.elapsed >= 25 ? StudioTheme.warning : AskTheme.accent)
                                .frame(width: geometry.size.width * min(1, max(0, model.elapsed / 30)), height: 2)
                        }.frame(height: 2).padding(.horizontal, 10).padding(.bottom, 2)
                    }
                }
                .popover(
                    isPresented: Binding(get: { confirmation != nil }, set: {
                        if !$0 {
                            confirmation = nil
                        }
                    }),
                    arrowEdge: .top
                ) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(L(confirmation == "restart" ? "recording.restartQuestion" : "recording.discardQuestion"))
                            .fontWeight(.semibold)
                        Text(L("recording.discardHint")).foregroundStyle(StudioTheme.textSecondary)
                        HStack {
                            Button(L("recording.keep")) { confirmation = nil }.keyboardShortcut(.defaultAction)
                            Button(L(confirmation == "restart" ? "recording.restart" : "recording.discard")) {
                                let restart = confirmation == "restart"
                                confirmation = nil
                                if restart {
                                    model.restart()
                                } else {
                                    close()
                                }
                            }
                        }
                    }.font(.system(size: 12)).padding(14).frame(width: 280)
                }
        }.fixedSize().padding(12)
    }

    private func control(_ symbol: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 12)).frame(width: 30, height: 30) }
            .foregroundStyle(StudioTheme.textSecondary).help(title).accessibilityLabel(title)
    }
}
