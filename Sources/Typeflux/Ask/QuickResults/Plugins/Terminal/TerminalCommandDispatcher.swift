import AppKit
import Carbon
import Foundation

enum TerminalCommandError: Error, LocalizedError, Equatable {
    case notInstalled, permissionDenied, unavailable, uncertain

    var errorDescription: String? {
        switch self {
        case .notInstalled: L("terminal.command.notInstalled")
        case .permissionDenied: L("terminal.command.permissionDenied")
        case .unavailable: L("terminal.command.unavailable")
        case .uncertain: L("terminal.command.uncertain")
        }
    }
}

@MainActor
protocol TerminalCommandDispatching {
    func authorize(_ terminal: TerminalApplication) async throws
    func send(_ request: TerminalCommandRequest) async throws
}

/// No command is interpolated into source, a process argument or a temporary file.
/// The terminal owns the session and its processes after the Apple Event is sent.
@MainActor
final class TerminalCommandDispatcher: TerminalCommandDispatching {
    private nonisolated static let queue = DispatchQueue(label: "ai.typeflux.terminal-automation", qos: .userInitiated)
    private let applicationURL: (TerminalApplication) -> URL?
    private let launch: (URL) async throws -> Void
    private let consent: @Sendable (TerminalApplication) throws -> Void
    private let execute: @Sendable (TerminalCommandRequest) throws -> Void

    init(
        applicationURL: @escaping (TerminalApplication) -> URL? = {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleID)
        },
        launch: @escaping (URL) async throws -> Void = { url in
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        },
        consent: @escaping @Sendable (TerminalApplication) throws -> Void = {
            try TerminalCommandDispatcher.nativeConsent($0)
        },
        execute: @escaping @Sendable (TerminalCommandRequest) throws -> Void = {
            try TerminalCommandDispatcher.nativeExecute($0)
        }
    ) {
        self.applicationURL = applicationURL
        self.launch = launch
        self.consent = consent
        self.execute = execute
    }

    func authorize(_ terminal: TerminalApplication) async throws {
        guard let url = applicationURL(terminal) else {
            throw TerminalCommandError.notInstalled
        }
        // Consent preflight needs a running target. Do not activate it or choose an
        // existing session; the actual dispatch always creates a fresh window.
        do {
            try await launch(url)
        } catch {
            throw TerminalCommandError.unavailable
        }
        let consent = consent
        try await Self.work { try consent(terminal) }
    }

    func send(_ request: TerminalCommandRequest) async throws {
        guard TerminalCommandRequest.problem(with: request.command) == nil else {
            throw TerminalCommandError.unavailable
        }
        let execute = execute
        try await Self.work { try execute(request) }
    }

    private nonisolated static func nativeConsent(_ terminal: TerminalApplication) throws {
        let target = NSAppleEventDescriptor(bundleIdentifier: terminal.bundleID)
        let status = AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, true)
        guard status == noErr else { throw TerminalCommandError.permissionDenied }
    }

    private nonisolated static func nativeExecute(_ request: TerminalCommandRequest) throws {
        _ = try runScript(NSAppleScript(source: source(for: request.terminal)), command: request.command)
    }

    /// The same compiler/event/error boundary can be exercised with a local echo
    /// handler, without launching a terminal or asking for system permissions.
    nonisolated static func runScript(_ script: NSAppleScript?, command: String) throws -> NSAppleEventDescriptor {
        guard let script else { throw TerminalCommandError.unavailable }
        var error: NSDictionary?
        guard script.compileAndReturnError(&error) else { throw TerminalCommandError.unavailable }
        let result = script.executeAppleEvent(event(command: command), error: &error)
        // Once dispatched, even an error may mean the command already ran.
        // Never retry, switch terminals or report successful command execution.
        if error != nil {
            throw TerminalCommandError.uncertain
        }
        return result
    }

    nonisolated static func event(command: String) -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kASAppleScriptSuite),
                                           eventID: AEEventID(kASSubroutineEvent),
                                           targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID),
                                           transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(.init(string: "dispatchcommand"), forKeyword: AEKeyword(keyASSubroutineName))
        let arguments = NSAppleEventDescriptor.list()
        arguments.insert(.init(string: command), at: 1)
        event.setParam(arguments, forKeyword: AEKeyword(keyDirectObject))
        return event
    }

    nonisolated static func source(for terminal: TerminalApplication) -> String {
        let body = switch terminal {
        case .terminal:
            """
            tell application id "com.apple.Terminal"
                do script commandText
                activate
            end tell
            """
        case .iterm:
            """
            tell application id "com.googlecode.iterm2"
                set newWindow to (create window with default profile)
                tell current session of newWindow to write text commandText
                activate
            end tell
            """
        }
        return """
        on dispatchcommand(commandText)
            with timeout of 15 seconds
                \(body)
            end timeout
        end dispatchcommand
        """
    }

    private nonisolated static func work(_ operation: @escaping @Sendable () throws -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                autoreleasepool {
                    do {
                        try operation()
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }
}
