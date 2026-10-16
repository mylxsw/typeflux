import AppKit

/// Only fixed, built-in operations reach the process runner. Search text is never a command.
@MainActor
struct AskSystemCommandRunner {
    var process: any ProcessCommandRunning = ProcessCommandRunner(timeout: 60, outputLimit: 200_000)

    var native: any NativeSystemWorking = NativeSystemWorker.shared

    func presentsFailures(for command: AskSystemCommand) -> Bool {
        switch command {
        case .toggleWiFi, .toggleBluetooth, .toggleScrollDirection: native.isEnabled
        default: true
        }
    }

    struct Invocation: Equatable {
        var executable: String
        var arguments: [String]
    }

    // Keep the fixed command dispatch table together.
    // swiftlint:disable:next cyclomatic_complexity
    static func invocation(for command: AskSystemCommand) -> Invocation? {
        func script(_ source: String)
            -> Invocation {
            .init(executable: "/usr/bin/osascript", arguments: ["-e", source])
        }
        switch command {
        case .ejectAllDisks: return script("tell application \"Finder\" to eject (every disk whose ejectable is true)")
        case .toggleDarkMode:
            return script(
                "tell application \"System Events\" to tell appearance preferences to set dark mode to not dark mode"
            )
        case .showTrash: return script("tell application \"Finder\"\nopen trash\nactivate\nend tell")
        case .emptyTrash: return script("tell application \"Finder\" to empty trash")
        case .screenSaver: return .init(
                executable: "/usr/bin/open",
                arguments: ["-a", "/System/Library/CoreServices/ScreenSaverEngine.app"]
            )
        case .sleep: return script("tell application \"System Events\" to sleep")
        case .displaySleep: return .init(executable: "/usr/bin/pmset", arguments: ["displaysleepnow"])
        case .shutdown: return script("tell application \"System Events\" to shut down")
        case .restart: return script("tell application \"System Events\" to restart")
        case .lockScreen: return script(
                "tell application \"System Events\" to keystroke \"q\" using {control down, command down}"
            )
        case .resetSpotlight: return script("do shell script \"/usr/bin/mdutil -E /\" with administrator privileges")
        // Restart the gesture handler when trackpad pinch-to-zoom stops responding.
        case .resetTrackpadZoom: return .init(executable: "/usr/bin/killall", arguments: ["Dock"])
        case .toggleBluetooth, .toggleWiFi, .toggleHiddenFiles, .toggleDesktopFiles, .toggleScrollDirection,
             .cleanScreen: return nil
        }
    }

    func run(_ command: AskSystemCommand) async throws {
        if let invocation = Self.invocation(for: command) {
            try await execute(invocation)
            return
        }
        switch command {
        case .toggleWiFi, .toggleBluetooth, .toggleScrollDirection:
            let operation: NativeSystemOperation = switch command {
            case .toggleWiFi: .toggleWiFi
            case .toggleBluetooth: .toggleBluetooth
            default: .toggleScrollDirection
            }
            do { try await native.perform(operation) }
            catch {
                let failure = error as? NativeSystemFailure ?? .unknown
                throw AskPluginFailure(message: L(failure.messageKey), retry: false)
            }
        case .toggleHiddenFiles:
            try await togglePreference(domain: "com.apple.finder", key: "AppleShowAllFiles", fallback: false)
            try await execute(.init(executable: "/usr/bin/killall", arguments: ["Finder"]))
        case .toggleDesktopFiles:
            try await togglePreference(domain: "com.apple.finder", key: "CreateDesktop", fallback: true)
            try await execute(.init(executable: "/usr/bin/killall", arguments: ["Finder"]))
        case .cleanScreen:
            try AskScreenCleaningController.shared.show()
        default: throw failure()
        }
    }

    private func execute(_ invocation: Invocation) async throws {
        let result = try await process.run(executablePath: invocation.executable, arguments: invocation.arguments)
        guard result.exitCode == 0 else {
            throw AskPluginFailure(
                message: result.stderr.isEmpty ? L("ask.system.failed") : result.stderr,
                retry: false
            )
        }
    }

    private func togglePreference(domain: String, key: String, fallback: Bool) async throws {
        let stored = UserDefaults.standard.persistentDomain(forName: domain)?[key] as? NSNumber
        let next = !(stored?.boolValue ?? fallback)
        try await execute(.init(executable: "/usr/bin/defaults",
                                arguments: [
                                    "write",
                                    domain == UserDefaults.globalDomain ? "-g" : domain,
                                    key,
                                    "-bool",
                                    next ? "true" : "false"
                                ]))
    }

    private func failure() -> AskPluginFailure {
        .init(message: L("ask.system.failed"), retry: false)
    }
}
