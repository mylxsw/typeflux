import AppKit
import Combine
import SwiftUI

extension AskConversationModel {
    var terminalLauncherSessions: [TerminalSession] {
        terminalSessionCenter.sessions.filter {
            $0.host == .launcher && (!$0.exited || $0 === launcherTerminal?.session)
        }
    }

    var terminalHomeSessions: [TerminalSession] {
        terminalSessionCenter.sessions.filter { !$0.exited }
    }

    var terminalHomeRows: [AskLauncherHome.Row] {
        terminalHomeSessions.map { session in
            let block = session.blocks.last
            let detail = (session.cwd as NSString).abbreviatingWithTildeInPath
            return .init(id: "terminal." + session.id.uuidString,
                         title: block?.command ?? L("terminal.command.title"), detail: detail,
                         symbol: session.host == .launcher ? "terminal" : "macwindow",
                         tint: .green, action: .terminalSession(session.id),
                         status: block.flatMap(TerminalLauncherModel.homeStatus))
        }
    }

    func launchTerminal(command: String = "", settings: TerminalRunSettings, window: Bool = false,
                        dismiss: () -> Void = {}) {
        do {
            let session = try terminalSessionCenter.create(settings: settings)
            if !command.isEmpty, !session.submit(command) {
                terminalSessionCenter.close(session)
                return
            }
            let presentation = terminalPresentation(for: session, settings: settings)
            finishPluginResult()
            if window {
                presentTerminalWindow(presentation)
                dismiss()
            } else {
                showLauncherTerminal(presentation)
            }
        } catch {
            passiveNotice(L("terminal.launcher.startFailed"))
        }
    }

    func newLauncherTerminal() {
        launchTerminal(settings: launcherTerminal?.settings ?? .init())
    }

    func resumeLauncherTerminal(_ id: UUID) {
        guard let session = terminalLauncherSessions.first(where: { $0.id == id }) else { return }
        finishPluginResult()
        showLauncherTerminal(terminalPresentation(for: session, settings: .init()))
    }

    func openTerminalHomeSession(_ id: UUID, dismiss: () -> Void) {
        if let panel = terminalPopouts[id]?.panel {
            finishPluginResult()
            dismiss()
            panel.makeKeyAndOrderFront(nil)
        } else {
            resumeLauncherTerminal(id)
        }
    }

    private func terminalPresentation(for session: TerminalSession, settings: TerminalRunSettings) -> TerminalLauncherModel {
        if terminalPresentationObservation == nil {
            terminalPresentationObservation = terminalSessionCenter.$sessions.sink { [weak self] sessions in
                let live = Set(sessions.map(\.id))
                self?.terminalPresentations = self?.terminalPresentations.filter { live.contains($0.key) } ?? [:]
            }
        }
        if let existing = terminalPresentations[session.id] { return existing }
        let frontmost = NSWorkspace.shared.frontmostApplication
        let presentation = TerminalLauncherModel(
            session: session, settings: settings,
            source: frontmost?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : frontmost,
            notify: notifyUser,
            visible: { [weak self, weak session] in
                guard let self, let session else { return false }
                if self.launcherTerminal?.session === session { return true }
                return self.terminalPopouts[session.id]?.panel.isKeyWindow == true
            }
        )
        terminalPresentations[session.id] = presentation
        return presentation
    }

    private func showLauncherTerminal(_ presentation: TerminalLauncherModel) {
        if launcherTerminal !== presentation { hideLauncherTerminal(showNotice: false) }
        launcherTerminal = presentation
        terminalSessionCenter.setVisible(true, session: presentation.session)
    }

    func hideLauncherTerminal(showNotice: Bool = true) {
        guard let presentation = launcherTerminal else { return }
        launcherTerminal = nil
        presentation.secret = ""
        let session = presentation.session
        if session.host == .launcher {
            if session.exited {
                terminalSessionCenter.close(session)
            } else {
                terminalSessionCenter.setVisible(false, session: session)
                if showNotice, let command = session.runningBlock?.command {
                    passiveNotice(L("terminal.launcher.background", TerminalRunModel.truncated(command, limit: 48)))
                }
            }
        }
    }

    func closeLauncherTerminal() {
        guard let presentation = launcherTerminal else { return }
        let session = presentation.session
        guard confirmTerminalClose(session) else { return }
        let next = terminalLauncherSessions.first { $0 !== session }
        launcherTerminal = nil
        terminalSessionCenter.close(session)
        terminalPresentations.removeValue(forKey: session.id)
        if let next { resumeLauncherTerminal(next.id) }
    }

    func insertTerminalOutput(_ text: String, from presentation: TerminalLauncherModel, dismiss: () -> Void) {
        guard !text.isEmpty else { return }
        let source = presentation.source
        dismiss()
        if let source, !source.isTerminated,
           NSWorkspace.shared.frontmostApplication?.processIdentifier != source.processIdentifier {
            source.activate(options: [])
        }
        Task {
            try? await Task.sleep(for: .milliseconds(150))
            do {
                guard let source, !source.isTerminated, let deliverText,
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == source.processIdentifier else {
                    throw TextDeliveryError.noInput
                }
                try await deliverText(text)
            } catch {
                AskQuickResults.copy(text)
                passiveNotice(L("ask.plugin.writeBack.failed"))
            }
        }
    }

    func moveLauncherTerminal(dismiss: () -> Void) {
        guard let presentation = launcherTerminal else { return }
        presentTerminalWindow(presentation)
        hideLauncherTerminal(showNotice: false)
        dismiss()
    }

    /// The launcher handoff borrows the shared content and moves the existing PTY.
    private func presentTerminalWindow(_ presentation: TerminalLauncherModel) {
        let session = presentation.session
        let popout = TerminalLauncherPopout { [weak self] in
            self?.confirmTerminalClose(session) ?? true
        }
        let window = popout.panel
        window.level = presentation.settings.pinned ? .floating : .normal
        let root = TerminalSessionContent(
            model: presentation, session: session,
            commands: { [weak self] in self?.terminalSessionCenter.history.commands ?? [] },
            new: { [weak self, weak window] in
                self?.launchTerminal(settings: presentation.settings, window: true)
                window?.close()
            },
            insert: { [weak self, weak window] text in
                self?.insertTerminalOutput(text, from: presentation) {
                    if session.runningBlock == nil {
                        window?.close()
                    } else {
                        window?.resignKey()
                    }
                }
            },
            error: { [weak self] text in self?.passiveNotice(text) }
        )
        popout.onClose = { [weak self] in
            guard let self else { return }
            self.terminalSessionCenter.close(session)
            self.terminalPopouts.removeValue(forKey: session.id)
        }
        terminalPopouts[session.id] = popout
        terminalSessionCenter.move(session, to: .window(popout.id))
        window.contentView = NSHostingView(rootView: root)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    private func confirmTerminalClose(_ session: TerminalSession) -> Bool {
        guard let block = session.runningBlock else { return true }
        terminalCloseInProgress = true
        defer { terminalCloseInProgress = false }
        let alert = NSAlert()
        alert.messageText = L("terminal.runner.close.title", TerminalRunModel.truncated(block.command, limit: 40))
        alert.informativeText = L("terminal.runner.close.message")
        alert.addButton(withTitle: L("terminal.runner.close.end")).hasDestructiveAction = true
        alert.addButton(withTitle: L("terminal.runner.close.keep"))
        return alert.runModal() == .alertFirstButtonReturn
    }
}

/// Hosts a launcher session in a standalone panel for the launcher handoff.
@MainActor
final class TerminalLauncherPopout: NSObject, NSWindowDelegate {
    let id = UUID()
    let panel: TerminalRunnerPanel
    var onClose: (() -> Void)?
    private let confirmClose: () -> Bool

    init(confirmClose: @escaping () -> Bool) {
        self.confirmClose = confirmClose
        panel = TerminalRunnerPanel(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 460),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        super.init()
        panel.title = L("terminal.launcher.label")
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.minSize = TerminalRunnerWindowController.minimumSize
        panel.delegate = self
        panel.keyHandler = { [weak panel] event in
            guard event.modifierFlags.intersection([.command, .option, .control, .shift]) == .command,
                  event.keyCode == 13 else { return false }
            if !event.isARepeat { panel?.performClose(nil) }
            return true
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { confirmClose() }

    func windowWillClose(_ notification: Notification) {
        withExtendedLifetime(self) { onClose?() }
    }
}
