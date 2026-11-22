import AppKit
import Combine
import SwiftUI

extension AskConversationModel {
    var terminalLauncherSessions: [TerminalSession] {
        terminalSessionCenter.sessions.filter { $0.host == .launcher }
    }

    var terminalHomeSessions: [TerminalSession] {
        terminalSessionCenter.sessions
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
        showLauncherTerminal(terminalPresentation(for: session, settings: session.settings))
    }

    func openTerminalHomeSession(_ id: UUID, dismiss: () -> Void) {
        if let index = terminalSessionWindow.tabs.firstIndex(where: { $0.id == id }) {
            finishPluginResult()
            dismiss()
            terminalSessionWindow.select(index)
            terminalSessionWindow.panel.makeKeyAndOrderFront(nil)
        } else {
            resumeLauncherTerminal(id)
        }
    }

    func endTerminalHomeSession(_ id: UUID) {
        guard let session = terminalHomeSessions.first(where: { $0.id == id }) else { return }
        guard confirmTerminalClose(session) else { return }
        terminalSessionCenter.close(session)
    }

    private func terminalPresentation(for session: TerminalSession, settings: TerminalRunSettings) -> TerminalLauncherModel {
        if terminalPresentationObservation == nil {
            terminalPresentationObservation = terminalSessionCenter.$sessions.sink { [weak self] sessions in
                guard let self else { return }
                let live = Set(sessions.map(\.id))
                if let presentation = launcherTerminal, !live.contains(presentation.session.id) {
                    presentation.secret = ""
                    launcherTerminal = nil
                }
                terminalPresentations = terminalPresentations.filter { live.contains($0.key) }
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
                return self.terminalSessionWindow.selected === session && self.terminalSessionWindow.panel.isKeyWindow
            }
        )
        presentation.explanation.generator = promptAI as? any AskStructuredTextGenerating
        presentation.explanation.openAsk = { [weak self] text in
            Task { [weak self] in
                _ = await self?.openChatFromLauncher(incomingDraft: AskDraft(text: text, includeScreenshot: false))
            }
        }
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
            terminalSessionCenter.setVisible(false, session: session)
            if showNotice, let command = session.runningBlock?.command {
                passiveNotice(L("terminal.launcher.background", TerminalRunModel.truncated(command, limit: 48)))
            }
        }
    }

    func closeLauncherTerminal() {
        guard let session = launcherTerminal?.session else { return }
        endTerminalHomeSession(session.id)
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

    /// The window hosts the same PTY and block/prompt view as the launcher.
    private func presentTerminalWindow(_ presentation: TerminalLauncherModel) {
        let settings = presentation.settings
        terminalSessionWindow.present(presentation.session, center: terminalSessionCenter, settings: settings,
                                      content: { [weak self] session in
            guard let self else { return AnyView(EmptyView()) }
            return self.terminalWindowContent(for: session, settings: settings)
        }, returnToLauncher: { [weak self] session in
            guard let self else { return }
            if let show = self.onShowLauncher {
                show { [weak self] in self?.resumeLauncherTerminal(session.id) }
            } else {
                self.resumeLauncherTerminal(session.id)
            }
        })
    }

    private func terminalWindowContent(for session: TerminalSession, settings: TerminalRunSettings) -> AnyView {
        let presentation = terminalPresentation(for: session, settings: settings)
        return AnyView(TerminalSessionContent(
            model: presentation, session: session,
            commands: { [weak self] in self?.terminalSessionCenter.history.commands ?? [] },
            new: { [weak self] in self?.terminalSessionWindow.addTab() },
            insert: { [weak self] text in
                guard let self else { return }
                self.insertTerminalOutput(text, from: presentation) {
                    self.terminalSessionWindow.panel.resignKey()
                }
            },
            error: { [weak self] text in self?.passiveNotice(text) }
        ))
    }

    private func confirmTerminalClose(_ session: TerminalSession) -> Bool {
        guard let block = session.runningBlock else { return true }
        guard !terminalCloseInProgress else { return false }
        terminalCloseInProgress = true
        defer { terminalCloseInProgress = false }
        let alert = NSAlert()
        alert.messageText = L("terminal.runner.close.title", TerminalRunModel.truncated(block.command, limit: 40))
        alert.informativeText = L("terminal.runner.close.message")
        alert.addButton(withTitle: L("terminal.session.end")).hasDestructiveAction = true
        alert.addButton(withTitle: L("common.cancel")).keyEquivalent = "\u{1b}"
        let observation = terminalSessionCenter.$sessions.dropFirst().sink { sessions in
            if !sessions.contains(where: { $0 === session }), NSApp.modalWindow === alert.window {
                NSApp.abortModal()
            }
        }
        return withExtendedLifetime(observation) { alert.runModal() == .alertFirstButtonReturn }
    }
}
