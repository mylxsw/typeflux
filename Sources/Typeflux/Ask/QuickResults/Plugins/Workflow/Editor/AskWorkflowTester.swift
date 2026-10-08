import Foundation

/// One test run's input, as the editor's test panel or the assistant gives it.
struct AskWorkflowTestInput: Equatable, Sendable {
    var query: String
    var selection: String?
    /// Which of the manifest's keywords started it (its preset options apply); the first by default.
    var keyword: String?

    init(query: String, selection: String? = nil, keyword: String? = nil) {
        self.query = query
        self.selection = selection
        self.keyword = keyword
    }
}

/// How a test run ended, with what the script received.
struct AskWorkflowTestResult: Equatable, Sendable {
    var input: AskWorkflowTestInput
    var exitCode: Int32
    var stdout: String
    var stderr: String
    var duration: Double
    var timedOut = false
    var truncated = false
    /// The run could not start (no interpreter, invalid manifest); nothing ran.
    var failure: String?
    var arguments: [String] = []
    /// `TYPEFLUX_*` and the manifest's own variables; the basics (`HOME`, `PATH`) are left out.
    var environment: [String: String] = [:]
    var stdin = ""
    var date = Date()
    /// The workflow's actions for this run, filled in: the failure list after a failure.
    var actionSteps: [AskWorkflowActionStep] = []
    /// Where each action ended: previewed, or run when the test ran them for real.
    var actionOutcomes: [AskWorkflowActionOutcome] = []

    var succeeded: Bool {
        failure == nil && !timedOut && !truncated && exitCode == 0
    }

    /// The launcher would take the failure actions: it timed out, failed, or was cut short.
    var takesFailureActions: Bool {
        timedOut || exitCode != 0 || truncated
    }

    /// Why the run failed, as the launcher says it, with the end of stderr: the `{error}` placeholder.
    func errorText(timeout: Double, folder: URL?) -> String? {
        guard failure == nil, takesFailureActions else { return nil }
        let reason = timedOut ? L("ask.workflow.timedOut", Int(timeout))
            : exitCode != 0 ? AskWorkflowPlugin.errorMessage(in: stdout) ?? L("ask.workflow.failed", Int(exitCode))
            : L("ask.workflow.truncated")
        return reason + AskWorkflowPlugin.tail(stderr, folder: folder)
    }

    /// The placeholders' values for this run. A script that printed `{"text": …,
    /// "actions": …}` has its text as `{output}`, as in the launcher.
    func placeholders(keyword: String, options: [String: String], timeout: Double,
                      folder: URL?) -> AskWorkflowPlaceholders {
        let script = AskWorkflowScriptOutput.parse(stdout)
        return AskWorkflowPlaceholders(output: script?.text ?? stdout, query: input.query, selection: input.selection,
                                       keyword: keyword, options: options,
                                       error: errorText(timeout: timeout, folder: folder),
                                       json: script == nil ? nil : stdout)
    }

    /// One line for lists: "✓ exit 0 · 0.62 s".
    var summary: String {
        if let failure {
            return failure
        }
        if timedOut {
            return L("ask.workflow.editor.test.timedOut", duration)
        }
        return L("ask.workflow.editor.test.summary", Int(exitCode), duration)
    }
}

/// Runs a workflow folder the way the launcher would: the same plugin builds the
/// command, the same clean environment and stdin, the same runner with its limits.
/// Only the request is made up, from the test input.
struct AskWorkflowTester: Sendable {
    var runner: any AskWorkflowRunning = AskWorkflowRunner()
    var searchPath: @Sendable () async -> String = { await AskWorkflowPath.searchPath() }
    var home = NSHomeDirectory()
    var language: AppLanguage = .english
    var record: @Sendable (AskWorkflowLog.Entry) -> Void = { _ in }

    /// Runs `workflow` (trusted or not: the caller decides whether it may run) with `input`.
    func run(_ workflow: AskWorkflow, input: AskWorkflowTestInput) async -> AskWorkflowTestResult {
        var result = AskWorkflowTestResult(input: input, exitCode: -1, stdout: "", stderr: "", duration: 0)
        guard let manifest = workflow.manifest else {
            result.failure = L("ask.workflow.invalid")
            return result
        }
        if case let .invalid(problems) = workflow.status {
            result.failure = L("ask.workflow.blocked.invalid", problems.first?.message ?? "")
            return result
        }
        let plugin = AskWorkflowPlugin(workflow: workflow, runner: runner, searchPath: searchPath, home: home)
        let keyword = plugin.defaultKeywords.first { $0.keyword == input.keyword } ?? plugin.defaultKeywords.first
            ?? AskKeyword(keyword: manifest.keywords.first?.keyword ?? "", pluginID: plugin.id)
        let request = AskPluginRequest(text: input.query, origin: .argument, keyword: keyword, options: keyword.options,
                                       interfaceLanguage: language, selection: input.selection)
        let pluginInput = plugin.input(for: request)
        guard manifest.input.argument != .required || !pluginInput.query.isEmpty || pluginInput.selection != nil else {
            result.failure = L("ask.workflow.needsInput")
            return result
        }
        let path = await searchPath()
        let invocation: AskWorkflowInvocation
        do {
            invocation = try plugin.invocation(for: request, input: pluginInput, manifest: manifest,
                                               source: ("Typeflux", Bundle.main.bundleIdentifier), path: path)
        } catch {
            result.failure = (error as? AskPluginFailure)?.message ?? error.localizedDescription
            return result
        }
        let basics: Set = ["HOME", "USER", "LOGNAME", "PATH", "LANG", "LC_ALL", "TMPDIR", "SHELL",
                           "PYTHONIOENCODING", "PYTHONUNBUFFERED"]
        result.arguments = invocation.launch.arguments
        result.environment = invocation.environment.filter { !basics.contains($0.key) && $0.key != "TYPEFLUX_RUN_ID" }
        result.stdin = String(data: invocation.stdin, encoding: .utf8)?.trimmingCharacters(in: .newlines) ?? ""
        await execute(invocation, into: &result)
        guard result.failure == nil else { return result }
        let options = request.options.filter { $0.key != AskWorkflowPlugin.titleOption }
        result.actionSteps = actionSteps(of: result, manifest: manifest, folder: workflow.folder,
                                         keyword: keyword.keyword, options: options)
        record(AskWorkflowLog.Entry(workflowID: workflow.id, keyword: keyword.keyword, date: Date(),
                                    duration: result.duration, exitCode: result.exitCode, timedOut: result.timedOut,
                                    stderr: String(result.stderr.suffix(4096)), source: .test))
        return result
    }

    /// The run's actions filled in, as the launcher would take them: the failure list
    /// after a failure; after a success, the configured ones and then what the script
    /// added (run only when the manifest allows it).
    private func actionSteps(of result: AskWorkflowTestResult, manifest: AskWorkflowManifest, folder: URL,
                             keyword: String, options: [String: String]) -> [AskWorkflowActionStep] {
        let output = manifest.output
        let placeholders = result.placeholders(keyword: keyword, options: options, timeout: manifest.timeout,
                                               folder: folder)
        var steps = AskWorkflowActionRunner.steps(
            for: result.takesFailureActions ? output.onFailure : output.onSuccess, placeholders: placeholders,
            folder: folder, name: manifest.name, home: home, chain: [keyword]
        )
        if !result.takesFailureActions, let script = AskWorkflowScriptOutput.parse(result.stdout) {
            steps += AskWorkflowActionRunner.scriptSteps(
                script.actions, allowed: output.scriptActions, folder: folder, name: manifest.name, home: home,
                chain: [keyword], knownHosts: { AskWorkflowScriptOutput.knownHosts(in: folder) }
            )
        }
        return steps
    }

    /// Runs the process and copies how it ended into `result`.
    private func execute(_ invocation: AskWorkflowInvocation, into result: inout AskWorkflowTestResult) async {
        do {
            try Task.checkCancellation()
            for try await event in runner.run(invocation) {
                guard case let .finished(finished) = event else { continue }
                result.exitCode = finished.exitCode
                result.stdout = finished.stdout
                result.stderr = finished.stderr
                result.duration = finished.duration
                result.timedOut = finished.timedOut
                result.truncated = finished.truncated
            }
        } catch let AskWorkflowRunError.spawnFailed(code) {
            result.failure = L("ask.workflow.spawnFailed", String(cString: strerror(code)))
        } catch {
            result.failure = error.localizedDescription
        }
    }
}
