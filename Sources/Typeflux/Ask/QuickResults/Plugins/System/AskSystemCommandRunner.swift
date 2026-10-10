import AppKit
import CoreWLAN
import Darwin

/// Only fixed, built-in operations reach the process runner. Search text is never a command.
@MainActor
struct AskSystemCommandRunner {
    var process: any ProcessCommandRunning = ProcessCommandRunner()

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
        case .toggleWiFi:
            guard let interface = CWWiFiClient.shared().interface() else { throw failure() }
            try interface.setPower(!interface.powerOn())
        case .toggleBluetooth:
            try await toggleBluetooth()
        case .toggleHiddenFiles:
            try await togglePreference(domain: "com.apple.finder", key: "AppleShowAllFiles", fallback: false)
            try await execute(.init(executable: "/usr/bin/killall", arguments: ["Finder"]))
        case .toggleDesktopFiles:
            try await togglePreference(domain: "com.apple.finder", key: "CreateDesktop", fallback: true)
            try await execute(.init(executable: "/usr/bin/killall", arguments: ["Finder"]))
        case .toggleScrollDirection:
            try toggleScrollDirection()
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

    /// macOS exposes the Bluetooth preference functions through IOBluetooth.
    /// Resolve them at runtime so missing symbols produce a visible failure.
    private func toggleBluetooth() async throws {
        guard let framework = dlopen("/System/Library/Frameworks/IOBluetooth.framework/IOBluetooth", RTLD_LAZY)
        else { throw failure() }
        defer { dlclose(framework) }
        guard let getSymbol = dlsym(framework, "IOBluetoothPreferenceGetControllerPowerState"),
              let setSymbol = dlsym(framework, "IOBluetoothPreferenceSetControllerPowerState") else { throw failure() }
        let get = unsafeBitCast(getSymbol, to: (@convention(c) () -> Int32).self)
        let set = unsafeBitCast(setSymbol, to: (@convention(c) (Int32) -> Void).self)
        let target: Int32 = get() == 0 ? 1 : 0
        set(target)
        for _ in 0 ..< 20 {
            try await Task.sleep(for: .milliseconds(100))
            if get() == target { return }
        }
        throw failure()
    }

    private func failure() -> AskPluginFailure {
        .init(message: L("ask.system.failed"), retry: false)
    }

    /// The preference pane's setter updates the input driver as well as the saved value.
    /// Changing defaults alone does not change current scrolling behavior.
    private func toggleScrollDirection() throws {
        let path = "/System/Library/PrivateFrameworks/PreferencePanesSupport.framework/PreferencePanesSupport"
        guard let framework = dlopen(path, RTLD_LAZY) else { throw failure() }
        defer { dlclose(framework) }
        guard let getSymbol = dlsym(framework, "swipeScrollDirection"),
              let setSymbol = dlsym(framework, "setSwipeScrollDirection") else { throw failure() }
        let get = unsafeBitCast(getSymbol, to: (@convention(c) () -> Bool).self)
        let set = unsafeBitCast(setSymbol, to: (@convention(c) (Bool) -> Void).self)
        let target = !get()
        set(target)
        guard get() == target else { throw failure() }
        DistributedNotificationCenter.default().postNotificationName(
            .init("SwipeScrollDirectionDidChangeNotification"), object: nil, userInfo: nil, deliverImmediately: true
        )
    }
}
