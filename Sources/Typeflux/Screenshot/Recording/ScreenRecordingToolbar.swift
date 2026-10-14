import AVFoundation
import SwiftUI

struct ScreenRecordingToolbar: View {
    @ObservedObject private var localization = AppLocalization.shared
    @ObservedObject var model: ScreenRecordingCoordinator
    var levelProvider: () -> Float = { 0 }
    var close: () -> Void
    var chooseDirectory: () -> Void
    @State private var showsOptions = false
    @State private var showsMicrophonePermission = false
    @State private var showsCameraPermission = false

    var body: some View {
        VStack(spacing: 10) {
            if let error = model.error, model.permissionFailure != .microphonePermission,
               model.permissionFailure != .cameraPermission {
                HStack(spacing: 8) {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                    if model.permissionFailure != nil {
                        Button(model.permissionActionTitle) { model.openPermissions() }
                    }
                    Button(L("recording.refresh")) { model.reloadChoices() }
                }.font(.system(size: 12)).padding(10)
                    .background(AskTheme.popoverSurface, in: RoundedRectangle(cornerRadius: 10))
            }
            HStack(spacing: 2) {
                Image(systemName: "line.3.horizontal").font(.system(size: 9)).foregroundStyle(StudioTheme.textTertiary)
                    .frame(width: 14, height: 30)
                segment {
                    ForEach([ScreenRecordingSourceKind.region, .window, .display], id: \.self) { kind in
                        Button { model.selectSourceKind(kind) } label: {
                            Label(L("recording.source." + kind.rawValue), systemImage: kind.symbol)
                                .padding(.horizontal, 8).frame(height: 26)
                                .background(
                                    model.sourceKind == kind ? AskTheme.pressFill : .clear,
                                    in: RoundedRectangle(cornerRadius: 6)
                                )
                        }.accessibilityIdentifier("recording.source." + kind.rawValue)
                    }
                }
                separator
                segment {
                    ForEach(ScreenRecordingFormat.allCases, id: \.self) { format in
                        Button {
                            if format == .mp4,
                               model.options.maxDimension < 1280 {
                                model.options.maxDimension = 1920
                            }; model
                                .options.format = format
                        } label: {
                            Label(format.rawValue.uppercased(), systemImage: format == .mp4 ? "film" : "photo.stack")
                                .padding(.horizontal, 8).frame(height: 26)
                                .background(
                                    model.options.format == format ? AskTheme.pressFill : .clear,
                                    in: RoundedRectangle(cornerRadius: 6)
                                )
                        }
                    }
                }
                separator
                icon(
                    "speaker.wave.2",
                    title: L("recording.systemAudio"),
                    isOn: model.options.systemAudio && model.options.capturesAudio
                ) {
                    model.options.systemAudio.toggle()
                }.disabled(!model.options.capturesAudio)
                    .help(L(model.options.capturesAudio ? "recording.systemAudioScope" : "recording.gifSilent"))
                Button {
                    model.setDevice(.audio, enabled: !model.options.microphone)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "mic")
                        if model.options.microphone, model.options.capturesAudio {
                            TimelineView(.periodic(
                                from: .now,
                                by: 0.1
                            )) { _ in ScreenRecordingMeterView(level: levelProvider()) }
                        }
                    }.padding(.horizontal, 7).frame(height: 30)
                        .background(
                            model.options.microphone && model.options.capturesAudio ? AskTheme.accentSoft : .clear,
                            in: RoundedRectangle(cornerRadius: 8)
                        )
                        .foregroundStyle(model.options.microphone && model.options.capturesAudio ? AskTheme
                            .accent : StudioTheme.textSecondary)
                        .overlay(alignment: .topTrailing) { permissionDot(.audio) }
                }.disabled(!model.options.capturesAudio).accessibilityLabel(L("recording.microphone"))
                    .popover(isPresented: $showsMicrophonePermission, arrowEdge: .top) { permission(.audio) }
                    .help(L(model.options.capturesAudio ? "recording.microphone" : "recording.gifSilent"))
                icon("video", title: L("recording.camera"), isOn: model.options.camera) {
                    model.setDevice(.video, enabled: !model.options.camera)
                }.overlay(alignment: .topTrailing) { permissionDot(.video) }
                    .popover(isPresented: $showsCameraPermission, arrowEdge: .top) { permission(.video) }
                separator
                Button { showsOptions.toggle() } label: {
                    Label(L("recording.options"), systemImage: "slider.horizontal.3").padding(.horizontal, 7)
                        .frame(height: 30)
                }.popover(isPresented: $showsOptions, arrowEdge: .top) { options }
                separator
                icon("xmark", title: L("recording.cancel"), action: close)
                Button(action: model.start) {
                    Label(L("recording.start"), systemImage: "circle.fill")
                        .fontWeight(.semibold).padding(.horizontal, 12).frame(height: 30)
                        .foregroundStyle(.white).background(
                            ScreenRecordingAppearance.record,
                            in: RoundedRectangle(cornerRadius: 8)
                        )
                }.disabled(!model.canStart).opacity(model.canStart ? 1 : 0.4)
                    .keyboardShortcut(.defaultAction).accessibilityIdentifier("recording.start")
            }.padding(4).buttonStyle(.plain).font(.system(size: 12.5))
                .foregroundStyle(StudioTheme.textPrimary).recordingSurface(corner: 12)
            HStack(spacing: 10) {
                Text(model.selectedSource == nil ? model.selectionHint : model.outputSummary)
                    .padding(.horizontal, 9).padding(.vertical, 3).background(.black.opacity(0.65), in: Capsule())
                Text(L("recording.selectionKeys"))
                    .padding(.horizontal, 9).padding(.vertical, 3).background(.black.opacity(0.65), in: Capsule())
            }.font(.system(size: 11.5)).foregroundStyle(.white)
        }.fixedSize().padding(12)
            .onAppear {
                showsMicrophonePermission = model.permissionFailure == .microphonePermission
                showsCameraPermission = model.permissionFailure == .cameraPermission
            }
            .onChange(of: model.permissionFailure) { failure in
                showsMicrophonePermission = failure == .microphonePermission
                showsCameraPermission = failure == .cameraPermission
            }
    }

    private var separator: some View {
        Rectangle().fill(AskTheme.border).frame(width: 1, height: 18).padding(
            .horizontal,
            4
        )
    }

    private func segment(@ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: 2, content: content).padding(2).background(
            AskTheme.controlSurface,
            in: RoundedRectangle(cornerRadius: 8)
        )
    }

    private func icon(_ symbol: String, title: String, isOn: Bool = false,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 30, height: 30)
                .foregroundStyle(isOn ? AskTheme.accent : StudioTheme.textSecondary)
                .background(isOn ? AskTheme.accentSoft : .clear, in: RoundedRectangle(cornerRadius: 8))
        }.accessibilityLabel(title).help(title)
    }

    @ViewBuilder private func permissionDot(_ type: AVMediaType) -> some View {
        if [.denied, .restricted, .notDetermined].contains(AVCaptureDevice.authorizationStatus(for: type)) {
            Circle().fill(StudioTheme.warning).frame(width: 6, height: 6).padding(2)
        }
    }

    private func permission(_ type: AVMediaType) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(
                L(type == .audio ? "recording.error.microphonePermission" : "recording.error.cameraPermission"),
                systemImage: "exclamationmark.triangle.fill"
            )
            .fontWeight(.semibold)
            Text(L(type == .audio ? "recording.microphonePermissionHint" : "recording.cameraPermissionHint"))
                .foregroundStyle(StudioTheme.textSecondary)
            HStack {
                Button(L(type == .audio ? "recording.skipMicrophone" : "recording.skipCamera")) {
                    model.setDevice(type, enabled: false)
                    showsMicrophonePermission = false; showsCameraPermission = false
                }
                Button(model.permissionActionTitle) {
                    model.openPermissions()
                    showsMicrophonePermission = false; showsCameraPermission = false
                }.buttonStyle(.borderedProminent)
            }
        }.font(.system(size: 12)).padding(14).frame(width: 320)
    }

    private var options: some View {
        ScreenRecordingOptionsPopover(model: model, chooseDirectory: chooseDirectory)
    }
}

extension View {
    func recordingSurface(corner: CGFloat) -> some View {
        askInWindowGlass(
            corner: corner,
            opaqueFill: AskTheme.glassFill.opacity(0.96),
            elevation: .popover,
            placement: .floating
        )
        .overlay(RoundedRectangle(cornerRadius: corner).strokeBorder(AskTheme.border))
    }
}
