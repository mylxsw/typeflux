import AppKit
import AVFoundation
import Combine
import SwiftUI

/// Every recorder surface uses the same exclusion identifier, including surfaces
/// made visible before the capture filter is constructed.
@MainActor
final class ScreenRecordingWindowController: NSObject, NSWindowDelegate {
    static let identifier = NSUserInterfaceItemIdentifier("ai.gulu.app.typeflux.window.screen-recording")
    var window: NSWindow?
    var border: NSPanel?
    var selectionPanels: [NSPanel] = []
    var selectionViews: [ScreenRecordingSelectionView] = []
    var cameraPanel: NSPanel?
    var cameraView: ScreenRecordingCameraBubbleView?
    var statusItem: NSStatusItem?
    var observations: [AnyCancellable] = []
    var appearanceObservation: NSObjectProtocol?
    var activationObservation: NSObjectProtocol?
    var refreshTask: Task<Void, Never>?
    var deviceTask: Task<Void, Never>?
    var keyMonitor: Any?
    var lastState: ScreenRecordingCoordinator.State?
    var activeScreen: NSScreen?
    var lastDeviceFlags: [Bool] = []
    let preview: any ScreenRecordingDevicePreviewing
    let toast: ScreenRecordingToastController
    let permissionGuide = ScreenshotPermissionGuideController()
    let settings: SettingsStore
    let interfaceStyle: InterfaceStyleObserver
    weak var model: ScreenRecordingCoordinator?

    init(settings: SettingsStore? = nil,
         preview: any ScreenRecordingDevicePreviewing = ScreenRecordingDevicePreview()) {
        let settings = settings ?? SettingsStore()
        self.settings = settings
        self.preview = preview
        toast = ScreenRecordingToastController(settings: settings)
        interfaceStyle = InterfaceStyleObserver(settings: settings)
        super.init()
        appearanceObservation = NotificationCenter.default.addObserver(
            forName: .appearanceModeDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyAppearance() }
        }
        activationObservation = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let model = self.model, model.state == .setup else { return }
                if model.permissionFailure == .permission {
                    model.reloadChoices()
                }
                if model.options.camera {
                    model.setDevice(.video, enabled: true)
                }
                if model.options.microphone, model.options.capturesAudio {
                    model.setDevice(.audio, enabled: true)
                }
                self.lastDeviceFlags = []
            }
        }
    }

    deinit {
        if let appearanceObservation {
            NotificationCenter.default.removeObserver(appearanceObservation)
        }
        if let activationObservation {
            NotificationCenter.default.removeObserver(activationObservation)
        }
        refreshTask?.cancel()
        deviceTask?.cancel()
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
    }

    static func contentSize(for state: ScreenRecordingCoordinator.State, available: CGSize) -> CGSize {
        let desired = switch state {
        case .preview, .exporting: CGSize(width: 920, height: 632)
        case .setup, .selecting, .idle: CGSize(width: 850, height: 100)
        case .countdown: CGSize(width: 160, height: 180)
        default: CGSize(width: 440, height: 82)
        }
        return CGSize(width: min(desired.width, available.width), height: min(desired.height, available.height))
    }

    func show(_ model: ScreenRecordingCoordinator) {
        if self.model !== model {
            observations = []
            self.model = model
            model.prepareCapture = { [weak self] in
                guard let self else { return }
                deviceTask?.cancel()
                await deviceTask?.value
                await preview.stop()
                lastDeviceFlags = []
                render(.starting)
                indicator("● 00:00")
            }
            observations.append(model.$state.sink { [weak self] state in
                DispatchQueue.main.async {
                    guard let self, self.model?.state == state else { return }
                    self.render(state)
                }
            })
        }
        if keyMonitor == nil {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let handled = MainActor.assumeIsolated {
                    self?.handleSelectionKey(event) == true || self?.handleEditorKey(event) == true
                }
                return handled ? nil : event
            }
        }
        activeScreen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        render(model.state)
        if refreshTask == nil {
            refreshTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(100))
                    guard let self, !Task.isCancelled else { return }
                    syncChrome()
                }
            }
        }
    }

    func makePanel(frame: CGRect, interactive: Bool = true) -> NSPanel {
        let panel = ScreenRecordingOverlayPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.identifier = Self.identifier
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + (interactive ? 1 : 0))
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.ignoresMouseEvents = !interactive
        panel.appearance = AppAppearance.nsAppearance(for: settings.appearanceMode)
        return panel
    }

    func host(_ view: some View, in window: NSWindow) {
        let host = NSHostingView(rootView: view.interfaceStyle(following: interfaceStyle))
        host.sizingOptions = []
        window.contentView = host
    }

    func showPermissionGuideIfNeeded() {
        guard let model, model.permissionFailure == .permission, !permissionGuide.isVisible else { return }
        selectionPanels.forEach { $0.orderOut(nil) }
        window?.orderOut(nil)
        permissionGuide.show(actions: ScreenshotPermissionGuideActions(
            openSettings: { model.openPermissions() },
            recheck: { model.reloadChoices(); return model.screenPermissionGranted },
            restart: { ScreenshotAppRelauncher.relaunch() },
            later: { model.cancel() }
        ))
    }

    func appKitTargetFrame() -> CGRect {
        guard let choice = model?.selectedSource else { return .zero }
        var frame = choice.frame
        if case let .window(id) = choice.target,
           let info = (CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]])?.first,
           let bounds = info[kCGWindowBounds as String] as? NSDictionary,
           let current = CGRect(dictionaryRepresentation: bounds) {
            frame = current
        }
        return ScreenCaptureGeometry.flipped(frame, primaryDisplayHeight: NSScreen.screens.first?.frame.height ?? 0)
    }

    func updateCamera() {
        guard let model, model.options.camera, model.selectedSource != nil,
              [.setup, .countdown, .starting, .recording, .paused].contains(model.state) else {
            cameraPanel?.orderOut(nil); cameraPanel = nil; cameraView = nil; return
        }
        if cameraPanel == nil {
            let panel = makePanel(frame: .zero)
            panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
            let view = ScreenRecordingCameraBubbleView(model: model)
            panel.contentView = view
            cameraPanel = panel; cameraView = view
        }
        guard cameraView?.isDragging != true else { return }
        let target = appKitTargetFrame()
        guard target.width > 0, target.height > 0 else { return }
        let local = ScreenRecordingGeometry.cameraRect(
            in: target.size,
            fraction: model.options.cameraFraction,
            corner: model.options.cameraCorner
        )
        cameraPanel?.setFrame(local.offsetBy(dx: target.minX, dy: target.minY), display: true)
        cameraView?.targetFrame = target
        cameraView?.updateChrome()
        cameraView?.preview.session = [.setup, .countdown].contains(model.state) ? preview.session : model.liveSession
        cameraPanel?.ignoresMouseEvents = model.state != .setup
        cameraPanel?.orderFrontRegardless()
    }

    func hide() {
        window?.orderOut(nil); window = nil
        border?.orderOut(nil); border = nil
        cameraPanel?.orderOut(nil); cameraPanel = nil; cameraView = nil
        selectionPanels.forEach { $0.orderOut(nil) }; selectionPanels = []; selectionViews = []
        refreshTask?.cancel(); refreshTask = nil
        deviceTask?.cancel()
        deviceTask = Task { [preview] in await preview.stop() }
        lastDeviceFlags = []; lastState = nil
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil
        }
        permissionGuide.dismiss()
    }
}
