import AppKit
import SwiftUI

/// Companion to the screenshot toast, with a draggable file thumbnail and recovery actions.
@MainActor
final class ScreenRecordingToastController {
    private(set) var panel: NSPanel?
    private let settings: SettingsStore
    private let interfaceStyle: InterfaceStyleObserver
    init(settings: SettingsStore? = nil, model: ScreenRecordingToastModel? = nil) {
        self.model = model ?? ScreenRecordingToastModel()
        let settings = settings ?? SettingsStore()
        self.settings = settings
        interfaceStyle = InterfaceStyleObserver(settings: settings)
        for name in [Notification.Name.authDidLogin, .authDidLogout, .authTokenDidRefresh] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.hide() }
            })
        }
    }
    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        hideWork?.cancel()
        let model = model, panel = panel
        if Thread.isMainThread { MainActor.assumeIsolated { model.retire(); panel?.orderOut(nil); panel?.contentView = nil } }
        else { Task { @MainActor in model.retire(); panel?.orderOut(nil); panel?.contentView = nil } }
    }

    private var hideWork: DispatchWorkItem?
    private var observers: [NSObjectProtocol] = []
    let model: ScreenRecordingToastModel
    var copyFile: (URL) -> Void = ScreenRecordingCoordinator.copyFile
    var revealFile: (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }
    var openFile: (URL) -> Void = { NSWorkspace.shared.open($0) }

    func showSaved(_ url: URL, thumbnail: CGImage?, duration: Double) {
        show(url, thumbnail: thumbnail, duration: duration, recovery: false)
    }
    func showRecovery(_ url: URL, open: @escaping () -> Void, discard: @escaping () -> Void) {
        show(url, thumbnail: nil, duration: 0, recovery: true, open: open, discard: discard)
    }
    private func show(_ url: URL, thumbnail: CGImage?, duration: Double, recovery: Bool,
                      open: @escaping () -> Void = {}, discard: @escaping () -> Void = {}) {
        hide()
        model.start(url, thumbnail: thumbnail)
        let view = ScreenRecordingToastView(model: model, duration: duration, recovery: recovery,
            close: { [weak self] in self?.hide() },
            open: { [weak self] _ in guard let self else { return }; self.hide(); open() },
            discard: { [weak self] _ in guard let self else { return }; self.hide(); discard() },
            reveal: { [weak self] in self?.revealFile($0) }, copy: { [weak self] in self?.copyFile($0) },
            openFile: { [weak self] in self?.openFile($0) })
        let panel = ScreenRecordingToastPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        let presentation = model.generation
        panel.retire = { [weak model] in
            guard let model, model.generation == presentation else { return }; model.retire()
        }
        panel.identifier = ScreenshotCaptureWindowPolicy.toastIdentifier
        panel.appearance = AppAppearance.nsAppearance(for: settings.appearanceMode)
        panel.level = .floating; panel.isOpaque = false; panel.backgroundColor = .clear
        // The rounded SwiftUI surface owns its shadow; a window shadow outlines the rectangular panel.
        panel.hasShadow = false; panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let host = NSHostingView(rootView: view.interfaceStyle(following: interfaceStyle))
        panel.contentView = host
        let size = CGSize(width: 440, height: 116)
        let area = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1000, height: 800)
        panel.setFrame(
            CGRect(x: area.maxX - size.width - 18, y: area.minY + 18, width: size.width, height: size.height),
            display: true
        )
        panel.orderFrontRegardless(); self.panel = panel
        let token = model.generation
        let work = DispatchWorkItem { [weak self] in
            guard let self, model.generation == token else { return }; hide()
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (recovery ? 12 : 10), execute: work)
    }

    func hide() {
        model.retire()
        hideWork?.cancel(); hideWork = nil
        panel?.orderOut(nil); panel?.contentView = nil; panel = nil
    }
}

struct ScreenRecordingToastView: View {
    @ObservedObject private var localization = AppLocalization.shared
    @ObservedObject var model: ScreenRecordingToastModel
    var duration: Double
    var recovery: Bool
    var close: () -> Void
    var open: (URL) -> Void = { _ in }
    var discard: (URL) -> Void = { _ in }
    var reveal: (URL) -> Void = { _ in }
    var copy: (URL) -> Void = { _ in }
    var openFile: (URL) -> Void = { _ in }
    var body: some View {
        if let url = model.url {
            let token = model.generation
        HStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                if let image = model.image {
                    Image(decorative: image, scale: 1).resizable().scaledToFill()
                } else {
                    Rectangle().fill(AskTheme.controlSurface).overlay(Image(systemName: "film"))
                }
                if !recovery {
                    Text(ScreenRecordingCoordinator.timeLabel(duration)).font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.white).padding(3).background(
                            .black.opacity(0.7),
                            in: RoundedRectangle(cornerRadius: 4)
                        ).padding(4)
                }
            }.frame(width: 108, height: 68).clipShape(RoundedRectangle(cornerRadius: 8))
                .onDrag { model.generation == token && model.ready ? NSItemProvider(object: url as NSURL) : NSItemProvider() }
            VStack(alignment: .leading, spacing: 5) {
                Label(
                    recovery ? L("recording.unsaved") : url.lastPathComponent,
                    systemImage: recovery ? "clock.arrow.circlepath" : "checkmark.circle.fill"
                )
                .font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(recovery ? L("recording.recoveryHint") : url.deletingLastPathComponent()
                    .lastPathComponent + " · " + ByteCountFormatter.string(
                        fromByteCount: model.fileBytes,
                        countStyle: .file
                    ))
                    .font(.system(size: 11.5)).foregroundStyle(StudioTheme.textTertiary).lineLimit(1)
                HStack(spacing: 6) {
                    if recovery {
                        Button(L("recording.openEditor")) { model.perform(generation: token, open) }
                        Button(L("recording.discard")) { model.perform(generation: token, discard) }
                        Button(L("recording.later")) { if model.generation == token { close() } }
                    } else {
                        Button(L("recording.reveal")) { model.perform(generation: token, reveal) }
                        Button(L("recording.copy")) { model.perform(generation: token, copy) }
                        Button(L("recording.open")) { model.perform(generation: token, openFile) }
                    }
                }.font(.system(size: 12)).buttonStyle(.borderless).disabled(!model.ready || model.busy)
            }
            Spacer(minLength: 0)
        }.padding(12).recordingSurface(corner: 14).padding(6)
            .overlay(alignment: .topTrailing) {
                Button(action: { if model.generation == token { close() } }) {
                    Image(systemName: "xmark").font(.system(size: 10)).foregroundStyle(StudioTheme.textTertiary)
                }
                .buttonStyle(.plain).padding(14).accessibilityLabel(L("recording.cancel"))
            }
        }
    }
}
