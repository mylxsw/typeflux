import Foundation

/// The languages a workflow can be written in, and how each one is started.
/// Typeflux ships none of them: it finds the user's own on the PATH.
enum AskWorkflowRuntime: String, Codable, CaseIterable, Sendable {
    case python3, node, typescript, zsh, bash, osascript, exec

    var title: String {
        switch self {
        case .python3: "Python"
        case .node: "Node"
        case .typescript: "TypeScript"
        case .zsh: "zsh"
        case .bash: "bash"
        case .osascript: "AppleScript"
        case .exec: L("ask.workflow.runtime.exec")
        }
    }

    /// Shell scripts may live in the manifest itself.
    var allowsInline: Bool { self == .zsh || self == .bash }

    /// The program that runs a script and what it is called when missing.
    var interpreterName: String? {
        switch self {
        case .python3: "python3"
        case .node: "node"
        case .typescript: "bun"
        case .zsh: "zsh"
        case .bash: "bash"
        case .osascript: "osascript"
        case .exec: nil
        }
    }

    /// A process to start: the program and its arguments, none of them parsed by a shell.
    struct Launch: Equatable, Sendable {
        var executable: URL
        var arguments: [String]
    }

    enum LaunchError: Error, Equatable {
        /// No interpreter on the PATH; carries what to install.
        case missing(String)
    }

    /// How to start `script` (or an inline shell script) with `arguments`.
    /// `resolve` finds a program by name on the PATH.
    func launch(script: URL?, inline: String?, arguments: [String], interpreter: String?, name: String,
                resolve: (String) -> URL?) throws -> Launch {
        if let interpreter, !interpreter.isEmpty, self != .exec {
            guard let program = resolve(interpreter) else { throw LaunchError.missing(interpreter) }
            return Launch(executable: program, arguments: scriptArguments(script, inline: inline, name: name) + arguments)
        }
        switch self {
        case .exec:
            guard let script else { throw LaunchError.missing(name) }
            return Launch(executable: script, arguments: arguments)
        case .typescript:
            // Bun and Deno run TypeScript directly; tsx through npx is the fallback.
            let path = script?.path ?? ""
            if let bun = resolve("bun") { return Launch(executable: bun, arguments: [path] + arguments) }
            if let deno = resolve("deno") { return Launch(executable: deno, arguments: ["run", "-A", path] + arguments) }
            if let npx = resolve("npx") { return Launch(executable: npx, arguments: ["--yes", "tsx", path] + arguments) }
            throw LaunchError.missing("bun")
        case .osascript:
            let program = resolve("osascript") ?? URL(fileURLWithPath: "/usr/bin/osascript")
            let path = script?.path ?? ""
            let language = path.hasSuffix(".js") ? ["-l", "JavaScript"] : []
            return Launch(executable: program, arguments: language + [path] + arguments)
        case .python3, .node, .zsh, .bash:
            let name = interpreterName ?? rawValue
            guard let program = resolve(name) else { throw LaunchError.missing(name) }
            return Launch(executable: program, arguments: scriptArguments(script, inline: inline, name: name) + arguments)
        }
    }

    /// The script's path, or `-c <inline> <name>` so the inline script reads its arguments as `$1`, `$2`…
    private func scriptArguments(_ script: URL?, inline: String?, name: String) -> [String] {
        if let inline, allowsInline { return ["-c", inline, name] }
        return [script?.path ?? ""]
    }
}

/// Where programs are found. Apps opened from Finder get only the system PATH, so
/// the login shell's is read once and the usual install directories are added.
enum AskWorkflowPath {
    private actor Cache {
        private var value: String?
        private var pending: Task<String, Never>?

        func get(_ make: @escaping @Sendable () async -> String) async -> String {
            if let value { return value }
            if let pending { return await pending.value }
            let task = Task { await make() }
            pending = task
            let made = await task.value
            value = made
            pending = nil
            return made
        }
    }

    private static let cache = Cache()

    static func extraDirectories(home: String = NSHomeDirectory()) -> [String] {
        StdioMCPClient.commonExecutableDirectories(home: home)
            + [home + "/.deno/bin", home + "/.pyenv/shims", home + "/.nvm/current/bin", "/opt/homebrew/sbin"]
    }

    /// The login shell's PATH (read once), then the common directories it lacks.
    static func searchPath(home: String = NSHomeDirectory()) async -> String {
        await cache.get { combine(await loginShellPath() ?? "", home: home) }
    }

    static func combine(_ path: String, home: String = NSHomeDirectory()) -> String {
        var directories = path.split(separator: ":").map(String.init).filter { !$0.isEmpty }
        for directory in extraDirectories(home: home) where !directories.contains(directory) {
            directories.append(directory)
        }
        return directories.joined(separator: ":")
    }

    /// Runs the user's shell as a login shell to print its PATH. Nil after two
    /// seconds or on failure. It goes through the workflow runner, so a profile that
    /// leaves something running (holding the output open) cannot hold it up.
    static func loginShellPath(shell: String = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh",
                               runner: any AskWorkflowRunning = AskWorkflowRunner()) async -> String? {
        let invocation = AskWorkflowInvocation(
            launch: .init(executable: URL(fileURLWithPath: shell), arguments: ["-l", "-c", "printf %s \"$PATH\""]),
            environment: ["HOME": NSHomeDirectory(), "USER": NSUserName(), "TERM": "dumb"],
            directory: URL(fileURLWithPath: NSHomeDirectory()), stdin: Data(), timeout: 2, stdoutLimit: 64 * 1024
        )
        var result: AskWorkflowRunResult?
        do {
            for try await event in runner.run(invocation) {
                if case let .finished(finished) = event { result = finished }
            }
        } catch {
            return nil
        }
        guard let result, result.exitCode == 0, !result.timedOut else { return nil }
        let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    static func resolve(_ name: String, searchPath: String) -> URL? {
        StdioMCPClient.resolveExecutable(name, searchPath: searchPath)
    }
}
