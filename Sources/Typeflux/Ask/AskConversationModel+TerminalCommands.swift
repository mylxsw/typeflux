import AppKit

extension AskConversationModel {
    var isTerminalCommandMode: Bool {
        plugins.keyword?.pluginID == AskTerminalCommandPlugin.id
    }

    /// Consent dialogs receive clicks outside the panel. Keep its input until
    /// dispatch settles; explicit Escape and hotkey dismissal still work.
    var allowsLauncherOutsideDismissal: Bool {
        !recordingIsActive() && !terminalCloseInProgress && !(terminalCommandSending && isTerminalCommandMode)
    }

    /// Called only by the composer's explicit user action, never by plugin.run.
    func submitTerminalCommand(_ request: TerminalCommandRequest, completed: @escaping () -> Void) {
        guard !terminalCommandSending, currentTerminalCommand(request) else { return }
        if let keyword = plugins.keyword {
            var properties = plugins.analyticsProperties(for: keyword)
            properties["execution_kind"] = "submitted"
            featureAnalytics.event(.keyword, "executed", properties: properties)
        }
        if let settings = request.builtin {
            if request.runner == .window, let terminalRunnerOverride {
                let services = terminalRunnerServices
                finishPluginResult()
                completed()
                terminalRunnerOverride.present(request, services: services)
            } else {
                launchTerminal(command: request.command, settings: settings,
                               window: request.runner == .window, dismiss: completed)
            }
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
        guard isTerminalCommandMode, let keyword = plugins.keyword,
              launcherKeywords.contains(where: { $0.enabled && $0 == keyword }),
              launcherDraft.text == request.command else { return false }
        return TerminalCommandRequest.configured(command: request.command, options: keyword.options,
                                                 destination: request.runner) == request
    }

    /// Also catches input closed before its keyword was converted into a chip.
    func isTerminalCommandInput(_ text: String) -> Bool {
        switch AskKeywordMatcher.match(text, keywords: launcherKeywords) {
        case let .active(keyword, _), let .hint(keyword): keyword.pluginID == AskTerminalCommandPlugin.id
        case nil: false
        }
    }
}
