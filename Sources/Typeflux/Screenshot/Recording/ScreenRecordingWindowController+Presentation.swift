import AppKit
import AVFoundation
import SwiftUI

extension ScreenRecordingWindowController {
    func render(_ state: ScreenRecordingCoordinator.State, focus: Bool = false) {
        guard let model else { return }
        let changed = lastState != state
        lastState = state
        switch state {
        case .setup, .countdown: presentSelection(state, changed: changed, focus: focus)
        case .preview, .exporting:
            let selectionHadFocus = selectionPanels.contains(where: \.isKeyWindow)
            dismissSelection()
            presentEditor(focus: focus || selectionHadFocus)
        case .starting, .recording, .paused, .stopping: dismissSelection(); presentCapsule(state, changed: changed)
        case .completed:
            if let url = model.savedURL {
                let image = model.media.thumbnails.first
                hide()
                toast.showSaved(url, thumbnail: image, duration: model.selectionDuration)
                model.finishSavedPresentation()
            }
        case .idle: hide()
        case .selecting: break
        }
        syncChrome()
    }

    func dismissSelection() {
        selectionPanels.forEach { $0.orderOut(nil) }
        selectionPanels = []; selectionViews = []
        permissionGuide.dismiss()
    }

    func presentSelection(_ state: ScreenRecordingCoordinator.State, changed: Bool, focus: Bool = false) {
        guard let model else { return }
        let shouldFocus = focus || selectionPanels.contains(where: \.isKeyWindow)
            || KeyboardFocusPolicy.shouldFocusReplacement(of: window)

        if selectionPanels.isEmpty {
            makeSelection()
        }
        if state == .setup {
            if changed || window == nil || window?.styleMask.contains(.titled) == true {
                window?.orderOut(nil)
                let area = activeScreen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1200, height: 800)
                let size = Self.contentSize(for: .setup, available: area.size)
                let panel = makePanel(frame: CGRect(
                    x: area.midX - size.width / 2,
                    y: area.minY + 12,
                    width: size.width,
                    height: size.height
                ))
                host(
                    ScreenRecordingToolbar(model: model, levelProvider: { [weak self] in
                        self?.preview.level ?? 0
                    }, close: { model.cancel() },
                    chooseDirectory: { [weak self] in self?.chooseDirectory() }),
                    in: panel, sizesToContent: true
                )
                window = panel
            }
            window?.orderFrontRegardless()
            if shouldFocus {
                selectionPanels.first?.makeKey()
                selectionPanels.first?.makeFirstResponder(selectionViews.first)
            }
            showPermissionGuideIfNeeded()
        } else {
            window?.orderOut(nil)
        }
    }

    func presentCapsule(_ state: ScreenRecordingCoordinator.State, changed: Bool) {
        guard let model else { return }

        if state == .starting && changed || window == nil {
            window?.orderOut(nil)
            let frame = appKitTargetFrame()
            let screen = screenForTarget()?.visibleFrame ?? NSScreen.main?.visibleFrame ?? frame
            let panel = makePanel(frame: ScreenRecordingLayout.capsule(
                target: frame,
                size: CGSize(width: 440, height: 82),
                screen: screen
            ))
            panel.isMovableByWindowBackground = true
            host(
                ScreenRecordingCapsule(model: model, levelProvider: { model.liveAudioLevel },
                                       close: { model.cancel() }),
                in: panel
            )
            window = panel
        }
        window?.orderFrontRegardless()
    }

    func presentEditor(focus: Bool = false) {
        guard let model else { return }
        let shouldFocus = focus || KeyboardFocusPolicy.shouldFocusReplacement(of: window)

        if window?.styleMask.contains(.titled) != true {
            window?.orderOut(nil)
            let area = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1000, height: 800)
            let size = Self.contentSize(
                for: .preview,
                available: CGSize(width: area.width - 32, height: area.height - 48)
            )
            let panel = ScreenRecordingPreviewPanel(
                contentRect: CGRect(origin: .zero, size: size),
                styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            panel.retire = { [weak model] in model?.retirePreview() }
            panel.animationBehavior = .none
            panel.identifier = Self.previewIdentifier
            panel.title = L("recording.previewTitle")
            panel.titleVisibility = .hidden; panel.titlebarAppearsTransparent = true; panel
                .titlebarSeparatorStyle = .none
            panel.isReleasedWhenClosed = false; panel.hidesOnDeactivate = false
            panel.isOpaque = false; panel.backgroundColor = .clear
            panel.minSize = CGSize(width: 760, height: 540)
            panel.delegate = self
            host(
                ScreenRecordingPreviewView(model: model, close: { [weak self] in
                    self?.requestClose()
                }, chooseDirectory: { [weak self] in self?.chooseDirectory() },
                saveAs: { [weak self] in self?.saveAs() }),
                in: panel
            )
            panel.center()
            if let previous = NSApp.orderedWindows.first(where: { $0.identifier == Self.previewIdentifier }) {
                panel.cascadeTopLeft(from: NSPoint(x: previous.frame.minX + 24, y: previous.frame.maxY - 24))
            }
            window = panel; applyAppearance()
            if keyMonitor == nil {
                keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    let handled = MainActor.assumeIsolated { self?.handleEditorKey(event) ?? false }
                    return handled ? nil : event
                }
            }
        }
        if shouldFocus {
            NSApp.activate(ignoringOtherApps: true)
            window?.makeKeyAndOrderFront(nil)
        } else if let window {
            KeyboardFocusPolicy.showWithoutTakingFocus(window)
        }
    }

    func makeSelection() {
        guard let model else { return }
        for screen in NSScreen.screens {
            let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            let frame = CGDisplayBounds(id)
            let panel = makePanel(frame: screen.frame)
            panel.level = .screenSaver
            panel.acceptsMouseMovedEvents = true
            let view = ScreenRecordingSelectionView(
                frame: frame,
                displayID: id,
                scale: screen.backingScaleFactor,
                model: model
            )
            view.activate = { [weak self, weak screen] in
                guard let self, let screen, activeScreen !== screen else { return }
                activeScreen = screen
                if let window {
                    let size = window.frame.size
                    window.setFrameOrigin(CGPoint(
                        x: screen.visibleFrame.midX - size.width / 2,
                        y: screen.visibleFrame.minY + 12
                    ))
                }
            }
            panel.contentView = view
            panel.orderFrontRegardless()
            selectionPanels.append(panel); selectionViews.append(view)
        }
    }

    func handleEditorKey(_ event: NSEvent) -> Bool {
        guard event.window === window, let model, model.state == .preview,
              !(window?.firstResponder is NSTextView) else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == [.command, .shift], event.charactersIgnoringModifiers?.lowercased() == "s" {
            saveAs(); return true
        }
        guard flags.isDisjoint(with: [.command, .control, .option]) else { return false }
        switch event.keyCode {
        case 53: requestClose(); return true
        case 123, 124:
            let step = flags.contains(.shift) ? 1 : 1 / Double(model.frameRate)
            model.seek(model.currentTime + (event.keyCode == 124 ? step : -step)); return true
        default: return Self.performEditorCharacter(event.charactersIgnoringModifiers?.lowercased(), on: model)
        }
    }

    /// Single-character editor shortcuts: Space, I/O trim points, [ ] speed.
    static func performEditorCharacter(_ character: String?, on model: ScreenRecordingCoordinator) -> Bool {
        switch character {
        case " ": model.togglePlayback()
        case "i": model.setTrimStart(model.currentTime)
        case "o": model.setTrimEnd(model.currentTime)
        case "[": model.stepRate(by: -1)
        case "]": model.stepRate(by: 1)
        default: return false
        }
        return true
    }

    func outline(_ target: ScreenRecordingTarget?) {
        border?.orderOut(nil); border = nil
        guard let target else { return }
        let frame: CGRect = if case let .region(_, rect) = target {
            ScreenCaptureGeometry.flipped(rect, primaryDisplayHeight: NSScreen.screens.first?.frame.height ?? 0)
        } else {
            appKitTargetFrame()
        }
        guard frame.width > 0 else { return }
        let panel = makePanel(frame: ScreenRecordingBorderView.panelFrame(around: frame), interactive: false)
        panel.contentView = ScreenRecordingBorderView()
        panel.orderFrontRegardless(); border = panel
    }

    func handleSelectionKey(_ event: NSEvent) -> Bool {
        guard let model, [.setup, .countdown].contains(model.state),
              event.window?.identifier == Self.identifier,
              !(event.window?.firstResponder is NSTextView) else { return false }
        switch event.keyCode {
        case 36: model.start()
        case 53: if model.state == .countdown {
                model.returnToSelection()
            } else {
                model.cancel()
            }
        case 49: if model.state == .countdown {
                model.skipCountdown()
            } else {
                return false
            }
        case 48:
            let modes: [ScreenRecordingSourceKind] = [.region, .window, .display]
            model.selectSourceKind(modes[((modes.firstIndex(of: model.sourceKind) ?? 0) + 1) % modes.count])
        default: return false
        }
        return true
    }

    func applyAppearance() {
        for panel in [window, border, cameraPanel].compactMap(\.self) + selectionPanels {
            panel.appearance = AppAppearance.nsAppearance(for: settings.appearanceMode)
        }
    }

    func screenForTarget() -> NSScreen? {
        let rect = appKitTargetFrame()
        return NSScreen.screens.first { $0.frame.contains(CGPoint(x: rect.midX, y: rect.midY)) } ?? activeScreen
    }

    func syncChrome() {
        guard let model else { return }
        selectionViews.forEach { $0.needsDisplay = true }
        if model.state == .setup {
            if model.permissionFailure == .permission {
                showPermissionGuideIfNeeded()
            } else {
                permissionGuide.dismiss()
                selectionPanels.forEach { $0.orderFrontRegardless() }
                window?.orderFrontRegardless()
                if let window, let view = window.contentView, let area = activeScreen?.visibleFrame {
                    let fitting = view.fittingSize
                    // Keep the last usable frame if SwiftUI has not produced a size yet.
                    if fitting.width.isFinite, fitting.height.isFinite, fitting.width > 0, fitting.height > 0 {
                        let size = CGSize(width: min(fitting.width, area.width - 24),
                                          height: min(fitting.height, area.height - 24))
                        let origin = CGPoint(
                            x: min(max(window.frame.midX - size.width / 2, area.minX + 12),
                                   area.maxX - size.width - 12),
                            y: min(max(window.frame.minY, area.minY + 12), area.maxY - size.height - 12)
                        )
                        let frame = CGRect(origin: origin, size: size)
                        if window.frame != frame {
                            window.setFrame(frame, display: true)
                        }
                    }
                }
            }
        }
        if [.setup, .countdown].contains(model.state) {
            if model.state == .setup, let denied = [
                (AVMediaType.audio, model.options.microphone && model.options.capturesAudio),
                (.video, model.options.camera)
            ].first(where: { item in
                item.1 && [.denied, .restricted].contains(preview.authorizationStatus(for: item.0))
            }) {
                model.reportDevicePermissionFailure(denied.0)
            }
            let flags = [
                model.options.camera && preview.authorizationStatus(for: .video) == .authorized,
                model.options.microphone && model.options.capturesAudio && preview
                    .authorizationStatus(for: .audio) == .authorized
            ]
            if flags != lastDeviceFlags {
                lastDeviceFlags = flags
                deviceTask?.cancel()
                deviceTask = Task { [preview] in await preview.configure(camera: flags[0], microphone: flags[1]) }
            }
        }
        if model.state == .recording || model.state == .paused {
            if case .window = model.selectedSource?.target, let border {
                border.setFrame(ScreenRecordingBorderView.panelFrame(around: appKitTargetFrame()), display: true)
            }
            (border?.contentView as? ScreenRecordingBorderView)?.paused = model.state == .paused
        }
        updateCamera()
    }
}
