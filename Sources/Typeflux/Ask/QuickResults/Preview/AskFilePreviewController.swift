import AppKit
import QuartzCore
import SwiftUI

@MainActor
final class AskFilePreviewState: ObservableObject {
    @Published var imageAccess = AskImagePresentationAccess()
    @Published var hit: AskFileHit?
    @Published var content: AskFilePreviewContent?
    @Published var contentID = UUID()
    @Published var detail: String?
    @Published var skeleton = false
}

/// Owns one panel and the selection clock. Every delayed callback belongs to a selection generation.
@MainActor
final class AskFilePreviewController: AskImageScopeObserver {
    let state = AskFilePreviewState()
    private(set) var isVisible = false
    private(set) var panel: NSPanel?
    private weak var parent: NSWindow?
    private let loader: any AskFilePreviewLoading
    private let clock: any AskFilePreviewClock
    private let reduceMotion: () -> Bool
    private var debounce: AskFilePreviewTimer?
    private var skeleton: AskFilePreviewTimer?
    private var grace: AskFilePreviewTimer?
    private var hideCompletion: AskFilePreviewTimer?
    private var generation = 0
    private var motionGeneration = 0
    private var selected: AskFileHit?
    private var placement: AskFilePreviewPlacement?
    private var observers: [NSObjectProtocol] = []
    private var style: InterfaceStyleObserver?
    private let imageScope = AskImagePresentationScope()
    private var originalAccess: AskImagePresentationAccess?
    private var accessRegistration: UUID?

    private func retireImageAccess() {
        // Cached private content cannot cross selection, visibility or authorization epochs.
        loader.clearCache()
        imageScope.setVisible(false); state.imageAccess = .init()
        if let accessRegistration { originalAccess?.scope?.remove(accessRegistration) }
        accessRegistration = nil; originalAccess = nil
    }

    private func showImageAccess() {
        guard let originalAccess, originalAccess.allows(), selected != nil else { return }
        imageScope.setVisible(true)
        let requiresParent = parent != nil
        state.imageAccess = .init(scope: imageScope, epoch: imageScope.epoch,
            authorize: { [weak self] in
                guard let self else { return false }
                return isVisible && (!requiresParent || parent?.isVisible == true) && originalAccess.allows()
            })
    }

    /// Upstream account, selection and launcher visibility revoke this separate panel too.
    func cancel() { dismissNow() }

    var pixels = CGSize(width: 720, height: 900)

    init(loader: (any AskFilePreviewLoading)? = nil,
         clock: any AskFilePreviewClock = AskFilePreviewSystemClock(),
         reduceMotion: @escaping () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }) {
        self.loader = loader ?? AskFilePreviewLoader(); self.clock = clock; self.reduceMotion = reduceMotion
    }

    func attach(to parent: NSWindow, style: InterfaceStyleObserver) {
        self.parent = parent; self.style = style
        observers.forEach(NotificationCenter.default.removeObserver); observers = []
        for name in [NSWindow.didMoveNotification, NSWindow.didChangeScreenNotification] {
            observers
                .append(NotificationCenter.default
                    .addObserver(forName: name, object: parent, queue: .main) { [weak self] _ in
                        MainActor.assumeIsolated { self?.updateFrame() }
                    })
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: parent,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismissNow() }
        })
        for name in [AskFloatingPanel.willOrderOut, NSWindow.willCloseNotification, NSWindow.didChangeOcclusionStateNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: parent, queue: .main) { [weak self] notification in
                MainActor.assumeIsolated {
                    if notification.name != NSWindow.didChangeOcclusionStateNotification || self?.parent?.isVisible == false { self?.dismissNow() }
                }
            })
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: AskQuickLook.willShow,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismissNow() }
        })
        updateFrame()
    }

    func request(_ hit: AskFileHit?, neighbours: [AskFileHit] = [], empty: Bool = false, access: AskImagePresentationAccess? = nil) {
        if originalAccess?.allows() == false { dismissNow() }
        guard !empty, access?.allows() != false else { dismissNow(); return }
        if access?.epoch == originalAccess?.epoch, let hit, hit.path == selected?.path, hit.modified == selected?.modified,
           hit.evidence == selected?.evidence {
            // Rank changes can reuse the image; a different matched page or passage must render again.
            selected = hit; state.hit = hit
            grace?.cancel(); grace = nil; return
        }
        retireImageAccess()
        if let access {
            do {
                guard let scope = access.scope, let epoch = access.epoch else { dismissNow(); return }
                accessRegistration = try scope.register(self, epoch: epoch); originalAccess = access
            } catch { dismissNow(); return }
        }
        generation += 1
        let ticket = generation
        debounce?.cancel(); skeleton?.cancel(); grace?.cancel()
        loader.cancel()
        selected = hit
        guard let hit, AskFilePreviewPolicy.kind(for: hit) != nil else {
            selected = nil
            grace = clock.schedule(after: 0.15) { [weak self] in self?.hide(animated: true) }
            return
        }
        // Refresh the header immediately while retaining the previous content through the grace window.
        state.hit = hit
        state.detail = nil
        loader.setVisible(true)
        debounce = clock.schedule(after: 0.12) { [weak self] in
            guard let self, generation == ticket else { return }
            guard originalAccess?.allows() != false else { dismissNow(); return }
            skeleton = clock.schedule(after: 0.15) { [weak self] in
                guard let self, generation == ticket else { return }
                state.skeleton = true
                show()
            }
            loader.load(hit, pixels: pixels) { [weak self] content in
                guard let self, generation == ticket else { return }
                guard originalAccess?.allows() != false else { dismissNow(); return }
                skeleton?.cancel(); skeleton = nil
                guard let content else { hide(animated: true); return }
                withAnimation(.easeInOut(duration: reduceMotion() ? 0.1 : 0.12)) {
                    self.state.content = content; self.state.detail = content.detail
                    self.state.skeleton = false; self.state.contentID = UUID()
                }
                show()
                loader.prefetch(neighbours, pixels: pixels)
                if let panel, let view = panel.contentView {
                    NSAccessibility.post(element: view, notification: .announcementRequested, userInfo: [
                        .announcement: hit.name + ", " + L("ask.preview.kind.\(content.kind.rawValue)"),
                        .priority: NSAccessibilityPriorityLevel.medium.rawValue
                    ])
                }
            }
        }
    }

    func dismissNow() {
        generation += 1; selected = nil
        debounce?.cancel(); skeleton?.cancel(); grace?.cancel()
        loader.setVisible(false)
        hide(animated: false)
    }

    /// The launcher card's visible height, gutters included, while it animates
    /// inside a panel that is already taller; nil follows the panel.
    var visibleHeight: CGFloat?

    /// Called on every tick of AskLauncherHeightAnimator, not on an independent animation clock.
    func updateFrame() {
        guard let parent else { return }
        var frame = parent.frame
        if let visibleHeight, visibleHeight < frame.height {
            frame = NSRect(x: frame.minX, y: frame.maxY - visibleHeight, width: frame.width, height: visibleHeight)
        }
        let card = frame.insetBy(dx: AskMetrics.launcherGutter, dy: AskMetrics.launcherGutter)
        placement = AskFilePreviewPlacement.resolve(card: card, screens: NSScreen.screens.map(\.visibleFrame))
        guard let placement else { dismissNow(); return }
        pixels = CGSize(width: (placement.frame.width - 20) * parent.backingScaleFactor,
                        height: max(1, placement.frame.height - 108) * parent.backingScaleFactor)
        panel?.setFrame(placement.frame, display: false)
    }

    private func show() {
        if let parent, !parent.isVisible { dismissNow(); return }
        guard originalAccess?.allows() != false else { dismissNow(); return }
        if isVisible { showImageAccess(); return }
        if parent != nil {
            updateFrame()
            guard parent?.isVisible == true, placement != nil else { return }
        }
        motionGeneration += 1
        hideCompletion?.cancel(); hideCompletion = nil
        isVisible = true
        showImageAccess()
        guard let parent, let placement else { return }
        let panel = makePanel()
        panel.appearance = parent.appearance
        if panel.parent != parent {
            parent.addChildWindow(panel, ordered: .above)
        }
        let reduced = reduceMotion()
        panel.alphaValue = 0
        panel.setFrame(reduced ? placement.frame : collapsed(placement), display: false)
        panel.orderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduced ? 0.1 : 0.18
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
            panel.animator().alphaValue = 1
            panel.animator().setFrame(placement.frame, display: true)
        }
    }

    private func hide(animated: Bool) {
        retireImageAccess()
        let wasVisible = isVisible
        isVisible = false
        motionGeneration += 1
        let ticket = motionGeneration
        hideCompletion?.cancel(); hideCompletion = nil
        guard animated, wasVisible else {
            if let panel {
                panel.parent?.removeChildWindow(panel); panel.orderOut(nil); panel.alphaValue = 0
            }
            state.content = nil; state.skeleton = false
            return
        }
        let duration = reduceMotion() ? 0.1 : 0.14
        if let panel {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = duration
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                panel.animator().alphaValue = 0
                if !reduceMotion(), let placement {
                    panel.animator().setFrame(collapsed(placement), display: true)
                }
            }
        }
        hideCompletion = clock.schedule(after: duration) { [weak self] in
            guard let self, motionGeneration == ticket else { return }
            if let panel {
                panel.parent?.removeChildWindow(panel); panel.orderOut(nil)
            }
            state.content = nil; state.skeleton = false
        }
    }

    private func collapsed(_ placement: AskFilePreviewPlacement) -> CGRect {
        var frame = placement.frame
        frame.size.width *= 0.985; frame.size.height *= 0.985
        frame.origin.y = placement.frame.maxY - frame.height
        frame.origin.x = placement.side == .right ? placement.frame.minX - 10 : placement.frame.maxX - frame.width + 10
        return frame
    }

    private func makePanel() -> NSPanel {
        if let panel {
            return panel
        }
        let panel = Panel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false; panel.level = .floating; panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.fullScreenAuxiliary, .canJoinAllSpaces]
        panel.identifier = NSUserInterfaceItemIdentifier("ask.filePreview")
        panel.onOrderOut = { [weak self] in
            if self?.isVisible == true { self?.dismissNow() }
        }
        if let style {
            let hosting = NSHostingView(rootView: AskFilePreviewView(state: state).interfaceStyle(following: style))
            hosting.sizingOptions = []
            panel.contentView = hosting
        } else {
            let hosting = NSHostingView(rootView: AskFilePreviewView(state: state))
            hosting.sizingOptions = []
            panel.contentView = hosting
        }
        self.panel = panel
        return panel
    }

    private final class Panel: NSPanel {
        var onOrderOut: (() -> Void)?
        override func orderOut(_ sender: Any?) { onOrderOut?(); super.orderOut(sender) }
        override var canBecomeKey: Bool {
            false
        }

        override var canBecomeMain: Bool {
            false
        }
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        Task { @MainActor [imageScope, loader] in
            imageScope.setVisible(false); loader.setVisible(false)
        }
    }
}
