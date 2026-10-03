import AppKit

@MainActor
final class AskBrowserExecutor {
    struct Target {
        let reference: AskObservationRef
        let stamp: String
    }

    let store: AskObservationStore
    let runner: any ProcessCommandRunning
    var writesEnabled = false
    var processInstance: (String) -> String? = { bundle in
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first,
              !app.isTerminated, let launch = app.launchDate else { return nil }
        return "\(app.processIdentifier):\(launch.timeIntervalSince1970)"
    }

    init(store: AskObservationStore, runner: any ProcessCommandRunning = AskAutomationScriptRunner()) {
        self.store = store; self.runner = runner
    }

    static func isObservation(_ args: [String: Any]) -> Bool {
        ["read", "snapshot"]
            .contains(args["action"] as? String ?? "")
    }

    func target(bundle: String) async throws -> Target {
        guard AskLocalTools.isSupportedBrowser(bundle),
              let process = processInstance(bundle) else { throw AskObservationError.needsObservation }
        let stamp = try await run(Self.appleScript(bundle: bundle))
        let fields = stamp.split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
        guard fields.count == 4, fields.allSatisfy({ !$0.isEmpty }), processInstance(bundle) == process else {
            throw AskObservationError.needsObservation
        }
        let target = AskExecutionTarget(kind: "browser_tab", id: bundle,
                                        version: AskToolPolicy.digest(process + ":" + stamp),
                                        domain: URL(string: fields[2])?.host?.lowercased())
        return .init(reference: .init(
            id: "",
            target: target,
            capturedAt: Date(),
            appId: bundle,
            processInstanceId: process,
            pid: process.split(separator: ":").first.flatMap { Int($0) },
            windowId: fields[0],
            browserId: bundle,
            tabId: fields[1],
            documentGeneration: fields[3]
        ), stamp: stamp)
    }

    func binding(_ args: [String: Any], bundle: String,
                 scope: AskObservationStore.Scope) async throws -> AskExecutionTarget {
        if !Self.isObservation(args), !writesEnabled {
            throw AskObservationError.disabled
        }
        let current = try await target(bundle: bundle)
        if Self.isObservation(args) {
            return current.reference.target
        }
        let reference = try store.validate(
            id: args["observation_id"] as? String,
            scope: scope,
            target: current.reference.target
        )
        _ = try Self.command(args) // Reject malformed commands before authorization.
        return AskObservationStore.boundTarget(reference)
    }

    func execute(_ args: [String: Any], bundle: String, scope: AskObservationStore.Scope,
                 approved: AskExecutionTarget? = nil,
                 authorize: () throws -> Void = {}) async throws -> AskLocalToolOutput {
        if !Self.isObservation(args), !writesEnabled {
            throw AskObservationError.disabled
        }
        let current = try await target(bundle: bundle)
        try Task.checkCancellation()
        if Self.isObservation(args) {
            guard approved == nil || approved == current.reference.target
            else { throw AskObservationError.needsObservation }
            try authorize()
            store.invalidate(scope: scope)
            let id = UUID().uuidString
            let body = try await run(Self.appleScript(bundle: bundle, expected: current.stamp,
                                                      javascript: Self.observationScript(
                                                          id: id,
                                                          read: args["action"] as? String == "read"
                                                      )))
            let after = try await target(bundle: bundle)
            try Task.checkCancellation()
            guard after.reference.target == current.reference.target,
                  let data = body.data(using: .utf8),
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["observation_id"] as? String == id else { throw AskObservationError.needsObservation }
            let reference = store.record(current.reference, scope: scope, id: id)
            return AskActionReceipt.observed(body, reference: reference).output()
        }
        let reference = try store.validate(
            id: args["observation_id"] as? String,
            scope: scope,
            target: current.reference.target
        )
        guard approved == nil || approved == AskObservationStore.boundTarget(reference)
        else { throw AskObservationError.needsObservation }
        let command = try Self.command(args)
        try authorize()
        try Task.checkCancellation()
        _ = try store.consume(id: reference.id, scope: scope, target: current.reference.target)
        // From this boundary onward, transport loss/cancellation leaves the effect unknown.
        do {
            let result = try await run(Self.appleScript(bundle: bundle, expected: current.stamp,
                                                        javascript: Self.actionScript(
                                                            id: reference.id,
                                                            command: command
                                                        )))
            return try Self.receipt(result).output()
        } catch {
            return AskActionReceipt(
                outcome: .init(status: "unknown", effectVerified: false),
                message: "Action result unknown. Observe and reconcile; do not automatically replay."
            ).output()
        }
    }

    private func run(_ source: String) async throws -> String {
        let result = try await runner.run(executablePath: "/usr/bin/osascript", arguments: ["-e", source])
        guard result.exitCode == 0 else { throw AskAutomationError.unavailable }
        return result.stdout.trimmingCharacters(in: .newlines)
    }

    static func receipt(_ text: String) throws -> AskActionReceipt {
        guard let data = text.data(using: .utf8),
              let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = value["status"] as? String, AskExecutionStatus(rawValue: status) != nil,
              let message = value["message"] as? String else { throw AskAutomationError.unavailable }
        return .init(outcome: .init(status: status, eventDispatched: value["event_dispatched"] as? Bool,
                                    effectVerified: value["effect_verified"] as? Bool), message: message)
    }

    // Explicit action validation stays together so every command is checked before dispatch.
    // swiftlint:disable:next cyclomatic_complexity
    static func command(_ args: [String: Any]) throws -> String {
        let action = args["action"] as? String ?? ""
        var command: [String: Any] = ["action": action]
        switch action {
        case "open":
            guard let raw = args["url"] as? String, raw.count <= 4000, let url = URL(string: raw),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  url.host != nil else { throw AskObservationError.invalid }
            command["url"] = raw
        case "click", "fill":
            if let ref = args["ref"] as? String, !ref.isEmpty {
                command["ref"] = ref
            } else if let selector = args["selector"] as? String, !selector.isEmpty,
                      selector.count <= 2000 {
                command["selector"] = selector
            } else {
                throw AskObservationError.invalid
            }
            if action == "fill" {
                guard let text = args["text"] as? String,
                      text.utf16.count <= 10000 else { throw AskObservationError.invalid }
                command["text"] = text
            }
        case "scroll":
            guard let amount = args["amount"] as? Int,
                  (-10 ... 10).contains(amount) else { throw AskObservationError.invalid }
            command["amount"] = amount
        case "back": break
        default: throw AskObservationError.invalid
        }
        let data = try JSONSerialization.data(withJSONObject: command, options: [.sortedKeys])
        guard let result = String(data: data, encoding: .utf8) else { throw AskObservationError.invalid }
        return result
    }

    /// OS-owned window/tab selection is pinned for this script. Page evidence is
    /// defense against stale UI, not a security boundary against hostile page JS.
    static func appleScript(bundle: String, expected: String? = nil, javascript: String? = nil) -> String {
        let safari = bundle == "com.apple.Safari"
        let execute: (String) -> String = { source in
            safari ? "do JavaScript \(AskLocalTools.appleScriptLiteral(source)) in approvedTab"
                : "execute approvedTab javascript \(AskLocalTools.appleScriptLiteral(source))"
        }
        var action = "return stamp"
        if let javascript, let expected {
            let fields = expected.split(separator: "\u{1f}", omittingEmptySubsequences: false)
            guard fields.count == 4 else { return "error \"needs-observation\"" }
            let guarded = "(()=>{if(location.href!==\(AskLocalTools.javascriptLiteral(String(fields[2])))||String(performance.timeOrigin)!==\(AskLocalTools.javascriptLiteral(String(fields[3]))))throw new Error('needs-observation');return \(javascript);})()"
            action = "return (\(execute(guarded)))"
        }
        return """
        with timeout of 20 seconds
        tell application id \(AskLocalTools.appleScriptLiteral(bundle))
        set approvedWindow to front window
        set approvedTab to \(safari ? "current tab" : "active tab") of approvedWindow
        set documentGeneration to (\(execute("String(performance.timeOrigin)")))
        set stamp to (id of approvedWindow as text) & (ASCII character 31) & (\(safari ? "index" : "id") of approvedTab as text) & (ASCII character 31) & (URL of approvedTab) & (ASCII character 31) & documentGeneration
        \(expected.map { "if stamp is not \(AskLocalTools.appleScriptLiteral($0)) then error \"needs-observation\"" } ?? "")
        \(action)
        end tell
        end timeout
        """
    }
}
