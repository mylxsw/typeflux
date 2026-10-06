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

    var succeeded: Bool {
        failure == nil && !timedOut && exitCode == 0
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
        record(AskWorkflowLog.Entry(workflowID: workflow.id, keyword: keyword.keyword, date: Date(),
                                    duration: result.duration, exitCode: result.exitCode, timedOut: result.timedOut,
                                    stderr: String(result.stderr.suffix(4096)), source: .test))
        return result
    }

    /// Runs the process and copies how it ended into `result`.
    private func execute(_ invocation: AskWorkflowInvocation, into result: inout AskWorkflowTestResult) async {
        do {
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
