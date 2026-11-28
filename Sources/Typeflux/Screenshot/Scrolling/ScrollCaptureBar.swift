import AppKit
import SwiftUI

@MainActor
final class ScrollCaptureBarModel: ObservableObject {
    @Published var state: ScrollCaptureViewState

    init(state: ScrollCaptureViewState = ScrollCaptureViewState()) {
        self.state = state
    }
}

/// The bar under the region while it scrolls: what is happening, the size so far, and
/// ␣ pause, ⌫ undo the last part, esc cancel, ↩ done.
struct ScrollCaptureBar: View {
    @ObservedObject var model: ScrollCaptureBarModel
    let actions: ScrollCaptureActions

    private var state: ScrollCaptureViewState { model.state }

    init(state: ScrollCaptureViewState, actions: ScrollCaptureActions) {
        self.init(model: ScrollCaptureBarModel(state: state), actions: actions)
    }

    init(model: ScrollCaptureBarModel, actions: ScrollCaptureActions) {
        self.model = model
        self.actions = actions
    }

    static func message(for state: ScrollCaptureViewState) -> String {
        if state.status == .finishing {
            return L("screenshot.scroll.status.finishing")
        }
        if state.lastSegmentSuspicious {
            return L("screenshot.scroll.status.suspicious")
        }
        return switch state.status {
        case .starting: L("screenshot.scroll.status.starting")
        case .manual: L("screenshot.scroll.status.manual")
        case .scrolling: L("screenshot.scroll.status.scrolling")
        case .paused: L("screenshot.scroll.status.paused")
        case .pausedByMouse: L("screenshot.scroll.status.pausedByMouse")
        case .misaligned: L("screenshot.scroll.status.misaligned")
        case .needsAccessibility: L("screenshot.scroll.status.needsAccessibility")
        case .finishing: L("screenshot.scroll.status.finishing")
        }
    }

    /// "1280 × 5400 px", or nothing before the first frame.
    static func sizeText(for state: ScrollCaptureViewState) -> String? {
        guard state.pixelSize.width > 0 else { return nil }
        return "\(state.pixelSize.width) × \(state.pixelSize.height) px"
    }

    var body: some View {
        HStack(spacing: 6) {
            if state.status == .finishing {
                ProgressView()
                    .controlSize(.small)
                    .padding(.leading, 6)
            } else {
                Image(systemName: state.lastSegmentSuspicious ? "exclamationmark.triangle.fill"
                    : (state.axis == .horizontal ? "arrow.right.to.line.compact" : "arrow.down.to.line.compact"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(state.lastSegmentSuspicious ? Color.orange : AskTheme.accent)
                    .padding(.leading, 6)
            }
            Text(Self.message(for: state))
                .font(.system(size: 12.5, weight: .medium))
                .lineLimit(1)
            if let size = Self.sizeText(for: state) {
                Text(size)
                    .font(.system(size: 11.5).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            if state.status == .needsAccessibility {
                Button(L("screenshot.scroll.allow"), action: actions.openAccessibilitySettings)
                    .buttonStyle(.link)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            Rectangle().fill(AskTheme.border).frame(width: 1, height: 18).padding(.horizontal, 4)
            button(state.isAutomatic ? "pause.fill" : "play.fill",
                   title: L(state.isAutomatic ? "screenshot.scroll.pause" : "screenshot.scroll.automatic"),
                   key: "␣", showsTitle: true, isEnabled: state.canToggleAutomatic, action: actions.togglePause)
            button("arrow.uturn.backward", title: L("screenshot.scroll.undo"), key: "⌫", isEnabled: state.canUndo,
                   action: actions.undo)
            button("xmark", title: L("screenshot.edit.cancel"), key: "esc", action: actions.cancel)
            Button(action: actions.finish) {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .bold))
                    Text(L("screenshot.scroll.done"))
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                    Text("↩").font(.system(size: 11)).opacity(0.75)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 11)
                .frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 8).fill(AskTheme.accent))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!state.canFinish)
            .opacity(state.canFinish || state.status == .finishing ? 1 : 0.5)
        }
        .padding(4)
        .screenshotSurface(corner: 12, elevation: nil, placement: .floating)
        .fixedSize()
    }

    private func button(_ symbol: String, title: String, key: String, showsTitle: Bool = false, isEnabled: Bool = true,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 12, weight: .medium))
                if showsTitle {
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
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
    var actions: ScrollCaptureActions? {
        didSet { measuredSize = nil }
    }
    private let model = ScrollCaptureBarModel()
    private var measuredSize: CGSize?
    private let host = NSHostingView(rootView: AnyView(EmptyView()))

    var state: ScrollCaptureViewState { model.state }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        host.autoresizingMask = [.width, .height]
        host.frame = bounds
        addSubview(host)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
        true
    }

    /// The bar's size for `state`.
    func show(_ state: ScrollCaptureViewState) -> CGSize {
        let previous = model.state
        if previous != state {
            model.state = state
        }
        guard let actions else { return .zero }
        // The size label uses monospaced digits. Its content can update without measuring the
        // hosting view or moving the panel until the number of digits changes.
        if let measuredSize, Self.sameLayout(previous, state) {
            return measuredSize
        }
        host.rootView = AnyView(ScrollCaptureBar(model: model, actions: actions).screenshotAppearance())
        let size = host.fittingSize
        measuredSize = size
        return size
    }

    private static func sameLayout(_ previous: ScrollCaptureViewState, _ current: ScrollCaptureViewState) -> Bool {
        var withUpdatedSize = previous
        withUpdatedSize.pixelSize = current.pixelSize
        return withUpdatedSize == current
            && ScrollCaptureBar.sizeText(for: previous)?.count == ScrollCaptureBar.sizeText(for: current)?.count
    }

    override func keyDown(with event: NSEvent) {
        if !handleKey(event.keyCode) {
            super.keyDown(with: event)
        }
    }

    /// - Returns: whether the key meant something here.
    @discardableResult
    func handleKey(_ keyCode: UInt16) -> Bool {
        guard let actions else { return false }
        switch keyCode {
        case ScreenshotOverlayView.Key.space:
            if state.canToggleAutomatic {
                actions.togglePause()
            }
        case ScreenshotOverlayView.Key.delete, ScreenshotOverlayView.Key.forwardDelete:
            if state.canUndo {
                actions.undo()
            }
        case ScreenshotOverlayView.Key.escape:
            actions.cancel()
        case ScreenshotOverlayView.Key.returnKey, ScreenshotOverlayView.Key.enter:
            if state.canFinish {
                actions.finish()
            }
        default:
            return false
        }
        return true
    }
}
