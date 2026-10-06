import Foundation

/// One installed workflow as a launcher plugin: its keywords start it, its script
/// runs on Return, and what it prints becomes a text card (or the launcher just
/// closes when it prints nothing).
struct AskWorkflowPlugin: AskLauncherPlugin {
    static let idPrefix = "workflow."
    /// Option the keyword carries: its title from the manifest, for the chip.
    static let titleOption = "title"

    var workflow: AskWorkflow
    var runner: any AskWorkflowRunning = AskWorkflowRunner()
    /// Finds a program by name; production reads the login shell's PATH.
    var searchPath: @Sendable () async -> String = { await AskWorkflowPath.searchPath() }
    /// The app the launcher came from, for `TYPEFLUX_SOURCE_APP`.
    var source: @MainActor @Sendable () -> (app: String?, bundleID: String?) = { (nil, nil) }
    var record: @Sendable (AskWorkflowLog.Entry) -> Void = { _ in }
    var home = NSHomeDirectory()

    var manifest: AskWorkflowManifest? { workflow.manifest }
    var id: String { Self.idPrefix + workflow.id }
    var title: String { manifest?.name ?? workflow.id }
    var symbol: String { workflow.symbol }
    var runsWithoutInput: Bool { manifest?.input.argument != .required }

    /// The keywords the manifest declares, carrying their titles as options.
    var defaultKeywords: [AskKeyword] {
        (manifest?.keywords ?? []).map { keyword in
            var options = keyword.options ?? [:]
            if let title = keyword.title { options[Self.titleOption] = title }
            return AskKeyword(keyword: keyword.keyword, pluginID: id, options: options)
        }
    }

    func placeholder(selectionLines: Int?) -> String {
        let usesSelection = manifest?.input.selection != .never
        if let selectionLines, selectionLines > 0, usesSelection {
            return L("ask.workflow.placeholder.selection", selectionLines)
        }
        return manifest?.description ?? L("ask.workflow.placeholder")
    }

    func chipDetail(for keyword: AskKeyword, language: AppLanguage) -> String? { keyword.options[Self.titleOption] }

    // MARK: - Plan

    /// What the script gets: the typed text, and the selection when the manifest takes it.
    struct Input: Equatable {
        var query: String
        var selection: String?
    }

    func input(for request: AskPluginRequest) -> Input {
        let wantsSelection = manifest?.input.selection ?? .ifEmpty
        let query = request.origin == .argument ? request.text : ""
        switch wantsSelection {
        case .never: return Input(query: query, selection: nil)
        case .always: return Input(query: query, selection: request.selection)
        case .ifEmpty: return Input(query: query, selection: query.isEmpty ? request.selection : nil)
        }
    }

    /// Workflows run only on Return (W1), and only when they can.
    func plan(_ request: AskPluginRequest) async -> AskPluginPlan {
        let input = input(for: request)
        let runtime = manifest.map { AskPluginMeta(text: $0.command.runtime.title) }
        var values: [String: String] = [:]
        let title: String
        if let blocked = workflow.blockedReason {
            title = blocked
            values["blocked"] = blocked
        } else if manifest?.input.argument == .required, input.query.isEmpty, input.selection == nil {
            title = L("ask.workflow.needsInput")
            values["blocked"] = title
        } else if let selection = input.selection, input.query.isEmpty {
            title = L("ask.workflow.plan.selection", self.title, selection.split(separator: "\n").count)
        } else if !input.query.isEmpty {
            title = L("ask.workflow.plan.query", self.title, input.query)
        } else {
            title = L("ask.workflow.plan.run", self.title)
        }
        return AskPluginPlan(mode: .onSubmit, title: title, meta: runtime.map { [$0] } ?? [], values: values)
    }

    // MARK: - Run

    func run(_ request: AskPluginRequest, plan: AskPluginPlan,
             progress: @escaping AskPluginProgress) async throws -> AskPluginOutput {
        if let blocked = plan.values["blocked"] {
            throw AskPluginFailure(message: blocked, retry: false, actions: editActions())
        }
        guard let manifest else {
            throw AskPluginFailure(message: L("ask.workflow.invalid"), retry: false, actions: editActions())
        }
        // Trust was checked when the launcher opened; the files may have changed since.
        guard AskWorkflow.contentHash(of: workflow.folder) == workflow.hash else {
            throw AskPluginFailure(message: L("ask.workflow.blocked.modified"), retry: false, actions: editActions())
        }
        let input = input(for: request)
        let source = await source()
        let path = await searchPath()
        let invocation: AskWorkflowInvocation
        do {
            invocation = try self.invocation(for: request, input: input, manifest: manifest, source: source, path: path)
        } catch var failure as AskPluginFailure {
            failure.actions = editActions()
            throw failure
        }
        var result: AskWorkflowRunResult?
        do {
            for try await event in runner.run(invocation) {
                switch event {
                case let .output(text) where manifest.output != .none:
                    await progress(output(text, request: request, plan: plan, input: input, duration: nil))
                case .output:
                    break
                case let .finished(finished):
                    result = finished
                }
            }
        } catch let AskWorkflowRunError.spawnFailed(code) {
            throw AskPluginFailure(message: L("ask.workflow.spawnFailed", String(cString: strerror(code))),
                                   actions: editActions())
        }
        try Task.checkCancellation()
        guard let result else { throw CancellationError() }
        record(AskWorkflowLog.Entry(workflowID: workflow.id, keyword: request.keyword.keyword, date: Date(),
                                    duration: result.duration, exitCode: result.exitCode, timedOut: result.timedOut,
                                    stderr: String(result.stderr.suffix(4096))))
        return try finish(result, request: request, plan: plan, input: input, manifest: manifest)
    }

    private func finish(_ result: AskWorkflowRunResult, request: AskPluginRequest, plan: AskPluginPlan, input: Input,
                        manifest: AskWorkflowManifest) throws -> AskPluginOutput {
        if result.timedOut {
            let reason = L("ask.workflow.timedOut", Int(manifest.timeout))
            throw AskPluginFailure(message: reason + Self.tail(result.stderr, folder: workflow.folder),
                                   actions: editActions(query: input.query, stderr: result.stderr, reason: reason))
        }
        let text = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        // A run cut off for printing too much still shows what it printed.
        if result.exitCode != 0, !result.truncated {
            let reason = Self.errorMessage(in: result.stdout) ?? L("ask.workflow.failed", Int(result.exitCode))
            throw AskPluginFailure(message: reason + Self.tail(result.stderr, folder: workflow.folder),
                                   actions: editActions(query: input.query, stderr: result.stderr, reason: reason))
        }
        if manifest.output == .none || text.isEmpty {
            var done = output("", request: request, plan: plan, input: input, duration: result.duration)
            done.dismisses = true
            return done
        }
        var shown = output(text, request: request, plan: plan, input: input, duration: result.duration)
        if result.truncated { shown.note = L("ask.workflow.truncated") }
        return shown
    }

    private func output(_ text: String, request: AskPluginRequest, plan: AskPluginPlan, input: Input,
                        duration: Double?) -> AskPluginOutput {
        let replaces = input.selection != nil && input.query.isEmpty
        let original = input.query.isEmpty ? input.selection ?? "" : input.query
        let source = duration.map { L("ask.workflow.source", manifest?.command.runtime.title ?? "", $0) }
            ?? manifest?.command.runtime.title ?? ""
        let actions = [
            AskPluginAction(kind: .copy(text), title: L("ask.plugin.action.copy"), symbol: "doc.on.doc", shortcut: .enter),
            AskPluginAction(kind: .writeBack(text),
                            title: L(replaces ? "ask.plugin.action.replace" : "ask.plugin.action.insert"),
                            symbol: replaces ? "arrow.down.to.line" : "text.insert", shortcut: .optionEnter),
            AskPluginAction(kind: .compare, title: L("ask.plugin.action.compare"), symbol: "rectangle.split.1x2",
                            shortcut: .commandD),
            AskPluginAction(kind: .rerun([:]), title: L("ask.workflow.action.rerun"), symbol: "arrow.clockwise",
                            shortcut: .commandR),
            AskPluginAction(kind: .askAI(L("ask.workflow.askAI", title, original, text)),
                            title: L("ask.quick.askAI"), symbol: "bubble.left", shortcut: nil)
        ] + editActions().prefix(1)
        return AskPluginOutput(body: text, original: original, meta: [], source: source, actions: actions)
    }

    /// ⌘E opens the workflow in the editor, at the line stderr points to; after a
    /// failed run the assistant can also be asked to fix it.
    func editActions(query: String? = nil, stderr: String = "", reason: String = "") -> [AskPluginAction] {
        let files = Set([manifest?.command.script].compactMap { $0 })
        let location = AskWorkflowStderrLocator.locate(stderr, folder: workflow.folder, files: files)
        var actions = [AskPluginAction(kind: .editWorkflow(id: workflow.id, path: location?.path, line: location?.line),
                                       title: L("ask.workflow.action.edit"), symbol: "pencil", shortcut: .commandE)]
        if let query {
            let error = (reason + Self.tail(stderr, lines: 20)).trimmingCharacters(in: .whitespacesAndNewlines)
            actions.append(AskPluginAction(kind: .copy(error), title: L("ask.workflow.action.copyError"),
                                           symbol: "doc.on.doc", shortcut: .commandC))
            actions.append(AskPluginAction(kind: .fixWorkflow(id: workflow.id, query: query, error: error),
                                           title: L("ask.workflow.action.fix"), symbol: "sparkles", shortcut: nil))
        }
        return actions
    }

    /// The last lines a failed script wrote to stderr, to show under the reason. Paths
    /// inside `folder` are shown relative to it: "main.sh:4: …".
    static func tail(_ stderr: String, lines: Int = 6, folder: URL? = nil) -> String {
        let kept = stderr.split(separator: "\n", omittingEmptySubsequences: true).suffix(lines)
        guard !kept.isEmpty else { return "" }
        var text = "\n" + kept.joined(separator: "\n")
        if let folder {
            // Temporary folders appear both as /var/… and /private/var/….
            let path = folder.standardizedFileURL.path
            let plain = path.hasPrefix("/private/") ? String(path.dropFirst("/private".count)) : path
            for prefix in ["/private" + plain + "/", plain + "/"] {
                text = text.replacingOccurrences(of: prefix, with: "")
            }
        }
        return text
    }

    /// A script may explain its failure itself by printing `{"error": "…"}` as its last line.
    static func errorMessage(in stdout: String) -> String? {
        guard let line = stdout.split(separator: "\n").last,
              let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = object["error"] as? String, !message.isEmpty else { return nil }
        return message
    }

    // MARK: - Process

    func invocation(for request: AskPluginRequest, input: Input, manifest: AskWorkflowManifest,
                    source: (app: String?, bundleID: String?), path: String) throws -> AskWorkflowInvocation {
        let script = manifest.command.script.flatMap { AskWorkflowManifest.scriptURL($0, in: workflow.folder) }
        let options = request.options.filter { $0.key != Self.titleOption }
        let arguments = AskWorkflowManifest.arguments(manifest.argumentTemplate, query: input.query,
                                                      selection: input.selection, options: options)
        let launch: AskWorkflowRuntime.Launch
        do {
            launch = try manifest.command.runtime.launch(script: script, inline: manifest.command.inline, arguments: arguments,
                                                         interpreter: manifest.command.interpreter, name: manifest.id) {
                AskWorkflowPath.resolve($0, searchPath: path)
            }
        } catch let AskWorkflowRuntime.LaunchError.missing(name) {
            throw AskPluginFailure(message: L("ask.workflow.missingRuntime", name), retry: false)
        }
        let environment = environment(request: request, input: input, manifest: manifest, path: path, source: source)
        return AskWorkflowInvocation(launch: launch, environment: environment, directory: workflow.folder,
                                     stdin: Self.stdin(request: request, input: input, source: source),
                                     timeout: manifest.timeout)
    }

    /// A clean environment: the basics a program expects, the request, and the
    /// manifest's own variables. Nothing of Typeflux's own environment gets through.
    func environment(request: AskPluginRequest, input: Input, manifest: AskWorkflowManifest, path: String,
                     source: (app: String?, bundleID: String?)) -> [String: String] {
        let data = AskWorkflow.dataDirectory(for: workflow.id, home: home)
        let cache = AskWorkflow.cacheDirectory(for: workflow.id, home: home)
        let (app, bundleID) = source
        var environment: [String: String] = [
            "HOME": home, "USER": NSUserName(), "LOGNAME": NSUserName(), "PATH": path,
            "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8", "TMPDIR": NSTemporaryDirectory(),
            "SHELL": "/bin/zsh", "PYTHONIOENCODING": "utf-8", "PYTHONUNBUFFERED": "1",
            "TYPEFLUX_QUERY": input.query,
            "TYPEFLUX_KEYWORD": request.keyword.keyword,
            "TYPEFLUX_LANGUAGE": request.interfaceLanguage.rawValue,
            "TYPEFLUX_WORKFLOW_DIR": workflow.folder.path,
            "TYPEFLUX_DATA_DIR": data.path,
            "TYPEFLUX_CACHE_DIR": cache.path,
            "TYPEFLUX_RUN_ID": UUID().uuidString
        ]
        if let selection = input.selection { environment["TYPEFLUX_SELECTION"] = selection }
        if let app { environment["TYPEFLUX_SOURCE_APP"] = app }
        if let bundleID { environment["TYPEFLUX_SOURCE_BUNDLE_ID"] = bundleID }
        for (name, value) in request.options where name != Self.titleOption {
            environment["TYPEFLUX_OPTION_" + Self.variableName(name)] = value
        }
        for (name, value) in manifest.env ?? [:] where Self.isAllowedVariable(name) { environment[name] = value }
        return environment
    }

    /// `TYPEFLUX_OPTION_` suffixes: upper case letters, digits and underscores.
    static func variableName(_ name: String) -> String {
        String(name.uppercased().map { $0.isLetter || $0.isNumber ? $0 : "_" })
    }

    /// The manifest may add variables, but not replace the ones Typeflux sets or the
    /// ones that change how programs load code.
    static func isAllowedVariable(_ name: String) -> Bool {
        let reserved = ["PATH", "HOME", "USER", "LOGNAME", "SHELL", "TMPDIR"]
        return !name.isEmpty && !name.hasPrefix("TYPEFLUX_") && !name.hasPrefix("DYLD_") && !reserved.contains(name)
            && name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    /// One JSON line on stdin with everything about the request.
    static func stdin(request: AskPluginRequest, input: Input, source: (app: String?, bundleID: String?)) -> Data {
        var object: [String: Any] = [
            "typeflux": 1, "query": input.query, "keyword": request.keyword.keyword,
            "options": request.options.filter { $0.key != titleOption },
            "language": request.interfaceLanguage.rawValue, "reason": "submit"
        ]
        object["selection"] = input.selection ?? NSNull()
        object["source"] = ["app": source.app ?? NSNull(), "bundleID": source.bundleID ?? NSNull()] as [String: Any]
        var data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        data.append(0x0A)
        return data
    }

    func nextOptions(after plan: AskPluginPlan, request: AskPluginRequest, step: Int) -> [String: String]? { nil }
}
