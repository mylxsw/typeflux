import AppKit
import SwiftUI

/// The bar under the region while it scrolls: what is happening, the size so far, and
/// ␣ pause, ⌫ undo the last part, esc cancel, ↩ done.
struct ScrollCaptureBar: View {
    let state: ScrollCaptureViewState
    let actions: ScrollCaptureActions

    static func message(for state: ScrollCaptureViewState) -> String {
        if state.lastSegmentSuspicious { return L("screenshot.scroll.status.suspicious") }
        return switch state.status {
        case .starting: L("screenshot.scroll.status.starting")
        case .scrolling: L("screenshot.scroll.status.scrolling")
        case .paused: L("screenshot.scroll.status.paused")
        case .pausedByMouse: L("screenshot.scroll.status.pausedByMouse")
        case .misaligned: L("screenshot.scroll.status.misaligned")
        case .needsAccessibility: L("screenshot.scroll.status.needsAccessibility")
        }
    }

    /// "1280 × 5400 px", or nothing before the first frame.
    static func sizeText(for state: ScrollCaptureViewState) -> String? {
        guard state.pixelSize.width > 0 else { return nil }
        return "\(state.pixelSize.width) × \(state.pixelSize.height) px"
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: state.lastSegmentSuspicious ? "exclamationmark.triangle.fill"
                : "arrow.down.to.line.compact")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(state.lastSegmentSuspicious ? Color.orange : AskTheme.accent)
                .padding(.leading, 6)
            Text(Self.message(for: state))
                .font(.system(size: 12.5, weight: .medium))
                .lineLimit(1)
            if let size = Self.sizeText(for: state) {
                Text(size)
                    .font(.system(size: 11.5).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if state.status == .needsAccessibility {
                Button(L("screenshot.scroll.allow"), action: actions.openAccessibilitySettings)
                    .buttonStyle(.link)
                    .font(.system(size: 12.5, weight: .medium))
            }
            Rectangle().fill(AskTheme.border).frame(width: 1, height: 18).padding(.horizontal, 4)
            button(state.isAutomatic ? "pause.fill" : "play.fill",
                   title: L(state.isAutomatic ? "screenshot.scroll.pause" : "screenshot.scroll.resume"),
                   key: "␣", isEnabled: state.canToggleAutomatic, action: actions.togglePause)
            button("arrow.uturn.backward", title: L("screenshot.scroll.undo"), key: "⌫", isEnabled: state.canUndo,
                   action: actions.undo)
            button("xmark", title: L("screenshot.edit.cancel"), key: "esc", action: actions.cancel)
            Button(action: actions.finish) {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .bold))
                    Text(L("screenshot.scroll.done")).font(.system(size: 12.5, weight: .semibold))
                    Text("↩").font(.system(size: 11)).opacity(0.75)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 11)
                .frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 8).fill(AskTheme.accent))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(state.pixelSize.width == 0)
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(AskTheme.glassFill.opacity(0.96))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(AskTheme.border, lineWidth: 1))
        )
        .fixedSize()
    }

    private func button(_ symbol: String, title: String, key: String, isEnabled: Bool = true,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 12, weight: .medium))
                Text(key).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .foregroundStyle(Color.primary.opacity(0.8))
            .padding(.horizontal, 8)
            .frame(height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.35)
        .help("\(title)  \(key)")
    }
}

/// Holds the bar and takes its keys, so ␣ ⌫ esc ↩ work while the bar's panel is key.
@MainActor
final class ScrollCaptureBarView: NSView {
    var actions: ScrollCaptureActions?
    private(set) var state = ScrollCaptureViewState()
    private let host = NSHostingView(rootView: AnyView(EmptyView()))

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        host.autoresizingMask = [.width, .height]
        host.frame = bounds
        addSubview(host)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The bar's size for `state`.
    func show(_ state: ScrollCaptureViewState) -> CGSize {
        self.state = state
        guard let actions else { return .zero }
        host.rootView = AnyView(ScrollCaptureBar(state: state, actions: actions))
        return host.fittingSize
    }

    override func keyDown(with event: NSEvent) {
        if !handleKey(event.keyCode) { super.keyDown(with: event) }
    }

    /// - Returns: whether the key meant something here.
    @discardableResult
    func handleKey(_ keyCode: UInt16) -> Bool {
        guard let actions else { return false }
        switch keyCode {
        case ScreenshotOverlayView.Key.space:
            if state.canToggleAutomatic { actions.togglePause() }
        case ScreenshotOverlayView.Key.delete, ScreenshotOverlayView.Key.forwardDelete:
            if state.canUndo { actions.undo() }
        case ScreenshotOverlayView.Key.escape:
            actions.cancel()
        case ScreenshotOverlayView.Key.returnKey, ScreenshotOverlayView.Key.enter:
            if state.pixelSize.width > 0 { actions.finish() }
        default:
            return false
        }
        return true
    }
}
