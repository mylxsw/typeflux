import AppKit
import SwiftUI

/// Companion to the screenshot toast, with a draggable file thumbnail and recovery actions.
@MainActor
final class ScreenRecordingToastController {
    private(set) var panel: NSPanel?
    private let settings: SettingsStore
    private let interfaceStyle: InterfaceStyleObserver
    init(settings: SettingsStore? = nil) {
        let settings = settings ?? SettingsStore()
        self.settings = settings
        interfaceStyle = InterfaceStyleObserver(settings: settings)
    }

    private var hideWork: DispatchWorkItem?
    func showSaved(_ url: URL, thumbnail: CGImage?, duration: Double) {
        show(
            ScreenRecordingToastView(url: url, thumbnail: thumbnail, duration: duration, recovery: false,
                                     close: { [weak self] in self?.hide() }),
            persistent: false
        )
    }

    func showRecovery(_ url: URL, open: @escaping () -> Void, discard: @escaping () -> Void) {
        show(
            ScreenRecordingToastView(url: url, thumbnail: nil, duration: 0, recovery: true, close: { [weak self] in
                self?.hide()
            }, open: { [weak self] in self?.hide(); open() },
            discard: { [weak self] in self?.hide(); discard() }),
            persistent: true
        )
    }

    private func show(_ view: ScreenRecordingToastView, persistent: Bool) {
        hide()
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.identifier = ScreenshotCaptureWindowPolicy.toastIdentifier
        panel.appearance = AppAppearance.nsAppearance(for: settings.appearanceMode)
        panel.level = .floating; panel.isOpaque = false; panel.backgroundColor = .clear
        panel.hasShadow = true; panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
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
        if !persistent {
            let work = DispatchWorkItem { [weak self] in self?.hide() }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: work)
        }
    }

    func hide() {
        hideWork?.cancel(); hideWork = nil
        panel?.orderOut(nil); panel?.contentView = nil; panel = nil
    }
}

struct ScreenRecordingToastView: View {
    @ObservedObject private var localization = AppLocalization.shared
    var url: URL
    var thumbnail: CGImage?
    var duration: Double
    var recovery: Bool
    var close: () -> Void
    var open: () -> Void = {}
    var discard: () -> Void = {}
    @State private var recoveredThumbnail: CGImage?
    var body: some View {
        HStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                if let image = thumbnail ?? recoveredThumbnail {
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
                .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider(object: url as NSURL) }
            VStack(alignment: .leading, spacing: 5) {
                Label(
                    recovery ? L("recording.unsaved") : url.lastPathComponent,
                    systemImage: recovery ? "clock.arrow.circlepath" : "checkmark.circle.fill"
                )
                .font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(recovery ? L("recording.recoveryHint") : url.deletingLastPathComponent()
                    .lastPathComponent + " · " + ByteCountFormatter.string(
                        fromByteCount: Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0),
                        countStyle: .file
                    ))
                    .font(.system(size: 11.5)).foregroundStyle(StudioTheme.textTertiary).lineLimit(1)
                HStack(spacing: 6) {
                    if recovery {
                        Button(L("recording.openEditor"), action: open)
                        Button(L("recording.discard"), action: discard)
                        Button(L("recording.later"), action: close)
                    } else {
                        Button(L("recording.reveal")) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        Button(L("recording.copy")) { ScreenRecordingCoordinator.copyFile(url) }
                        Button(L("recording.open")) { NSWorkspace.shared.open(url) }
                    }
                }.font(.system(size: 12)).buttonStyle(.borderless)
            }
            Spacer(minLength: 0)
        }.padding(12).recordingSurface(corner: 14).padding(6)
            .overlay(alignment: .topTrailing) {
                Button(action: close) {
                    Image(systemName: "xmark").font(.system(size: 10)).foregroundStyle(StudioTheme.textTertiary)
                }
                .buttonStyle(.plain).padding(14).accessibilityLabel(L("recording.cancel"))
            }
            .task(id: url) {
                guard thumbnail == nil else { return }
                let task = Task.detached { try ScreenRecordingPreviewMedia.thumbnail(url) }
                recoveredThumbnail = try? await withTaskCancellationHandler { try await task.value } onCancel: {
                    task.cancel()
                }
            }
    }
}
