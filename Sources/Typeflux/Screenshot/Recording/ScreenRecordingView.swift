import AppKit
import AVKit
import Combine
import SwiftUI

struct ScreenRecordingView: View {
    @ObservedObject var model: ScreenRecordingCoordinator
    var close: () -> Void
    var chooseDirectory: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Image(systemName: "record.circle").font(.title2).foregroundStyle(.red)
                Text(L("recording.title")).font(.title2.weight(.semibold))
                Spacer()
                if model.state == .recording || model.state == .paused {
                    Text(ScreenRecordingCoordinator.timeLabel(model.elapsed)).monospacedDigit().font(.title2)
                }
            }
            switch model.state {
            case .idle, .setup, .selecting: setup
            case .countdown:
                Text(String(model.countdown)).font(.system(size: 56, weight: .medium, design: .rounded))
                    .frame(maxWidth: .infinity)
                Text(L("recording.countdown")).foregroundStyle(.secondary)
                Button(L("recording.cancel"), action: close).keyboardShortcut(.cancelAction)
            case .starting, .stopping:
                ProgressView(L(model.state == .starting ? "recording.starting" : "recording.stopping"))
                    .frame(maxWidth: .infinity, minHeight: 70)
            case .recording, .paused:
                Text(L(model.state == .paused ? "recording.paused" : "recording.active")).foregroundStyle(.secondary)
                HStack {
                    Button(L(model.state == .paused ? "recording.resume" : "recording.pause")) { model.togglePause() }
                    Button(L("recording.stop")) { model.stop() }.buttonStyle(.borderedProminent)
                    Spacer()
                    Button(L("recording.discard"), action: close)
                }
            case .preview, .exporting: preview
            case .completed:
                Label(L("recording.saved"), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                if let url = model.savedURL {
                    Text(url.lastPathComponent).textSelection(.enabled)
                    HStack {
                        Button(L("recording.open")) { NSWorkspace.shared.open(url) }
                        Button(L("recording.reveal")) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        Spacer()
                        Button(L("recording.done"), action: close).keyboardShortcut(.defaultAction)
                    }
                }
            }
            if let error = model.error {
                Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled).fixedSize(
                    horizontal: false,
                    vertical: true
                )
                if model.state == .setup {
                    HStack {
                        Button(L("recording.permissions")) { model.openPermissions() }
                        Button(L("recording.refresh")) { model.reloadChoices() }
                    }
                }
            }
        }
        .padding(24)
        .frame(width: model.state == .preview || model.state == .exporting ? 660 : 440)
        .animation(.easeInOut(duration: 0.15), value: model.state)
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker(L("recording.source"), selection: $model.selectedID) {
                if model.choices.isEmpty {
                    Text(L("recording.selectSource")).tag("")
                }
                ForEach(model.choices) { choice in Text(choice.title).tag(choice.id) }
            }
            HStack {
                Button(L("recording.chooseRegion")) { model.selectRegion() }
                Button(L("recording.refresh")) { model.reloadChoices() }
            }
            Picker(L("recording.format"), selection: $model.options.format) {
                Text("MP4").tag(ScreenRecordingFormat.mp4)
                Text("GIF").tag(ScreenRecordingFormat.gif)
            }.pickerStyle(.segmented)
            if model.options.format == .mp4 {
                HStack {
                    Picker(L("recording.resolution"), selection: $model.options.maxDimension) {
                        Text("1280 px").tag(1280); Text("1920 px").tag(1920); Text("3840 px").tag(3840)
                    }
                    Picker(L("recording.fps"), selection: $model.options.framesPerSecond) {
                        Text("15").tag(15); Text("30").tag(30); Text("60").tag(60)
                    }
                }
                Toggle(L("recording.systemAudio"), isOn: $model.options.systemAudio)
                Toggle(L("recording.microphone"), isOn: $model.options.microphone)
                Text(L("recording.audioScope")).font(.caption).foregroundStyle(.secondary)
            } else {
                Text(L("recording.gifHint")).font(.callout).foregroundStyle(.secondary)
            }
            Toggle(L("recording.cursor"), isOn: $model.options.showsCursor)
            Toggle(L("recording.camera"), isOn: $model.options.camera)
            if model.options.camera {
                Picker(L("recording.cameraPosition"), selection: $model.options.cameraCorner) {
                    ForEach(ScreenRecordingOptions.CameraCorner.allCases, id: \.self) {
                        Text(L("recording.corner." + $0.rawValue)).tag($0)
                    }
                }
                HStack {
                    Text(L("recording.cameraSize"))
                    Slider(value: $model.options.cameraFraction, in: 0.12 ... 0.4)
                }
            }
            Picker(L("recording.delay"), selection: $model.options.countdown) {
                Text("0 s").tag(0); Text("3 s").tag(3); Text("5 s").tag(5)
            }
            Divider()
            HStack {
                Button(L("recording.cancel"), action: close).keyboardShortcut(.cancelAction)
                if !model.recovered.isEmpty {
                    Menu(L("recording.recover")) {
                        ForEach(model.recovered, id: \.self) { url in
                            Button(url.deletingLastPathComponent().lastPathComponent) { model.recover(url) }
                        }
                    }
                }
                Spacer()
                Button(L("recording.start")) { model.start() }.buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction).disabled(model.selectedID.isEmpty)
            }
        }
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 12) {
            VideoPlayer(player: model.player).frame(height: 310).clipShape(RoundedRectangle(cornerRadius: 10))
            Text(L("recording.trim")).font(.headline)
            HStack {
                Text(L("recording.from"))
                Slider(value: $model.trimStart, in: 0 ... max(0.01, model.duration)) { editing in
                    if !editing {
                        model.seek(model.trimStart)
                    }
                }
                TextField("", value: $model.trimStart, format: .number.precision(.fractionLength(2)))
                    .frame(width: 65).accessibilityLabel(L("recording.from"))
            }
            HStack {
                Text(L("recording.to"))
                Slider(value: $model.trimEnd, in: 0 ... max(0.01, model.duration)) { editing in
                    if !editing {
                        model.seek(model.trimEnd)
                    }
                }
                TextField("", value: $model.trimEnd, format: .number.precision(.fractionLength(2)))
                    .frame(width: 65).accessibilityLabel(L("recording.to"))
            }
            Picker(L("recording.format"), selection: $model.options.format) {
                Text("MP4").tag(ScreenRecordingFormat.mp4); Text("GIF").tag(ScreenRecordingFormat.gif)
            }.pickerStyle(.segmented)
            if model.options.format == .gif {
                Text(L("recording.gifHint")).font(.caption).foregroundStyle(.secondary)
            }
            if model.state == .exporting {
                ProgressView(value: model.progress)
                Button(L("recording.cancelExport")) { model.cancelExport() }
            } else {
                HStack {
                    Button(L("recording.discard"), action: close)
                    Spacer()
                    Button(L("recording.saveAs"), action: chooseDirectory)
                    Button(L("recording.export")) { model.export() }.buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
    }
}

/// One stable window ID is kept through setup, recording and export, so the
/// capture filter excludes the controls even when the content changes.
@MainActor
final class ScreenRecordingWindowController: NSObject, NSWindowDelegate {
    static let identifier = NSUserInterfaceItemIdentifier("ai.gulu.app.typeflux.window.screen-recording")
    private(set) var window: NSWindow?
    private(set) var border: NSPanel?
    private var statusItem: NSStatusItem?
    private var stateObservation: AnyCancellable?
    weak var model: ScreenRecordingCoordinator?

    func show(_ model: ScreenRecordingCoordinator) {
        self.model = model
        if window == nil {
            let window = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 488, height: 540),
                                 styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered,
                                 defer: false)
            window.identifier = Self.identifier
            window.title = L("recording.title")
            window.isReleasedWhenClosed = false
            window.hidesOnDeactivate = false
            window.level = .floating
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.delegate = self
            window.contentView = NSHostingView(rootView: ScreenRecordingView(model: model, close: { [weak self] in
                self?.requestClose()
            }, chooseDirectory: { [weak self] in self?.chooseDirectory() }))
            window.center()
            self.window = window
            stateObservation = model.$state.sink { [weak self] state in
                DispatchQueue.main.async {
                    let size = switch state {
                    case .preview, .exporting: CGSize(width: 660, height: 680)
                    case .setup, .selecting, .idle: CGSize(width: 440, height: 640)
                    default: CGSize(width: 440, height: 260)
                    }
                    self?.window?.setContentSize(size)
                }
            }
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func hide() {
        window?.orderOut(nil)
    }

    func windowShouldClose(_: NSWindow) -> Bool {
        requestClose(); return false
    }

    func requestClose() {
        guard let model, model.state != .stopping, model.state != .starting else { return }
        if model.state == .exporting {
            model.cancelExport(); return
        }
        if [.recording, .paused, .preview].contains(model.state) {
            let alert = NSAlert()
            alert.messageText = L("recording.discardQuestion")
            alert.informativeText = L("recording.discardHint")
            alert.addButton(withTitle: L("recording.keep"))
            alert.addButton(withTitle: L("recording.discard"))
            guard alert.runModal() == .alertSecondButtonReturn else { return }
        }
        model.cancel()
    }

    func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = L("recording.export")
        if panel.runModal() == .OK, let url = panel.url {
            model?.export(directory: url)
        }
    }

    func indicator(_ title: String?) {
        guard let title else {
            if let statusItem {
                NSStatusBar.system.removeStatusItem(statusItem)
            }
            statusItem = nil
            return
        }
        if statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            let menu = NSMenu()
            for (key, selector) in [
                ("recording.stop", #selector(stop)),
                ("recording.showControls", #selector(showControls))
            ] {
                let entry = NSMenuItem(title: L(key), action: selector, keyEquivalent: "")
                entry.target = self
                menu.addItem(entry)
            }
            item.menu = menu
            statusItem = item
        }
        statusItem?.button?.title = title
        statusItem?.button?.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
    }

    @objc private func stop() {
        model?.stop()
    }

    @objc private func showControls() {
        if let model {
            show(model)
        }
    }

    func outline(_ target: ScreenRecordingTarget?) {
        border?.orderOut(nil)
        border = nil
        guard case let .region(_, rect) = target else { return }
        let frame = ScreenCaptureGeometry.flipped(rect, primaryDisplayHeight: NSScreen.screens.first?.frame.height ?? 0)
        let panel = NSPanel(contentRect: frame.insetBy(dx: -2, dy: -2), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.identifier = Self.identifier
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: Rectangle().stroke(Color.red, lineWidth: 3))
        panel.orderFrontRegardless()
        border = panel
    }
}
