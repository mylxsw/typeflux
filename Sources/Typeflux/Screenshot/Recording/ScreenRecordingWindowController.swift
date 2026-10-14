import AppKit
import Combine
import SwiftUI

/// One stable window ID is kept through setup, recording and export, so the
/// capture filter excludes the controls even when the content changes.
@MainActor
final class ScreenRecordingWindowController: NSObject, NSWindowDelegate {
    static let identifier = NSUserInterfaceItemIdentifier("ai.gulu.app.typeflux.window.screen-recording")
    private(set) var window: NSWindow?
    private(set) var border: NSPanel?
    private var statusItem: NSStatusItem?
    private var stateObservation: AnyCancellable?
    private var appearanceObservation: NSObjectProtocol?
    private let settings: SettingsStore
    private let interfaceStyle: InterfaceStyleObserver
    weak var model: ScreenRecordingCoordinator?

    init(settings: SettingsStore? = nil) {
        let settings = settings ?? SettingsStore()
        self.settings = settings
        interfaceStyle = InterfaceStyleObserver(settings: settings)
        super.init()
        appearanceObservation = NotificationCenter.default.addObserver(
            forName: .appearanceModeDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.window?.appearance = AppAppearance.nsAppearance(for: self.settings.appearanceMode)
            }
        }
    }

    deinit {
        if let appearanceObservation {
            NotificationCenter.default.removeObserver(appearanceObservation)
        }
    }

    static func contentSize(for state: ScreenRecordingCoordinator.State, available: CGSize) -> CGSize {
        let desired = switch state {
        case .preview, .exporting: CGSize(width: 680, height: 660)
        case .setup, .selecting, .idle: CGSize(width: 540, height: 740)
        case .countdown: CGSize(width: 460, height: 340)
        default: CGSize(width: 460, height: 280)
        }
        return CGSize(width: min(desired.width, available.width), height: min(desired.height, available.height))
    }

    func show(_ model: ScreenRecordingCoordinator) {
        self.model = model
        if window == nil {
            let window = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 488, height: 540),
                                 styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered,
                                 defer: false)
            window.identifier = Self.identifier
            window.title = L("recording.title")
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
            window.isOpaque = false
            window.backgroundColor = .clear
            window.appearance = AppAppearance.nsAppearance(for: settings.appearanceMode)
            window.isReleasedWhenClosed = false
            window.hidesOnDeactivate = false
            window.level = .floating
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.delegate = self
            let hosting = NSHostingView(rootView: ScreenRecordingView(model: model, close: { [weak self] in
                self?.requestClose()
            }, chooseDirectory: { [weak self] in self?.chooseDirectory() }).interfaceStyle(following: interfaceStyle))
            hosting.sizingOptions = []
            hosting.autoresizingMask = [.width, .height]
            window.contentView = hosting
            window.minSize = CGSize(width: 460, height: 260)
            window.center()
            self.window = window
            stateObservation = model.$state.sink { [weak self] state in
                DispatchQueue.main.async {
                    guard let self, self.model?.state == state, let window = self.window else { return }
                    let available = window.screen?.visibleFrame.size ?? CGSize(width: 900, height: 800)
                    window.setContentSize(Self.contentSize(for: state,
                                                           available: CGSize(
                                                               width: available.width - 32,
                                                               height: available.height - 48
                                                           )))
                    window.setFrame(window.constrainFrameRect(window.frame, to: window.screen), display: true)
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
            alert.addButton(withTitle: L(model.state == .preview ? "recording.continueEditing" : "recording.keep"))
            alert.addButton(withTitle: L("recording.discard"))
            guard alert.runModal() == .alertSecondButtonReturn else { return }
        }
        model.cancel()
    }

    func chooseDirectory() {
        guard model?.canExport == true else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = L("recording.export")
        panel.directoryURL = model?.destinationDirectory
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
