import Foundation

/// What the assistant's tools act on: the editor (or the new-workflow sheet) owns
/// the draft, the proposals and the decision to let code run.
@MainActor
protocol AskWorkflowAuthoringHost: AnyObject {
    /// The editor's draft with the latest proposal applied: what the assistant builds on.
    var authoringDraft: AskWorkflowDraft { get }
    /// The installed workflow being edited; nil while generating a new one.
    var authoringWorkflowID: String? { get }
    var lastTestResult: AskWorkflowTestResult? { get }
    func keywordProblem(_ keyword: String) -> String?
    /// Records a proposal; returns it with its risks filled in.
    func submit(_ proposal: AskWorkflowProposal) -> AskWorkflowProposal
    /// Runs the latest proposal with these inputs; nil when the user did not allow it.
    func testLatestProposal(_ inputs: [AskWorkflowTestInput]) async -> [AskWorkflowTestResult]?
}

/// The five tools the workflow assistant gets, and nothing else: no files, desktop,
/// browser or MCP tools. Every effect goes through a proposal or a test run the
/// host controls. See `docs/design/ask-workflow-editor.md` §10.4.
@MainActor
struct AskWorkflowAuthorTools {
    static let read = "workflow_read"
    static let environment = "workflow_environment"
    static let checkKeyword = "workflow_check_keyword"
    static let propose = "workflow_propose"
    static let test = "workflow_test"
    static let names: Set<String> = [read, environment, checkKeyword, propose, test]

    /// Output the model sees from one stream of a test run.
    nonisolated static let outputLimit = 4096
    static let maximumInputs = 5

    var probe = AskWorkflowEnvironmentProbe()

    struct Output: Equatable {
        var content: String
        var isError: Bool
        /// One line for the conversation: "Read the workflow", "Tested 3 inputs · 2 passed".
        var summary: String
        /// The proposal a successful `workflow_propose` recorded.
        var proposalID: UUID?
    }

    static var definitions: [AskToolDefinition] {
        [
            definition(read, """
            Read the workflow being written: its manifest, the list of files, validation problems and the last \
            test run. Pass `path` to read one file.
            """, ["path": ["type": "string"]], required: []),
            definition(environment, """
            List the script interpreters installed on this Mac with their versions, and look up commands on the \
            PATH (only looked up, never run).
            """, ["commands": ["type": "array", "items": ["type": "string"], "maxItems": 20]], required: []),
            definition(checkKeyword, "Check whether a launcher keyword is free to use.",
                       ["keyword": ["type": "string"]], required: ["keyword"]),
            definition(propose, """
            Propose the workflow: the complete manifest object and every file to write (full contents), plus \
            files to delete. Nothing is written until the user applies it. Returns problems to fix and the \
            detected risks.
            """, [
                "summary": ["type": "string", "description": "One or two sentences on what changed."],
                "manifest": ["type": "object", "description": "The complete workflow.json object."],
                "files": ["type": "array", "items": ["type": "object", "properties": [
                    "path": ["type": "string"], "content": ["type": "string"]
                ], "required": ["path", "content"]]],
                "delete": ["type": "array", "items": ["type": "string"]]
            ], required: ["summary", "manifest"]),
            definition(test, """
            Run the latest proposal on this Mac, once per input, the way the launcher runs it. Returns exit code, \
            duration, stdout and stderr (each cut to 4 KB). The user may decline.
            """, ["inputs": [
                "type": "array",
                "minItems": 1,
                "maxItems": maximumInputs,
                "items": ["type": "object", "properties": [
                    "query": ["type": "string", "description": "Text typed after the keyword."],
                    "selection": ["type": "string", "description": "Selected text, for workflows that take it."],
                    "keyword": ["type": "string", "description": "Which manifest keyword started it."]
                ], "required": ["query"]]
            ]], required: ["inputs"])
        ]
    }

    private static func definition(_ name: String, _ description: String, _ properties: [String: Any],
                                   required: [String]) -> AskToolDefinition {
        let schema: [String: Any] = ["type": "object", "properties": properties, "required": required,
                                     "additionalProperties": false]
        // Constant schemas: serialization cannot fail.
        let data = (try? JSONSerialization.data(withJSONObject: schema, options: .sortedKeys)) ?? Data("{}".utf8)
        return AskToolDefinition(name: name, description: description, parameters: JSONValue(data: data))
    }

    // MARK: - Execution

    func execute(_ call: AskToolCall, host: AskWorkflowAuthoringHost) async -> Output {
        let arguments = (try? JSONSerialization.jsonObject(
            with: Data(call.function.arguments.utf8)
        )) as? [String: Any] ??
            [:]
        switch call.function.name {
        case Self.read: return read(arguments, host: host)
        case Self.environment: return await environment(arguments)
        case Self.checkKeyword: return checkKeyword(arguments, host: host)
        case Self.propose: return propose(arguments, host: host)
        case Self.test: return await test(arguments, host: host)
        default:
            return Output(content: "Unknown tool \(call.function.name).", isError: true,
                          summary: L("ask.workflow.assistant.tool.unknown"))
        }
    }

    private func read(_ arguments: [String: Any], host: AskWorkflowAuthoringHost) -> Output {
        let draft = host.authoringDraft
        if let path = arguments["path"] as? String, !path.isEmpty {
            guard let text = draft.text(of: path) else {
                return Output(
                    content: "No text file \(path).",
                    isError: true,
                    summary: L("ask.workflow.assistant.tool.read", path)
                )
            }
            return Output(
                content: String(text.prefix(64000)),
                isError: false,
                summary: L("ask.workflow.assistant.tool.read", path)
            )
        }
        var object: [String: Any] = [
            "manifest": draft.manifestText,
            "files": draft.files.keys.sorted().map { ["path": $0, "bytes": draft.files[$0]?.utf8.count ?? 0] },
            "otherFiles": draft.otherFiles,
            "problems": draft.problems().map { ["field": $0.field, "message": $0.message] },
            "isNew": host.authoringWorkflowID == nil
        ]
        if let last = host.lastTestResult {
            object["lastTest"] = Self.describe(last)
        }
        return Output(
            content: Self.json(object),
            isError: false,
            summary: L("ask.workflow.assistant.tool.readWorkflow")
        )
    }

    private func environment(_ arguments: [String: Any]) async -> Output {
        let commands = (arguments["commands"] as? [String] ?? []).prefix(20).map(\.self)
        let report = await probe.report(commands: commands)
        return Output(content: report, isError: false, summary: L("ask.workflow.assistant.tool.environment"))
    }

    private func checkKeyword(_ arguments: [String: Any], host: AskWorkflowAuthoringHost) -> Output {
        let keyword = (arguments["keyword"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        let problem = host.keywordProblem(keyword)
        var object: [String: Any] = ["keyword": keyword, "available": problem == nil]
        if let problem {
            object["problem"] = problem
        }
        let summary = problem == nil ? L("ask.workflow.assistant.tool.keywordFree", keyword)
            : L("ask.workflow.assistant.tool.keywordTaken", keyword)
        return Output(content: Self.json(object), isError: false, summary: summary)
    }

    private func propose(_ arguments: [String: Any], host: AskWorkflowAuthoringHost) -> Output {
        let failed = L("ask.workflow.assistant.tool.proposeFailed")
        guard let manifest = arguments["manifest"] as? [String: Any],
              let text = AskWorkflowDraft.format(manifest) else {
            return Output(
                content: "`manifest` must be the complete workflow.json object.",
                isError: true,
                summary: failed
            )
        }
        var files: [String: String] = [:]
        for entry in arguments["files"] as? [[String: Any]] ?? [] {
            guard let path = entry["path"] as? String, let content = entry["content"] as? String else {
                return Output(content: "Each file needs `path` and `content`.", isError: true, summary: failed)
            }
            files[path] = content
        }
        let deletes = arguments["delete"] as? [String] ?? []
        if let problem = AskWorkflowProposal.problem(files: files, deletes: deletes) {
            return Output(content: problem, isError: true, summary: failed)
        }
        let summary = (arguments["summary"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        // The same manifest in another layout is no change: keep the user's text.
        let current = host.authoringDraft.manifestText.data(using: .utf8)
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? NSDictionary }
        let unchanged = current?.isEqual(to: manifest) == true
        var proposal = AskWorkflowProposal(summary: String(summary.prefix(1000)), manifestText: unchanged ? nil : text,
                                           files: files, deletes: deletes)
        let result = proposal.applied(to: host.authoringDraft)
        var problems = result.problems()
        // A keyword already used elsewhere is a problem only the host can see.
        for (index, keyword) in (result.manifest?.keywords ?? []).enumerated() {
            if let problem = host.keywordProblem(keyword.keyword) {
                problems.append(.init(field: "keywords[\(index)]", message: keyword.keyword + ": " + problem))
            }
        }
        if !problems.isEmpty {
            let list = problems.map { ["field": $0.field, "message": $0.message] }
            return Output(content: Self.json(["accepted": false, "problems": list]), isError: true, summary: failed)
        }
        proposal = host.submit(proposal)
        let risks = proposal.risks.sorted().map { ["kind": $0.kind.rawValue, "detail": $0.detail] }
        return Output(content: Self.json(["accepted": true, "risks": risks]), isError: false,
                      summary: L("ask.workflow.assistant.tool.proposed"), proposalID: proposal.id)
    }

    private func test(_ arguments: [String: Any], host: AskWorkflowAuthoringHost) async -> Output {
        let inputs = (arguments["inputs"] as? [[String: Any]] ?? []).prefix(Self.maximumInputs).map {
            AskWorkflowTestInput(query: $0["query"] as? String ?? "", selection: $0["selection"] as? String,
                                 keyword: $0["keyword"] as? String)
        }
        guard !inputs.isEmpty else {
            return Output(
                content: "Give at least one input.",
                isError: true,
                summary: L("ask.workflow.assistant.tool.testDeclined")
            )
        }
        guard let results = await host.testLatestProposal(inputs) else {
            return Output(
                content: "The user did not allow running this version. Do not test again; explain what the code does.",
                isError: true,
                summary: L("ask.workflow.assistant.tool.testDeclined")
            )
        }
        let passed = results.filter(\.succeeded).count
        return Output(content: Self.json(["results": results.map(Self.describe)]), isError: false,
                      summary: L("ask.workflow.assistant.tool.tested", results.count, passed))
    }

    // MARK: - Formatting

    static func describe(_ result: AskWorkflowTestResult) -> [String: Any] {
        var object: [String: Any] = [
            "query": result.input.query, "exitCode": Int(result.exitCode),
            "seconds": (result.duration * 100).rounded() / 100,
            "stdout": tail(result.stdout), "stderr": tail(result.stderr)
        ]
        if let selection = result.input.selection {
            object["selection"] = selection
        }
        if result.timedOut {
            object["timedOut"] = true
        }
        if result.truncated {
            object["truncated"] = true
        }
        if let failure = result.failure {
            object["notStarted"] = failure
        }
        return object
    }

    /// The end of an output stream, where errors are.
    nonisolated static func tail(_ text: String, limit: Int = outputLimit) -> String {
        guard text.utf8.count > limit else { return text }
        // Whole characters from the end, never a cut UTF-8 sequence.
        var tail = Substring(text)
        while tail.utf8.count > limit {
            tail = tail.dropFirst(max(1, (tail.utf8.count - limit) / 4))
        }
        return "…" + tail
    }

    nonisolated static func json(_ object: Any) -> String {
        guard let data = try? JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        ) else {
            return "{}"
        }
        return String(bytes: data, encoding: .utf8) ?? "{}"
    }
}

/// What the assistant may learn about this Mac: interpreters and their versions,
/// and whether commands exist on the PATH. Versions are read once by running the
/// interpreter with `--version` in the same clean environment as a workflow.
actor AskWorkflowEnvironmentProbe {
    static let interpreters = ["python3", "node", "bun", "deno", "zsh", "bash", "osascript"]
    private var runtimes: [String: Any]?
    private let runner: any AskWorkflowRunning
    private let searchPath: @Sendable () async -> String
    private let osVersion: String

    init(runner: any AskWorkflowRunning = AskWorkflowRunner(),
         searchPath: @escaping @Sendable () async -> String = { await AskWorkflowPath.searchPath() },
         osVersion: String = ProcessInfo.processInfo.operatingSystemVersionString) {
        self.runner = runner
        self.searchPath = searchPath
        self.osVersion = osVersion
    }

    /// A JSON object: the macOS version, each interpreter's version and path (null when
    /// missing), and each requested command's path (null when missing).
    func report(commands: [String]) async -> String {
        let path = await searchPath()
        if runtimes == nil {
            runtimes = await versions(path: path)
        }
        var found: [String: Any] = [:]
        for name in commands {
            guard name.range(of: "^[A-Za-z0-9._+-]{1,64}$", options: .regularExpression) != nil else { continue }
            found[name] = AskWorkflowPath.resolve(name, searchPath: path)?.path ?? NSNull()
        }
        return AskWorkflowAuthorTools.json(["macOS": osVersion, "runtimes": runtimes ?? [:], "commands": found])
    }

    private func versions(path: String) async -> [String: Any] {
        var result: [String: Any] = [:]
        for name in Self.interpreters {
            guard let program = AskWorkflowPath.resolve(name, searchPath: path)
            else { result[name] = NSNull(); continue }
            guard name != "osascript" else { result[name] = program.path; continue }
            let invocation = AskWorkflowInvocation(
                launch: .init(executable: program, arguments: ["--version"]),
                environment: ["PATH": path, "HOME": NSHomeDirectory(), "LANG": "en_US.UTF-8"],
                directory: URL(fileURLWithPath: NSTemporaryDirectory()), stdin: Data(), timeout: 3,
                stdoutLimit: 4096, stderrLimit: 4096
            )
            var version = ""
            do {
                for try await event in runner.run(invocation) {
                    guard case let .finished(finished) = event else { continue }
                    let output = finished.stdout + finished.stderr
                    version = output.split(separator: "\n").first.map(String.init) ?? ""
                }
            } catch {}
            result[name] = version.isEmpty ? program.path : version
                .trimmingCharacters(in: .whitespaces) + " · " + program.path
        }
        return result
    }
}
