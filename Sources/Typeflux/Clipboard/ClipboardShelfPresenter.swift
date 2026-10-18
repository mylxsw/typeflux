import AppKit
import Combine
import SwiftUI

/// The window side of the clipboard shelf, for `ClipboardPanelController`: places the panel
/// along the bottom of the screen, slides it in, grows it while an editor is open, and keeps the
/// preview window above the selected card.
@MainActor
final class ClipboardShelfPresenter {
    /// Where the selected card is; the shelf view writes it, the preview follows it.
    let layout = ClipboardShelfLayout()
    private weak var panel: NSWindow?
    private weak var model: ClipboardPanelModel?
    /// Slides the shelf up from just below its final frame while fading it in.
    private let animator = AskLauncherHeightAnimator()
    /// The shelf's settled frame; the slide and the editor growth both aim for it.
    private(set) var frame: NSRect?
    private var previewWindow: ClipboardShelfPreviewWindow?
    private var previewRoot: ((ClipboardPanelModel) -> AnyView)?
    private var observations: [AnyCancellable] = []
    private var updateScheduled = false

    /// The preview while it is on screen.
    var presentedPreviewWindow: NSWindow? {
        previewWindow?.isVisible == true ? previewWindow : nil
    }

    /// Shows `panel` (whose content view hosts the shelf) as the shelf; the preview window takes
    /// the panel's appearance and its content from `previewRoot`.
    func present(
        _ panel: NSWindow, model: ClipboardPanelModel, screen: NSScreen?, animated: Bool,
        previewRoot: @escaping (ClipboardPanelModel) -> AnyView
    ) {
        dismiss()
        self.panel = panel
        self.model = model
        self.previewRoot = previewRoot
        let frame = ClipboardPanelPlacement.shelfFrame(
            height: ClipboardShelfView.height, screen: screen?.visibleFrame ?? panel.frame
        )
        self.frame = frame
        place(panel, shelf: frame, progress: animated ? 0 : 1)
        panel.makeKeyAndOrderFront(nil)
        animator.update(
            from: 0, to: 1, animated: animated, framesPerSecond: screen?.maximumFramesPerSecond ?? 60, rate: 22
        ) { [weak self, weak panel] progress in
            guard let self, let panel, panel.isVisible, let frame = self.frame else { return }
            place(panel, shelf: frame, progress: progress)
        }
        observe(model)
    }

    func dismiss() {
        animator.stop()
        observations = []
        hidePreview()
    }

    /// A scroll over the visible shelf. Returns whether it moved the selection.
    func handleScroll(deltaX: CGFloat, deltaY: CGFloat, isPrecise: Bool) -> Bool {
        guard let panel, panel.isVisible, let model,
              model.editingText == nil, model.snippetDraft == nil, model.pendingConfirmation == nil,
              let delta = ClipboardShelfScroll.selectionDelta(deltaX: deltaX, deltaY: deltaY, isPrecise: isPrecise)
        else { return false }
        model.moveSelection(by: delta)
        return true
    }

    /// `progress` 0 is the start of the slide, slightly low and transparent; 1 is in place.
    private func place(_ panel: NSWindow, shelf frame: NSRect, progress: CGFloat) {
        let clamped = min(max(progress, 0), 1)
        let offset = -ClipboardShelfScroll.slideDistance * (1 - clamped)
        panel.setFrame(frame.offsetBy(dx: 0, dy: offset), display: false)
        panel.alphaValue = clamped
        panel.contentView?.frame = NSRect(origin: .zero, size: frame.size)
    }

    /// `@Published` fires before the value changes, so the windows are updated on the next run
    /// loop turn, once per burst of changes.
    private func observe(_ model: ClipboardPanelModel) {
        let schedule: (Any) -> Void = { [weak self] _ in self?.scheduleUpdate() }
        observations = [
            model.$showsPreview.sink(receiveValue: schedule),
            model.$selectedIndex.sink(receiveValue: schedule),
            model.$visibleEntries.sink(receiveValue: schedule),
            model.$editingText.sink(receiveValue: schedule),
            model.$snippetDraft.sink(receiveValue: schedule),
            layout.$selectedCardMidX.sink(receiveValue: schedule)
        ]
    }

    private func scheduleUpdate() {
        guard !updateScheduled else { return }
        updateScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            updateScheduled = false
            update()
        }
    }

    /// Fits the shelf to an open editor, then shows the preview above the selected card, or
    /// hides it while editing.
    private func update() {
        resizeForEditors()
        guard let panel, panel.isVisible, let model, let frame,
              model.showsPreview, model.selectedEntry != nil,
              model.editingText == nil, model.snippetDraft == nil else {
            hidePreview()
            return
        }
        let window = preview(for: model)
        let screen = (panel.screen ?? NSScreen.main)?.visibleFrame ?? frame
        window.setFrame(ClipboardPanelPlacement.shelfPreviewFrame(
            size: ClipboardShelfPreview.size, shelf: frame,
            cardMidX: layout.selectedCardMidX ?? frame.width / 2, screen: screen
        ), display: true)
        if window.parent == nil {
            panel.addChildWindow(window, ordered: .above)
        }
        window.orderFront(nil)
    }

    /// The snippet editor and edit-before-paste are taller than the shelf, which grows upward
    /// while one is open and returns to its height afterwards.
    private func resizeForEditors() {
        guard let panel, panel.isVisible, let model, let current = frame else { return }
        let editing = model.editingText != nil || model.snippetDraft != nil
        let height = editing ? ClipboardShelfView.editingHeight : ClipboardShelfView.height
        guard current.height != height else { return }
        let screen = (panel.screen ?? NSScreen.main)?.visibleFrame ?? current
        let next = ClipboardPanelPlacement.shelfFrame(height: height, screen: screen)
        frame = next
        if !animator.isAnimating {
            place(panel, shelf: next, progress: 1)
        }
    }

    private func hidePreview() {
        guard let window = previewWindow else { return }
        window.parent?.removeChildWindow(window)
        window.orderOut(nil)
    }

    private func preview(for model: ClipboardPanelModel) -> ClipboardShelfPreviewWindow {
        let rootView = previewRoot?(model) ?? AnyView(EmptyView())
        if let window = previewWindow, let host = window.contentView as? NSHostingView<AnyView> {
            host.rootView = rootView
            window.appearance = panel?.appearance
            return window
        }
        let window = ClipboardShelfPreviewWindow(
            contentRect: NSRect(origin: .zero, size: ClipboardShelfPreview.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.level = .floating
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        window.identifier = NSUserInterfaceItemIdentifier("ai.gulu.app.typeflux.window.clipboard.preview")
        window.appearance = panel?.appearance
        let host = NSHostingView(rootView: rootView)
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: ClipboardShelfPreview.size)
        host.autoresizingMask = [.width, .height]
        window.contentView = host
        previewWindow = window
        return window
    }
}

/// The shelf's preview floats above it without taking keyboard focus from the search field.
final class ClipboardShelfPreviewWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
