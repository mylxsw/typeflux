import SwiftUI

struct ScreenRecordingOptionsPopover: View {
    @ObservedObject private var localization = AppLocalization.shared
    @ObservedObject var model: ScreenRecordingCoordinator
    var chooseDirectory: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(L("recording.optionsTitle"), systemImage: "slider.horizontal.3").fontWeight(.semibold)
            row(L("recording.quality")) {
                Picker(
                    L("recording.quality"),
                    selection: Binding(get: { model.options.dimension }, set: { model.options.maxDimension = $0 })
                ) {
                    if model.options.format == .gif {
                        Text(L("recording.gifSmall")).tag(640)
                        Text(L("recording.gifStandard")).tag(960)
                    } else {
                        if ![1280, 1920, 2560, 3840]
                            .contains(model.options.dimension) {
                            Text(String(model.options.dimension)).tag(model.options.dimension)
                        }
                        Text("720p").tag(1280); Text("1080p").tag(1920); Text("1440p").tag(2560); Text("4K").tag(3840)
                    }
                }.pickerStyle(.segmented).labelsHidden()
            }
            row(L("recording.fps")) {
                if model.options.format == .gif {
                    Text("10 FPS").foregroundStyle(StudioTheme.textTertiary)
                } else {
                    Picker(L("recording.fps"), selection: $model.options.framesPerSecond) {
                        if ![24, 30, 60]
                            .contains(model.options.framesPerSecond) {
                            Text(String(model.options.framesPerSecond)).tag(model.options.framesPerSecond)
                        }
                        Text("24").tag(24); Text("30").tag(30); Text("60").tag(60)
                    }.pickerStyle(.segmented).labelsHidden()
                }
            }
            row(L("recording.delay")) {
                Picker(L("recording.delay"), selection: $model.options.countdown) {
                    Text(L("recording.noDelay")).tag(0)
                    ForEach([3, 5, 10], id: \.self) { Text(L("recording.seconds", $0)).tag($0) }
                }.pickerStyle(.segmented).labelsHidden()
            }
            row(L("recording.cursor")) {
                Toggle(L("recording.cursor"), isOn: $model.options.showsCursor).toggleStyle(.switch).labelsHidden()
            }
            Divider()
            row(L("recording.destination")) {
                Button(action: chooseDirectory) { Label(
                    model.destinationDirectory.lastPathComponent,
                    systemImage: "folder"
                ) }
                .help(model.destinationDirectory.path)
            }
            Text("\(Int(model.outputSize.width)) × \(Int(model.outputSize.height)) px · " + L("recording.noUpscale"))
                .font(.system(size: 11.5)).foregroundStyle(StudioTheme.textTertiary)
        }.font(.system(size: 12)).padding(14).frame(width: 350).tint(AskTheme.accent)
    }

    private func row(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: 10) {
            Text(title).foregroundStyle(StudioTheme.textSecondary).frame(width: 74, alignment: .leading)
            content().frame(maxWidth: .infinity, alignment: .leading)
        }.frame(minHeight: 28)
    }
}
