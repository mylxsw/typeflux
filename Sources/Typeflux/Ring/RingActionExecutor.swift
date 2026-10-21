import AppKit
import Foundation
import IOKit.pwr_mgt

/// The macOS side effects of ring actions, behind a protocol so the executor is tested
/// without opening apps or sending keys.
@MainActor
protocol RingSystemEnvironment: AnyObject {
    func applicationURL(bundleIdentifier: String) -> URL?
    func openApplication(at url: URL)
    func open(_ url: URL)
    func directoryExists(atPath path: String) -> Bool
    func runProcess(_ executable: String, arguments: [String])
    /// Returns false when the script failed, e.g. because automation was not allowed.
    func runAppleScript(_ source: String) -> Bool
    func postKeyStroke(keyCode: Int, modifierFlags: UInt)
    func activate(_ application: NSRunningApplication?)
    /// Turns the "prevent sleep" assertion on or off; returns whether it is on afterwards.
    func setKeepAwake(_ enabled: Bool) -> Bool
}

/// Runs a ring slice. Typeflux features and keywords are handed back to the app coordinator,
/// which owns those windows; the rest are done here.
@MainActor
final class RingActionExecutor {
    struct Handlers {
        var feature: (RingFeature) -> Void = { _ in }
        var keyword: (KeywordHotkey) -> Void = { _ in }
    }

    static let missionControlURL = URL(fileURLWithPath: "/System/Applications/Mission Control.app")
    static let shortcutsExecutable = "/usr/bin/shortcuts"
    /// Lets the closing ring hand focus back before keys are sent.
    static let keyStrokeDelay: Duration = .milliseconds(120)

    var handlers = Handlers()
    /// Tells the user why an action could not run.
    var onFailure: (String) -> Void = { _ in }
    private let environment: any RingSystemEnvironment
    private(set) var keepAwake = false

    init(environment: any RingSystemEnvironment) {
        self.environment = environment
    }

    func perform(_ action: RingAction, previousApplication: NSRunningApplication?) async {
        switch action.kind {
        case let .feature(feature):
            handlers.feature(feature)
        case let .keyword(keyword, pluginID):
            handlers.keyword(KeywordHotkey(binding: nil, keyword: keyword, pluginID: pluginID))
        case .app, .url, .folder:
            open(action.kind)
        case let .keys(binding):
            await sendKeys(keyCode: binding.keyCode, flags: binding.modifierFlags, to: previousApplication)
        case let .system(system):
            await perform(system, previousApplication: previousApplication)
        case let .shortcut(name):
            environment.runProcess(Self.shortcutsExecutable, arguments: ["run", name])
        }
    }

    /// Apps, web pages and folders: things that open, after checking they exist.
    private func open(_ kind: RingActionKind) {
        switch kind {
        case let .app(bundleIdentifier, name):
            guard let url = environment.applicationURL(bundleIdentifier: bundleIdentifier) else {
                return onFailure(L("ring.error.appMissing", name))
            }
            environment.openApplication(at: url)
        case let .url(text):
            guard let url = RingSettingsPresentation.webURL(text) else {
                return onFailure(L("ring.error.invalidURL"))
            }
            environment.open(url)
        case let .folder(path):
            let expanded = RingSettingsPresentation.expandedFolderPath(path)
            guard environment.directoryExists(atPath: expanded) else {
                return onFailure(L("ring.error.folderMissing", path))
            }
            environment.open(URL(fileURLWithPath: expanded, isDirectory: true))
        default:
            break
        }
    }

    private func perform(_ system: RingSystemAction, previousApplication: NSRunningApplication?) async {
        switch system {
        case .darkMode:
            let script = "tell application \"System Events\" to tell appearance preferences "
                + "to set dark mode to not dark mode"
            if !environment.runAppleScript(script) { onFailure(L("ring.error.automation")) }
        case .mute:
            if !environment.runAppleScript("set volume output muted not (output muted of (get volume settings))") {
                onFailure(L("ring.error.automation"))
            }
        case .missionControl:
            environment.openApplication(at: Self.missionControlURL)
        case .lockScreen:
            // ⌃⌘Q, the system's own lock shortcut.
            await sendKeys(keyCode: 12, flags: Self.flags([.control, .command]), to: nil)
        case .emoji:
            // ⌃⌘Space opens the character viewer for the app the user was typing in.
            await sendKeys(keyCode: 49, flags: Self.flags([.control, .command]), to: previousApplication)
        case .keepAwake:
            keepAwake = environment.setKeepAwake(!keepAwake)
        }
    }

    private func sendKeys(keyCode: Int, flags: UInt, to application: NSRunningApplication?) async {
        environment.activate(application)
        try? await Task.sleep(for: Self.keyStrokeDelay)
        environment.postKeyStroke(keyCode: keyCode, modifierFlags: flags)
    }

    static func flags(_ flags: NSEvent.ModifierFlags) -> UInt {
        UInt(flags.rawValue)
    }
}

/// The real environment.
@MainActor
final class LiveRingSystemEnvironment: RingSystemEnvironment {
    private var keepAwakeAssertion: IOPMAssertionID = 0

    func applicationURL(bundleIdentifier: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
    }

    func openApplication(at url: URL) {
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    func directoryExists(atPath path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    func runProcess(_ executable: String, arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            ErrorLogStore.shared.log("Ring: failed to run \(executable): \(error.localizedDescription)")
        }
    }

    func runAppleScript(_ source: String) -> Bool {
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            ErrorLogStore.shared.log("Ring: AppleScript failed: \(error)")
            return false
        }
        return true
    }

    func postKeyStroke(keyCode: Int, modifierFlags: UInt) {
        let source = CGEventSource(stateID: .hidSystemState)
        let flags = Self.eventFlags(modifierFlags)
        for keyDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: keyDown)
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
        }
    }

    func activate(_ application: NSRunningApplication?) {
        guard let application, application.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            return
        }
        if #available(macOS 14.0, *) {
            application.activate()
        } else {
            application.activate(options: [])
        }
    }

    func setKeepAwake(_ enabled: Bool) -> Bool {
        if keepAwakeAssertion != 0 {
            IOPMAssertionRelease(keepAwakeAssertion)
            keepAwakeAssertion = 0
        }
        guard enabled else { return false }
        let status = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                                 IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                 "Typeflux ring: keep awake" as CFString, &keepAwakeAssertion)
        return status == kIOReturnSuccess
    }

    static func eventFlags(_ modifierFlags: UInt) -> CGEventFlags {
        let flags = NSEvent.ModifierFlags(rawValue: modifierFlags)
        var result: CGEventFlags = []
        if flags.contains(.command) { result.insert(.maskCommand) }
        if flags.contains(.option) { result.insert(.maskAlternate) }
        if flags.contains(.control) { result.insert(.maskControl) }
        if flags.contains(.shift) { result.insert(.maskShift) }
        if flags.contains(.function) { result.insert(.maskSecondaryFn) }
        return result
    }
}
