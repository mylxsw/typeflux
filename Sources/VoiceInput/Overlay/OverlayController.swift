import AppKit
import SwiftUI

final class OverlayController {
    private let appState: AppStateStore
    private var window: NSPanel?

    private let model = OverlayViewModel()

    init(appState: AppStateStore) {
        self.appState = appState
    }

    func show() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.show() }
            return
        }
        if window == nil {
            let view = OverlayView(model: model)
            let hosting = NSHostingView(rootView: view)

            let panel = NSPanel(
                contentRect: NSRect(
                    x: 0,
                    y: 0,
                    width: StudioTheme.Layout.overlayWidth,
                    height: StudioTheme.Layout.overlayHeight
                ),
                styleMask: [.nonactivatingPanel, .borderless],
                backing: .buffered,
                defer: false
            )
            panel.isFloatingPanel = true
            panel.level = .statusBar
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.isOpaque = false
            panel.ignoresMouseEvents = true
            panel.collectionBehavior = [.canJoinAllSpaces, .transient]
            panel.contentView = hosting

            window = panel
        }

        positionWindow()
        window?.orderFrontRegardless()
        model.statusText = "正在输入中"
    }

    func showProcessing() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.showProcessing() }
            return
        }
        show()
        model.statusText = "转写中"
    }

    func showFailure(message: String) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.showFailure(message: message) }
            return
        }
        show()
        model.statusText = "失败"
        model.detailText = message
    }

    func updateLevel(_ level: Float) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.updateLevel(level) }
            return
        }
        model.level = level
    }

    func updateStreamingText(_ text: String) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.updateStreamingText(text) }
            return
        }
        model.detailText = text
    }

    func dismissSoon() {
        dismiss(after: StudioTheme.Durations.overlayDismissDelay)
    }

    func dismiss(after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.window?.orderOut(nil)
            self?.model.detailText = ""
            self?.model.level = 0
        }
    }

    private func positionWindow() {
        guard let screen = NSScreen.main, let window else { return }
        let frame = screen.visibleFrame
        let size = window.frame.size
        let x = frame.midX - size.width / 2
        let y = frame.minY + StudioTheme.Layout.overlayBottomOffset
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

final class OverlayViewModel: ObservableObject {
    @Published var statusText: String = ""
    @Published var detailText: String = ""
    @Published var level: Float = 0
}

private struct OverlayView: View {
    @ObservedObject var model: OverlayViewModel

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.overlay)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.overlay)
                        .stroke(StudioTheme.Colors.white.opacity(StudioTheme.Opacity.overlayStroke), lineWidth: StudioTheme.BorderWidth.thin)
                )

            HStack(spacing: StudioTheme.Spacing.smallMedium) {
                VStack(alignment: .leading, spacing: StudioTheme.Spacing.xxSmall) {
                    Text(model.statusText)
                        .font(.headline)
                    if !model.detailText.isEmpty {
                        Text(model.detailText)
                            .font(.caption)
                            .lineLimit(StudioTheme.LineLimit.detail)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: StudioTheme.Insets.none)
                LevelBar(level: model.level)
                    .frame(width: StudioTheme.ControlSize.overlayLevelWidth, height: StudioTheme.ControlSize.overlayLevelHeight)
            }
            .padding(StudioTheme.Insets.overlay)
        }
        .frame(width: StudioTheme.Layout.overlayWidth, height: StudioTheme.Layout.overlayHeight)
    }
}

private struct LevelBar: View {
    let level: Float

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.meter)
                    .fill(StudioTheme.Colors.white.opacity(StudioTheme.Opacity.overlayTrack))
                RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.meter)
                    .fill(StudioTheme.Colors.overlayLevel.opacity(StudioTheme.Opacity.overlayLevel))
                    .frame(width: geo.size.width * CGFloat(max(0, min(1, level))))
            }
        }
    }
}
