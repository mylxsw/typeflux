import AppKit

/// A transparent native sheet keeps SwiftUI hit testing and shortcuts out of the background.
@MainActor final class AskTablePreviewOverlay: NSView {
    private let content: NSAttributedString
    private let columns: Int
    private let card = NSView()
    let scrollView = NSScrollView()
    let textView = TextView()
    private let zoomLabel = NSTextField(labelWithString: "120%")
    private let controls = NSStackView()
    private let closeButton: NSButton
    private weak var previousResponder: NSResponder?
    private weak var owner: NSWindow?
    private var panel: Panel?
    private var sheetPositioning: AskTableSheetPositioning?
    private var windowObservers: [NSObjectProtocol] = []
    private(set) var zoom: CGFloat = 1.2
    var onClose: (() -> Void)?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init(content: NSAttributedString, columns: Int, onOpenLink: ((URL, Bool) -> Void)?) {
        self.content = content
        self.columns = columns
        closeButton = NSButton()
        super.init(frame: .zero)
        setAccessibilityRole(.group)
        setAccessibilitySubrole(.dialog)
        setAccessibilityLabel(L("ask.preview.kind.table"))
        wantsLayer = true
        card.wantsLayer = true
        card.layer?.cornerRadius = 18
        card.layer?.borderWidth = 0.5
        addSubview(card)
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 24, height: 24)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.replaceLayoutManager(AskRoundedBackgroundLayoutManager())
        textView.onOpenLink = onOpenLink
        textView.onClose = { [weak self] in self?.close() }
        scrollView.documentView = textView
        card.addSubview(scrollView)
        controls.orientation = .horizontal
        controls.spacing = 8
        controls.addArrangedSubview(AskTranscriptTableInteraction.button(
            "minus.magnifyingglass", title: L("screenshot.pin.zoomOut"), target: self, action: #selector(zoomOut)))
        zoomLabel.alignment = .center
        zoomLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        zoomLabel.widthAnchor.constraint(equalToConstant: 46).isActive = true
        controls.addArrangedSubview(zoomLabel)
        controls.addArrangedSubview(AskTranscriptTableInteraction.button(
            "plus.magnifyingglass", title: L("screenshot.pin.zoomIn"), target: self, action: #selector(zoomIn)))
        card.addSubview(controls)
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: L("ask.artifact.close"))
        closeButton.target = self
        closeButton.action = #selector(close)
        closeButton.isBordered = false
        closeButton.toolTip = L("ask.artifact.close") + " (Esc)"
        closeButton.setAccessibilityLabel(L("ask.artifact.close"))
        addSubview(closeButton)
        applyZoom()
    }

    required init?(coder: NSCoder) { nil }

    func present(in owner: NSWindow) {
        guard panel == nil, owner.attachedSheet == nil, owner.contentView != nil else { return }
        self.owner = owner
        previousResponder = owner.firstResponder
        let panel = Panel(contentRect: owner.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.level = owner.level
        panel.appearance = owner.effectiveAppearance
        panel.animationBehavior = .none
        panel.onClose = { [weak self] in self?.close() }
        panel.contentView = self
        self.panel = panel
        let positioning = AskTableSheetPositioning(sheet: panel, original: owner.delegate)
        sheetPositioning = positioning
        owner.delegate = positioning
        owner.beginSheet(panel)
        synchronizeFrame()
        layoutSubtreeIfNeeded()
        // The key-view loop belongs to the sheet, so Tab cannot focus the composer or sidebar.
        let buttons = controls.arrangedSubviews.compactMap { $0 as? NSButton }
        closeButton.nextKeyView = buttons.first
        buttons.first?.nextKeyView = buttons.last
        buttons.last?.nextKeyView = textView
        textView.nextKeyView = closeButton
        panel.makeFirstResponder(textView)
        for name in [NSWindow.didResizeNotification, NSWindow.didMoveNotification] {
            windowObservers.append(NotificationCenter.default.addObserver(
                forName: name, object: owner, queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.synchronizeFrame() } })
        }
        windowObservers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: owner, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.close() } })
    }

    private func synchronizeFrame() {
        guard let panel, let owner, panel.sheetParent === owner else { return }
        panel.setFrame(owner.frame, display: true)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.72).setFill()
        dirtyRect.fill()
    }

    override func layout() {
        super.layout()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            card.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            card.layer?.borderColor = NSColor.separatorColor.cgColor
        }
        let width = max(100, min(bounds.width - 80, max(760, CGFloat(columns) * 200)))
        let availableHeight = max(80, bounds.height - 120)
        let textWidth = max(width - 48, CGFloat(columns) * 160 * zoom)
        textView.textContainer?.containerSize = NSSize(width: textWidth, height: .greatestFiniteMagnitude)
        if let container = textView.textContainer { textView.layoutManager?.ensureLayout(for: container) }
        let textHeight = ceil(textView.layoutManager?.usedRect(for: textView.textContainer!).height ?? 0) + 48
        let height = min(availableHeight, textHeight + 46)
        card.frame = NSRect(x: (bounds.width - width) / 2, y: (bounds.height - height) / 2,
                            width: width, height: height)
        // The card is unflipped: controls occupy its top edge.
        controls.frame = NSRect(x: width - 154, y: height - 40, width: 138, height: 30)
        scrollView.frame = NSRect(x: 0, y: 0, width: width, height: max(30, height - 46))
        textView.frame = NSRect(x: 0, y: 0, width: textWidth + 48,
                                height: max(textHeight, scrollView.contentSize.height))
        closeButton.frame = NSRect(x: bounds.width - 54, y: 14, width: 36, height: 36)
    }

    func setZoom(_ value: CGFloat) {
        zoom = min(2, max(0.8, value))
        applyZoom()
    }

    private func applyZoom() {
        let value = NSMutableAttributedString(attributedString: content)
        content.enumerateAttribute(.font, in: NSRange(location: 0, length: content.length)) { font, range, _ in
            guard let font = font as? NSFont else { return }
            value.addAttribute(.font, value: NSFontManager.shared.convert(font, toSize: font.pointSize * zoom), range: range)
        }
        textView.textStorage?.setAttributedString(value)
        zoomLabel.stringValue = "\(Int((zoom * 100).rounded()))%"
        needsLayout = true
    }

    @objc private func zoomIn() { setZoom(zoom + 0.2) }
    @objc private func zoomOut() { setZoom(zoom - 0.2) }

    override func mouseDown(with event: NSEvent) {
        if !card.frame.contains(convert(event.locationInWindow, from: nil)) { close() }
    }

    override func cancelOperation(_ sender: Any?) { close() }

    // Events at the backdrop or the table's scroll limits stop in this sheet.
    override func scrollWheel(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}

    @objc func close() {
        for observer in windowObservers { NotificationCenter.default.removeObserver(observer) }
        windowObservers.removeAll()
        if let panel {
            panel.sheetParent?.endSheet(panel)
            panel.orderOut(nil)
            panel.contentView = nil
            panel.onClose = nil
            self.panel = nil
        }
        if let sheetPositioning, owner?.delegate === sheetPositioning {
            owner?.delegate = sheetPositioning.original
        }
        sheetPositioning = nil
        if let previousResponder { owner?.makeFirstResponder(previousResponder) }
        previousResponder = nil
        owner = nil
        onClose?()
        onClose = nil
    }

    final class TextView: NSTextView {
        var onOpenLink: ((URL, Bool) -> Void)?
        var onClose: (() -> Void)?
        override func cancelOperation(_ sender: Any?) { onClose?() }
        override func insertTab(_ sender: Any?) { window?.selectNextKeyView(sender) }
        override func insertBacktab(_ sender: Any?) { window?.selectPreviousKeyView(sender) }
        override func clicked(onLink link: Any, at charIndex: Int) {
            guard let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:)) else { return }
            if let onOpenLink {
                onOpenLink(url, NSApp.currentEvent?.modifierFlags.contains(.command) == true)
            } else if url.scheme?.lowercased() != AskLinkRouter.fileScheme {
                super.clicked(onLink: link, at: charIndex)
            }
        }
    }

    private final class Panel: NSPanel {
        var onClose: (() -> Void)?
        override var canBecomeKey: Bool { true }
        override func cancelOperation(_ sender: Any?) { onClose?() }
        override func performClose(_ sender: Any?) { onClose?() }
    }
}
