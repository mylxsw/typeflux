import SwiftUI

struct ScreenRecordingSetupView: View {
    @ObservedObject private var localization = AppLocalization.shared
    @ObservedObject var model: ScreenRecordingCoordinator
    @State private var showsAdvanced = false

    var body: some View {
        source
        ScreenRecordingSection(title: L("recording.output"), symbol: "film") {
            Picker(L("recording.format"), selection: $model.options.format) {
                Text(L("recording.mp4Choice")).tag(ScreenRecordingFormat.mp4)
                Text(L("recording.gifChoice")).tag(ScreenRecordingFormat.gif)
            }.pickerStyle(.segmented).labelsHidden()
            if model.options.format == .mp4 {
                Toggle(L("recording.systemAudio"), isOn: $model.options.systemAudio)
                Toggle(L("recording.microphone"), isOn: $model.options.microphone)
                Text(model.options.systemAudio ? L("recording.audioScope") : L("recording.audioHint"))
                    .font(.caption).foregroundStyle(StudioTheme.textSecondary)
            } else {
                Text(L("recording.gifHint")).font(.caption).foregroundStyle(StudioTheme.textSecondary)
            }
        }
        ScreenRecordingSection(title: L("recording.cameraSection"), symbol: "video") {
            Toggle(L("recording.camera"), isOn: $model.options.camera)
            if model.options.camera {
                HStack(spacing: 14) {
                    cameraPlacement.frame(width: 136, height: 82)
                    VStack(alignment: .leading, spacing: 10) {
                        Picker(L("recording.cameraPosition"), selection: $model.options.cameraCorner) {
                            ForEach(ScreenRecordingOptions.CameraCorner.allCases, id: \.self) {
                                Text(L("recording.corner." + $0.rawValue)).tag($0)
                            }
                        }
                        HStack {
                            Text(L("recording.cameraSize"))
                            Slider(value: $model.options.cameraFraction, in: 0.12 ... 0.4)
                                .accessibilityLabel(L("recording.cameraSize"))
                            Text(model.options.cameraFraction, format: .percent.precision(.fractionLength(0)))
                                .monospacedDigit().frame(width: 34)
                        }
                    }
                }
                Text(L("recording.cameraHint")).font(.caption).foregroundStyle(StudioTheme.textSecondary)
            }
        }
        DisclosureGroup(L("recording.moreOptions"), isExpanded: $showsAdvanced) {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(L("recording.cursor"), isOn: $model.options.showsCursor)
                Picker(L("recording.delay"), selection: $model.options.countdown) {
                    Text(L("recording.noDelay")).tag(0)
                    Text(L("recording.seconds", 3)).tag(3)
                    Text(L("recording.seconds", 5)).tag(5)
                }
                if model.options.format == .mp4 {
                    Picker(L("recording.quality"), selection: $model.options.maxDimension) {
                        Text(L("recording.quality.small")).tag(1280)
                        Text(L("recording.quality.standard")).tag(1920)
                        Text(L("recording.quality.high")).tag(3840)
                    }
                    Picker(L("recording.fps"), selection: $model.options.framesPerSecond) {
                        Text("15").tag(15); Text("30").tag(30); Text("60").tag(60)
                    }
                    Text(L("recording.qualityHint")).font(.caption).foregroundStyle(StudioTheme.textSecondary)
                }
            }.padding(.top, 10)
        }
        .accessibilityIdentifier("recording.advanced")
    }

    private var source: some View {
        ScreenRecordingSection(title: L("recording.source"), symbol: "viewfinder") {
            Picker(L("recording.source"), selection: Binding(get: { model.sourceKind }, set: model.selectSourceKind)) {
                ForEach(ScreenRecordingSourceKind.allCases, id: \.self) {
                    Text(L("recording.source." + $0.rawValue)).tag($0)
                }
            }.pickerStyle(.segmented).labelsHidden()
            if model.sourceKind == .region {
                HStack {
                    if model.selectedSource != nil {
                        Text(model.sourceSummary).font(.caption).foregroundStyle(StudioTheme.textSecondary)
                    } else {
                        Text(L("recording.regionHint")).font(.caption).foregroundStyle(StudioTheme.textSecondary)
                    }
                    Spacer()
                    Button(L("recording.chooseRegion")) { model.selectRegion() }
                        .disabled(model.permissionFailure == .permission)
                }
            } else if model.visibleSources.isEmpty {
                if model.isLoadingSources {
                    ProgressView(L("recording.loadingSources")).controlSize(.small)
                } else {
                    HStack {
                        Text(L(model.sourceKind == .window ? "recording.noWindows" : "recording.noDisplays"))
                            .font(.caption).foregroundStyle(StudioTheme.textSecondary)
                        Spacer()
                        Button(L("recording.refresh")) { model.reloadChoices() }
                    }
                }
            } else {
                HStack {
                    Picker(L("recording.source"), selection: $model.selectedID) {
                        ForEach(model.visibleSources) { Text($0.title).tag($0.id) }
                    }.labelsHidden().frame(maxWidth: .infinity, alignment: .leading).help(model.sourceSummary)
                    Button { model.reloadChoices() } label: { Image(systemName: "arrow.clockwise") }
                        .accessibilityLabel(L("recording.refresh")).help(L("recording.refresh"))
                        .disabled(model.isLoadingSources)
                }
            }
        }
    }

    private var cameraPlacement: some View {
        GeometryReader { geometry in
            let rect = ScreenRecordingGeometry.cameraRect(in: geometry.size, fraction: model.options.cameraFraction,
                                                          corner: model.options.cameraCorner)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 6).fill(AskTheme.controlSurface)
                Image(systemName: "display").foregroundStyle(StudioTheme.textTertiary)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                RoundedRectangle(cornerRadius: 3).fill(AskTheme.accent)
                    .overlay(Image(systemName: "person.fill").font(.system(size: 10)).foregroundStyle(.white))
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: geometry.size.height - rect.maxY)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L("recording.cameraLayout"))
        .accessibilityValue(L("recording.corner." + model.options.cameraCorner.rawValue))
    }
}
