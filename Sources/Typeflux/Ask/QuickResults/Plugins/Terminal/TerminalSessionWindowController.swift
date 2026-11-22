import AppKit
import SwiftUI

/// Both hosts mount the screen owned by the session so the emulator and PTY survive moves.
struct TerminalAlternateScreenView: NSViewRepresentable {
    let session: TerminalSession

    func makeNSView(context: Context) -> NSView {
        let container = AlternateScreenContainer()
        let terminal = session.terminalView
        terminal.removeFromSuperview()
        terminal.inlineBackground = nil
        container.frame = terminal.frame
        terminal.frame = container.bounds
        terminal.autoresizingMask = [.width, .height]
        container.addSubview(terminal)
        DispatchQueue.main.async { [weak container] in
            guard let container, terminal.superview === container else { return }
            container.window?.makeFirstResponder(terminal)
        }
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Route key-down events before menus and host shortcuts can consume them.
private final class AlternateScreenContainer: NSView {
    private var monitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let window, event.window === window, window.isKeyWindow,
                  window.attachedSheet == nil, let terminal = subviews.first as? TerminalRunnerTerminalView,
                  !Self.isMoveShortcut(event) else { return event }
            terminal.keyDown(with: event)
            return nil
        }
    }

    static func isMoveShortcut(_ event: NSEvent) -> Bool {
        event.modifierFlags.intersection([.command, .option, .control, .shift]) == .command &&
            event.charactersIgnoringModifiers?.lowercased() == "o"
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }
}

@MainActor
final class TerminalSessionWindowController: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = TerminalSessionWindowController()
    let windowID = UUID()
    @Published private(set) var tabs: [TerminalSession] = []
    @Published private(set) var selected: TerminalSession?
    @Published private(set) var pinned = true
    private(set) lazy var panel = TerminalRunnerPanel(
        contentRect: NSRect(x: 0, y: 0, width: 800, height: 460),
        styleMask: [.titled, .closable, .resizable, .miniaturizable, .nonactivatingPanel, .fullSizeContentView],
        backing: .buffered, defer: false
    )
    private var center: TerminalSessionCenter?
    private struct Presentation {
        let settings: TerminalRunSettings
        let content: (TerminalSession) -> AnyView
        let returnToLauncher: (TerminalSession) -> Void
    }

    private var presentations: [UUID: Presentation] = [:]
    fileprivate var content: ((TerminalSession) -> AnyView)? {
        selected.flatMap { presentations[$0.id]?.content }
    }

    func present(_ session: TerminalSession, center: TerminalSessionCenter, settings: TerminalRunSettings,
                 content: @escaping (TerminalSession) -> AnyView,
                 returnToLauncher: @escaping (TerminalSession) -> Void) {
        guard center.sessions.contains(where: { $0 === session }) else { return }
        self.center = center
        presentations[session.id] = Presentation(settings: settings, content: content,
                                                  returnToLauncher: returnToLauncher)
        if tabs.isEmpty {
            pinned = settings.pinned
            panel.level = pinned ? .floating : .normal
            panel.title = L("terminal.session.window.title")
            panel.minSize = TerminalRunnerWindowController.minimumSize
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = false
            panel.delegate = self
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            panel.toolbar = NSToolbar(identifier: "typeflux.terminal.sessions")
            panel.toolbarStyle = .unifiedCompact
            panel.titlebarSeparatorStyle = .none
            let root = TerminalSessionWindow(controller: self, center: center)
            let hosting = NSHostingView(rootView: root.ignoresSafeArea())
            hosting.sizingOptions = []
            panel.contentView = hosting
            panel.center()
        }
        center.move(session, to: .window(windowID))
        if !tabs.contains(where: { $0 === session }) { tabs.append(session) }
        selected = session
        panel.makeKeyAndOrderFront(nil)
    }

    func select(_ index: Int) {
        guard tabs.indices.contains(index) else { return }
        selected = tabs[index]
    }

    func addTab() {
        guard let center, let selected, let presentation = presentations[selected.id] else { return }
        do {
            let session = try center.create(host: .window(windowID), settings: presentation.settings)
            presentations[session.id] = presentation
            tabs.append(session)
            self.selected = session
        } catch {
            NSAlert(error: error).beginSheetModal(for: panel)
        }
    }

    func togglePin() {
        pinned.toggle()
        panel.level = pinned ? .floating : .normal
    }

    func moveBack(_ session: TerminalSession? = nil) {
        guard let session = session ?? selected, let center,
              let presentation = presentations[session.id] else { return }
        center.move(session, to: .launcher)
        remove(session)
        presentation.returnToLauncher(session)
    }

    @discardableResult
    func reorder(_ id: UUID, to target: UUID) -> Bool {
        guard let sourceIndex = tabs.firstIndex(where: { $0.id == id }),
              let targetIndex = tabs.firstIndex(where: { $0.id == target }),
              sourceIndex != targetIndex else { return false }
        var reordered = tabs
        let session = reordered.remove(at: sourceIndex)
        reordered.insert(session, at: targetIndex)
        tabs = reordered
        return true
    }

    private func remove(_ session: TerminalSession) {
        guard let index = tabs.firstIndex(where: { $0 === session }) else { return }
        presentations.removeValue(forKey: session.id)
        tabs.remove(at: index)
        if selected === session { selected = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)] }
        if tabs.isEmpty {
            panel.close()
            panel.contentView = nil
            center = nil
        }
    }

    func closeTab(_ session: TerminalSession? = nil) {
        guard let session = session ?? selected, tabs.contains(where: { $0 === session }) else { return }
        confirm([session]) { [weak self] accepted in
            if accepted { self?.endTab(session) }
        }
    }

    func closeOtherTabs(keeping session: TerminalSession) {
        guard tabs.contains(where: { $0 === session }), panel.attachedSheet == nil else { return }
        closeInOrder(ArraySlice(tabs.filter { $0 !== session }))
    }

    private func closeInOrder(_ sessions: ArraySlice<TerminalSession>) {
        var remaining = sessions
        while let session = remaining.popFirst() {
            guard tabs.contains(where: { $0 === session }) else { continue }
            if session.runningBlock == nil {
                endTab(session)
            } else {
                let rest = remaining
                confirm([session]) { [weak self] accepted in
                    if accepted { self?.endTab(session) }
                    self?.closeInOrder(rest)
                }
                return
            }
        }
    }

    func endTab(_ session: TerminalSession) {
        guard tabs.contains(where: { $0 === session }) else { return }
        center?.close(session)
        remove(session)
    }

    private func confirm(_ sessions: [TerminalSession], completion: @escaping (Bool) -> Void) {
        guard let command = sessions.compactMap({ $0.runningBlock?.command }).first else {
            completion(true)
            return
        }
        guard panel.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = L("terminal.runner.close.title", TerminalRunModel.truncated(command, limit: 40))
        alert.informativeText = L("terminal.runner.close.message")
        alert.addButton(withTitle: L("terminal.runner.close.end")).hasDestructiveAction = true
        alert.addButton(withTitle: L("terminal.runner.close.keep"))
        alert.beginSheetModal(for: panel) { response in
            // AppKit detaches the current sheet after its completion handler.
            DispatchQueue.main.async {
                completion(response == .alertFirstButtonReturn)
            }
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        let closing = tabs
        confirm(closing) { [weak self] accepted in
            if accepted { closing.forEach { self?.endTab($0) } }
        }
        return false
    }

    func handleKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .control, .option])
        guard let key = event.charactersIgnoringModifiers?.lowercased() else { return false }
        let action: () -> Void
        if modifiers == .command, key == "o" {
            action = { self.moveBack() }
        } else {
            guard let selected, !selected.alternateScreen else { return false }
            switch (modifiers, key) {
            case (.command, "t"): action = addTab
            case (.command, "w"): action = { self.closeTab() }
            case ([.command, .option], "w"): action = { self.closeOtherTabs(keeping: selected) }
            case (.command, "1"..."9"):
                guard let number = Int(key) else { return false }
                action = { self.select(number - 1) }
            default: return false
            }
        }
        if !event.isARepeat { action() }
        return true
    }
}

private struct TerminalSessionWindow: View {
    @ObservedObject var controller: TerminalSessionWindowController
    @ObservedObject var center: TerminalSessionCenter

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        let folderCounts = Dictionary(grouping: controller.tabs, by: \.tabFolder).mapValues(\.count)
                        ForEach(Array(controller.tabs.enumerated()), id: \.element.id) { index, session in
                            SessionWindowTab(
                                session: session, duplicateFolder: folderCounts[session.tabFolder, default: 0] > 1,
                                selected: controller.selected === session,
                                select: { controller.select(index) },
                                close: { controller.closeTab(session) },
                                closeOthers: { controller.closeOtherTabs(keeping: session) },
                                move: { controller.moveBack(session) }
                            )
                            .draggable(session.id.uuidString)
                            .dropDestination(for: String.self) { items, _ in
                                guard let first = items.first, let id = UUID(uuidString: first) else { return false }
                                return controller.reorder(id, to: session.id)
                            }
                        }
                    }
                }
                Button(action: controller.addTab) { Image(systemName: "plus") }
                    .help(L("terminal.session.window.new"))
                if let selected = controller.selected {
                    SessionWindowDirectory(session: selected)
                }
                Button(action: controller.togglePin) { Image(systemName: controller.pinned ? "pin.fill" : "pin") }
                    .help(L("terminal.session.window.pin"))
                Button {
                    controller.moveBack()
                } label: {
                    Image(systemName: "rectangle.portrait.and.arrow.forward")
                }
                .help(L("terminal.session.window.back"))
            }
            .buttonStyle(.borderless)
            .padding(.leading, 76)
            .padding(.trailing, 10)
            .frame(height: 40)
            Divider()
            if let selected = controller.selected, let content = controller.content {
                SessionWindowBody(session: selected, content: content).id(selected.id)
            }
        }
        .background(TerminalKeyCapture(handler: controller.handleKey))
    }
}

private struct SessionWindowDirectory: View {
    @ObservedObject var session: TerminalSession

    var body: some View {
        Text(session.displayDirectory(session.cwd))
            .font(.system(.caption, design: .monospaced))
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.secondary.opacity(0.1), in: Capsule())
    }
}

private struct SessionWindowBody: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var session: TerminalSession
    let content: (TerminalSession) -> AnyView

    var body: some View {
        if session.alternateScreen {
            TerminalAlternateScreenView(session: session)
                .padding(.leading, TerminalRunnerHost.inset.left)
                .padding(.trailing, TerminalRunnerHost.inset.right)
                .background(Color(nsColor: colorScheme == .dark
                                  ? TerminalRunnerPalette.dark.background : TerminalRunnerPalette.light.background))
        } else {
            content(session)
        }
    }
}
