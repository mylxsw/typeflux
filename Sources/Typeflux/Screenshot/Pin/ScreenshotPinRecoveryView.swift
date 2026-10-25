import AppKit
import SwiftUI

/// Controls that stay clickable above a mouse-transparent pin, including very small pins.
@MainActor
final class ScreenshotPinRecoveryView: NSView {
    static let size = CGSize(width: 62, height: 30)

    var onRestore: (() -> Void)?
    var onClose: (() -> Void)?
    let restoreButton = NSButton()
    let closeButton = NSButton()

    init(settingsStore: SettingsStore = SettingsStore()) {
        super.init(frame: CGRect(origin: .zero, size: Self.size))
        let background = NSHostingView(rootView: StyledGlassShapeBackground(
            shape: RoundedRectangle(cornerRadius: 9), cornerRadius: 9,
            opaqueFill: AskTheme.popoverSurface, placement: .floating
        ).interfaceStyle(following: InterfaceStyleObserver(settings: settingsStore)))
        background.frame = bounds
        background.autoresizingMask = [.width, .height]
        addSubview(background)

        configure(restoreButton, symbol: "cursorarrow", label: L("menu.pins.restoreMouse"),
                  action: #selector(restoreMouse), x: 3)
        configure(closeButton, symbol: "xmark", label: L("screenshot.pin.close"),
                  action: #selector(closePin), x: 33)
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

    override var mouseDownCanMoveWindow: Bool {
        false
    }

    override func keyDown(with event: NSEvent) {
        typealias Key = ScreenshotOverlayView.Key
        switch event.keyCode {
        case Key.escape, Key.delete, Key.forwardDelete: onClose?()
        default: super.keyDown(with: event)
        }
    }

    private func configure(_ button: NSButton, symbol: String, label: String, action: Selector, x: CGFloat) {
        button.frame = CGRect(x: x, y: 3, width: 26, height: 24)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.target = self
        button.action = action
        addSubview(button)
    }

    @objc private func restoreMouse() {
        onRestore?()
    }

    @objc private func closePin() {
        onClose?()
    }
}
