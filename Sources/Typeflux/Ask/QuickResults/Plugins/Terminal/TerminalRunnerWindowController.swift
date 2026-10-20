import AppKit
import Combine
import SwiftUI

/// What a built-in terminal window needs from the rest of the app; tests record it instead.
@MainActor
struct TerminalRunnerServices {
    /// Types text into the app the launcher came from.
    var deliverText: ((String) async throws -> Void)?
    var notifyUser: @MainActor (String, String) async -> Bool
    /// A short note after the window closed itself.
    var passiveNotice: @MainActor (String) -> Void
    var dispatcher: any TerminalCommandDispatching
    var copy: @MainActor (String) -> Void = { AskQuickResults.copy($0) }
}

@MainActor
protocol TerminalRunnerPresenting: AnyObject {
    func present(_ request: TerminalCommandRequest, services: TerminalRunnerServices)
}

/// Keeps every built-in terminal window alive while it is open, and ends their commands
/// when the app quits.
@MainActor
final class TerminalRunnerCenter: TerminalRunnerPresenting {
    static let shared = TerminalRunnerCenter()
    static let cascadeOffset: CGFloat = 26

    private(set) var windows: [TerminalRunnerWindowController] = []
    private var termination: NSObjectProtocol?
    /// Builds how a command starts; tests use a shell without startup files.
    var makeLaunch: (TerminalCommandRequest, TerminalRunSettings) -> TerminalShellLaunch = { request, settings in
        TerminalShellLaunch(command: request.command, settings: settings, shell: TerminalShellLaunch.accountShell(),
                            base: ProcessInfo.processInfo.environment, home: NSHomeDirectory())
    }

    init() {
        termination = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.terminateAll() }
        }
    }

    /// Hangs up every running command; the app is quitting.
    func terminateAll() {
        windows.forEach { $0.model.terminate() }
    }

    func present(_ request: TerminalCommandRequest, services: TerminalRunnerServices) {
        guard let settings = request.builtin else { return }
        let launch = makeLaunch(request, settings)
        // The launcher never activates Typeflux, so the frontmost app is the one it came from.
        let target = NSWorkspace.shared.frontmostApplication
        let model = TerminalRunModel(request: request, settings: settings, launch: launch,
                                     targetAppName: target?.bundleIdentifier == Bundle.main.bundleIdentifier
                                         ? nil : target?.localizedName)
        let controller = TerminalRunnerWindowController(model: model, services: services)
        controller.onClose = { [weak self, weak controller] in
            self?.windows.removeAll { $0 === controller }
        }
        let open = windows.filter { $0.window.isVisible }.count
        windows.append(controller)
        controller.show(cascade: CGFloat(open) * Self.cascadeOffset)
        model.start()
    }
}

/// One floating terminal window. It takes keyboard focus without activating Typeflux,
/// so Insert can type into the app that is still frontmost.
@MainActor
final class TerminalRunnerWindowController: NSObject, NSWindowDelegate {
    static let defaultSize = NSSize(width: 640, height: 340)
    static let minimumSize = NSSize(width: 440, height: 220)
    static let fullScreenSize = NSSize(width: 860, height: 520)

    let model: TerminalRunModel
    let window: TerminalRunnerPanel
    var onClose: (() -> Void)?

    private let services: TerminalRunnerServices
    private let terminal: TerminalRunnerTerminalView
    private(set) var pinned: Bool
    private var confirmedClose = false
    private var closed = false
    /// The frame before a full-screen program enlarged the window, restored when it exits.
    private var frameBeforeAlternate: NSRect?
    private var enlargedFrame: NSRect?
    private var subscriptions: Set<AnyCancellable> = []

    init(model: TerminalRunModel, services: TerminalRunnerServices) {
        self.model = model
        self.services = services
        pinned = model.settings.pinned
        terminal = TerminalRunnerTerminalView(model: model)
        window = TerminalRunnerPanel(contentRect: NSRect(origin: .zero, size: Self.defaultSize),
                                     styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView,
                                                 .nonactivatingPanel],
                                     backing: .buffered, defer: false)
        super.init()
        configureWindow()
        model.onFinish = { [weak self] code, closes in self?.finished(code, closes: closes) }
        model.$alternateScreen.removeDuplicates().dropFirst()
            .sink { [weak self] alternate in self?.alternateScreenChanged(alternate) }
            .store(in: &subscriptions)
    }

    private func configureWindow() {
        window.title = model.command
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        // The header sits in the title bar, which drags the window; dragging in the terminal selects text.
        window.isMovableByWindowBackground = false
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.becomesKeyOnlyIfNeeded = false
        window.minSize = Self.minimumSize
        window.level = pinned ? .floating : .normal
        window.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        window.identifier = NSUserInterfaceItemIdentifier("typeflux.terminal.runner")
        window.delegate = self
        // A compact toolbar makes the title bar as tall as the header and centers the buttons in it.
        let toolbar = NSToolbar(identifier: "typeflux.terminal.runner")
        toolbar.showsBaselineSeparator = false
        window.toolbar = toolbar
        window.toolbarStyle = .unifiedCompact
        window.titlebarSeparatorStyle = .none
        window.keyHandler = { [weak self] event in self?.handleKey(event) ?? false }
        let pinnedBinding = Binding<Bool>(get: { [weak self] in self?.pinned ?? false },
                                          set: { [weak self] in self?.setPinned($0) })
        let actions = TerminalRunnerActions(
            copy: { [weak self] in self?.copyOutput() },
            insert: { [weak self] in self?.insertOutput() },
            rerun: { [weak self] in self?.model.rerun() },
            openExternal: { [weak self] in self?.openExternally() },
            stop: { [weak self] in self?.model.stop() },
            close: { [weak self] in self?.window.performClose(nil) },
            togglePin: { [weak self] in self?.setPinned(!(self?.pinned ?? false)) }
        )
        let root = TerminalRunnerView(model: model, terminal: terminal, actions: actions, pinned: pinnedBinding)
        let hosting = NSHostingView(rootView: root)
        hosting.sizingOptions = []
        window.contentView = hosting
    }

    func show(cascade: CGFloat) {
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            let size = Self.defaultSize
            let origin = NSPoint(x: visible.midX - size.width / 2 + cascade,
                                 y: visible.maxY - visible.height * 0.2 - size.height - cascade)
            window.setFrame(NSRect(origin: origin, size: size), display: false)
        }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(terminal)
        // The hosting view may only insert the terminal on its first layout pass.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window.firstResponder !== self.terminal else { return }
            self.window.makeFirstResponder(self.terminal)
        }
    }

    func setPinned(_ value: Bool) {
        pinned = value
        window.level = value ? .floating : .normal
        // The binding reads `pinned`; publish so the header redraws.
        model.objectWillChange.send()
    }

    // MARK: - Actions

    func copyOutput() {
        let text = model.visibleText()
        guard !text.isEmpty else { return }
        services.copy(text)
    }

    func insertOutput() {
        let text = model.visibleText()
        guard !text.isEmpty, !model.isRunning else { return }
        let services = services
        closeWindow()
        guard let deliver = services.deliverText else {
            services.copy(text)
            services.passiveNotice(L("ask.plugin.writeBack.failed"))
            return
        }
        Task { @MainActor in
            // Let the source app's window take keyboard focus back first.
            try? await Task.sleep(for: .milliseconds(150))
            do {
                try await deliver(text)
            } catch {
                services.copy(text)
                services.passiveNotice(L("ask.plugin.writeBack.failed"))
            }
        }
    }

    /// Runs the command again in the external terminal; the finished run is not moved there.
    func openExternally() {
        guard !model.isRunning else { return }
        let request = TerminalCommandRequest(command: model.command, terminal: model.externalTerminal)
        let dispatcher = services.dispatcher
        Task { @MainActor [weak self] in
            do {
                try await dispatcher.authorize(request.terminal)
                try await dispatcher.send(request)
                self?.closeWindow()
            } catch {
                let failure = error as? TerminalCommandError ?? .uncertain
                self?.showAlert(failure.localizedDescription)
            }
        }
    }

    private func showAlert(_ message: String) {
        let alert = NSAlert()
        alert.messageText = L("terminal.command.title")
        alert.informativeText = message
        alert.addButton(withTitle: L("common.ok"))
        alert.beginSheetModal(for: window)
    }

    // MARK: - Lifecycle

    private func finished(_ code: Int32, closes: Bool) {
        if model.shouldNotify, !window.isKeyWindow || closes {
            let title = code == 0 ? L("terminal.runner.notify.done") : L("terminal.runner.notify.failed", Int(code))
            let command = model.command
            let notify = services.notifyUser
            Task { _ = await notify(title, command) }
        }
        guard closes else { return }
        services.passiveNotice(model.completionNotice)
        closeWindow()
    }

    private func alternateScreenChanged(_ alternate: Bool) {
        if alternate {
            let frame = window.frame
            guard frame.width < Self.fullScreenSize.width || frame.height < Self.fullScreenSize.height else { return }
            var target = NSRect(x: frame.minX, y: frame.maxY - max(frame.height, Self.fullScreenSize.height),
                                width: max(frame.width, Self.fullScreenSize.width),
                                height: max(frame.height, Self.fullScreenSize.height))
            if let visible = window.screen?.visibleFrame {
                target.origin.x = min(max(target.minX, visible.minX), visible.maxX - target.width)
                target.origin.y = max(target.minY, visible.minY)
            }
            frameBeforeAlternate = frame
            enlargedFrame = target
            window.setFrame(target, display: true, animate: true)
        } else if let previous = frameBeforeAlternate {
            // Restored only if the user kept the size the program got.
            if window.frame == enlargedFrame { window.setFrame(previous, display: true, animate: true) }
            frameBeforeAlternate = nil
            enlargedFrame = nil
        }
    }

    func handleKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.charactersIgnoringModifiers?.lowercased()
        if modifiers == .command, key == "w" {
            window.performClose(nil)
            return true
        }
        guard !model.isRunning else { return false }
        switch (modifiers, event.keyCode) {
        case ([], 53): window.performClose(nil) // Esc
        case (.command, 36), (.command, 76): insertOutput() // ⌘↩
        case (.command, _) where key == "r": model.rerun()
        case ([.command, .shift], _) where key == "c": copyOutput()
        default: return false
        }
        return true
    }

    func windowShouldClose(_: NSWindow) -> Bool {
        guard model.isRunning, !confirmedClose else { return true }
        let alert = NSAlert()
        alert.messageText = L("terminal.runner.close.title", TerminalRunModel.truncated(model.command, limit: 40))
        alert.informativeText = L("terminal.runner.close.message")
        let end = alert.addButton(withTitle: L("terminal.runner.close.end"))
        end.hasDestructiveAction = true
        alert.addButton(withTitle: L("terminal.runner.close.keep"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            self.confirmedClose = true
            self.window.close()
        }
        return false
    }

    func windowWillClose(_: Notification) {
        guard !closed else { return }
        closed = true
        model.terminate()
        subscriptions.removeAll()
        // `onClose` drops the center's reference; stay alive until this call returns.
        withExtendedLifetime(self) { onClose?() }
    }

    private func closeWindow() {
        confirmedClose = true
        window.close()
    }
}

/// Takes keys before the terminal does, for the window's own shortcuts.
final class TerminalRunnerPanel: NSPanel {
    var keyHandler: ((NSEvent) -> Bool)?

    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        false
    }

    override func sendEvent(_ event: NSEvent) {
        KeyboardFocusPolicy.focusOnMouseDown(event, in: self)
        if event.type == .keyDown, attachedSheet == nil, keyHandler?(event) == true { return }
        super.sendEvent(event)
    }
}
