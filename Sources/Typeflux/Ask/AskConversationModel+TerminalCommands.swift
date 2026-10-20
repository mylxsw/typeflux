import AppKit

extension AskConversationModel {
    var isTerminalCommandMode: Bool {
        plugins.keyword?.pluginID == AskTerminalCommandPlugin.id
    }

    /// Consent dialogs receive clicks outside the panel. Keep its input until
    /// dispatch settles; explicit Escape and hotkey dismissal still work.
    var allowsLauncherOutsideDismissal: Bool {
        !recordingIsActive() && !(terminalCommandSending && isTerminalCommandMode)
    }

    /// Called only by the composer's explicit user action, never by plugin.run.
    func submitTerminalCommand(_ request: TerminalCommandRequest, completed: @escaping () -> Void) {
        guard !terminalCommandSending, currentTerminalCommand(request) else { return }
        if request.builtin != nil {
            // Nothing to authorize: the command runs in Typeflux's own window, which
            // takes keyboard focus once the launcher has gone.
            let services = terminalRunnerServices
            finishPluginResult()
            completed()
            terminalRunner.present(request, services: services)
            return
        }
        terminalCommandSending = true
        let presentation = launcherPresentationID
        let generation = plugins.resultGeneration
        let dispatcher = terminalCommandDispatcher
        Task {
            var sent = false
            defer { terminalCommandSending = false }
            do {
                guard launcherPresentationID == presentation, plugins.resultGeneration == generation,
                      currentTerminalCommand(request) else { return }
                try await dispatcher.authorize(request.terminal)
                // Consent can outlive the input, keyword, owner or presentation.
                guard launcherPresentationID == presentation, plugins.resultGeneration == generation,
                      currentTerminalCommand(request) else { return }
                sent = true
                try await dispatcher.send(request)
                if launcherPresentationID == presentation, currentTerminalCommand(request) {
                    finishPluginResult()
                    completed()
                }
            } catch {
                guard sent || (launcherPresentationID == presentation && isTerminalCommandMode) else { return }
                // Keep failures visible even when activation hid the launcher.
                // Only typed, command-free messages may leave this boundary.
                let failure = error as? TerminalCommandError ?? .uncertain
                if launcherPresentationID == presentation, isTerminalCommandMode {
                    confirm(failure.localizedDescription, for: .seconds(15))
                } else {
                    let alert = NSAlert()
                    alert.messageText = L("terminal.command.title")
                    alert.informativeText = failure.localizedDescription
                    alert.addButton(withTitle: L("common.ok"))
                    alert.runModal()
                }
            }
        }
    }

    var terminalRunnerServices: TerminalRunnerServices {
        TerminalRunnerServices(deliverText: deliverText, notifyUser: notifyUser, passiveNotice: passiveNotice,
                               dispatcher: terminalCommandDispatcher)
    }

    func currentTerminalCommand(_ request: TerminalCommandRequest) -> Bool {
        guard isTerminalCommandMode, plugins.isPlanCurrent,
              launcherKeywords.contains(where: { $0.enabled && $0 == plugins.keyword }),
              plugins.request?.origin == .argument, plugins.request?.text == request.command,
              launcherDraft.text == request.command,
              TerminalApplication.configured(in: plugins.request?.options ?? [:]) == request.terminal,
              TerminalCommandRequest.problem(with: request.command) == nil else { return false }
        return plugins.plan?.actions.contains(where: { $0.kind == .terminalCommand(request) }) == true
    }

    /// Also catches input closed before its keyword was converted into a chip.
    func isTerminalCommandInput(_ text: String) -> Bool {
        switch AskKeywordMatcher.match(text, keywords: launcherKeywords) {
        case let .active(keyword, _), let .hint(keyword): keyword.pluginID == AskTerminalCommandPlugin.id
        case nil: false
        }
    }
}
