import Foundation

/// Analysis execution is gated off in production until hostile process/session
/// escape is contained. The opt-in path validates file/environment isolation and
/// manages descendants that remain in their original process group.
struct AskCodeSandbox: Sendable {
    enum Language: String, CaseIterable, Sendable {
        case python, javascript, shell

        var fileExtension: String {
            switch self {
            case .python: "py"
            case .javascript: "js"
            case .shell: "sh"
            }
        }
    }

    static let defaultTimeout = 30
    static let maximumTimeout = 120
    static let maximumOutputCharacters = 30000
    static let maximumCodeBytes = 200_000
    static let sandboxExec = "/usr/bin/sandbox-exec"

    var baseDirectory: URL
    var readableDirectories: [URL]
    /// Test/integration opt-in only. Do not connect to a user setting until the
    /// process containment acceptance gate documented in docs is satisfied.
    var allowProcessGroupExecution: Bool

    init(
        baseDirectory: URL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "TypefluxAskSandbox-v2",
            isDirectory: true
        ),
        readableDirectories: [URL] = [],
        home _: String = NSHomeDirectory(),
        environment _: [String: String] = [:],
        allowProcessGroupExecution: Bool = false
    ) {
        self.baseDirectory = baseDirectory
        self.readableDirectories = readableDirectories
        self.allowProcessGroupExecution = allowProcessGroupExecution
    }

    var isSupported: Bool {
        allowProcessGroupExecution && FileManager.default.isExecutableFile(atPath: Self.sandboxExec)
    }

    /// Never derive child environment or executable search from the app's env.
    var launchEnvironment: [String: String] {
        ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8",
         "MPLBACKEND": "Agg", "PYTHONDONTWRITEBYTECODE": "1", "PYTHONNOUSERSITE": "1"]
    }

    /// Only OS/CLT runtimes with a bounded dependency root are supported. Homebrew,
    /// pyenv, nvm and arbitrary PATH runtimes require separate dependency validation.
    func interpreter(for language: Language) -> URL? {
        switch language {
        case .shell: return URL(fileURLWithPath: "/bin/zsh")
        case .javascript: return nil
        case .python:
            let path = Self.realPath("/Library/Developer/CommandLineTools/usr/bin/python3")
            let root = "/Library/Developer/CommandLineTools/Library/Frameworks/Python3.framework/"
            guard path.hasPrefix(root), FileManager.default.isExecutableFile(atPath: path) else { return nil }
            return URL(fileURLWithPath: path)
        }
    }

    var availableLanguages: [Language] {
        guard isSupported else { return [] }
        return Language.allCases.filter { interpreter(for: $0) != nil }
    }

    func definition() -> AskToolDefinition? {
        let languages = availableLanguages.map(\.rawValue)
        guard !languages.isEmpty else { return nil }
        let schema: [String: Any] = [
            "type": "object", "required": ["language", "code"], "additionalProperties": false,
            "properties": [
                "language": ["type": "string", "enum": languages],
                "code": ["type": "string"],
                "timeout_seconds": ["type": "integer", "minimum": 1, "maximum": Self.maximumTimeout]
            ]
        ]
        let description = """
        Run a short program in an isolated workspace for calculations, data processing, file conversion or charts. \
        Available: \(languages.joined(separator: ", ")). The program has no network access and cannot read the user's \
        home folder; files it writes stay in this conversation's workspace and later runs can read them. Save images \
        as PNG or JPEG in the working directory; the first new image is returned. Default time limit \(Self.defaultTimeout) s. \
        Each run needs user approval.
        """
        guard let data = try? JSONSerialization.data(withJSONObject: schema, options: .sortedKeys) else { return nil }
        return AskToolDefinition(name: "run_code", description: description, parameters: JSONValue(data: data))
    }

    func workspace(for conversationId: String) throws -> URL {
        let root = try AskSecureDirectory.openRoot(baseDirectory)
        let sessions = try root.child("sessions", create: true, privateDirectory: true)
        let workspace = try sessions.child(
            AskSecureDirectory.sessionName(conversationId),
            create: true,
            privateDirectory: true
        )
        _ = try workspace.child(".tmp", create: true, privateDirectory: true)
        return try workspace.url
    }

    /// Only used for trusted OS runtime lookup, never for host writes.
    static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Only inactive v2 sessions are pruned; legacy roots are never followed.
    func pruneWorkspaces(olderThan age: TimeInterval = 7 * 24 * 3600, now: Date = Date()) {
        guard let root = try? AskSecureDirectory.openRoot(baseDirectory, create: false),
              let sessions = try? root.child("sessions") else { return }
        for name in sessions.entries() {
            guard let child = try? sessions.child(name), (try? child.lock()) != nil else { continue }
            var info = stat()
            guard fstat(child.descriptor, &info) == 0,
                  now.timeIntervalSince1970 - Double(info.st_mtimespec.tv_sec) > age else { continue }
            try? sessions.remove(name)
        }
    }

    static func quoted(_ path: String) -> String {
        "\"" + path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func profile(workspace: String, home _: String, readable: [String]) -> String {
        let system = ["/bin", "/usr/bin", "/usr/lib", "/System/Library", "/usr/share/locale", "/usr/share/zoneinfo"]
        let roots = system + [workspace] + readable
        // realpath/lstat need metadata on each ancestor, not its contents.
        var ancestors = Set(["/var", "/tmp", "/etc"])
        for root in roots {
            var parent = (root as NSString).deletingLastPathComponent
            while !parent.isEmpty, parent != "/" {
                ancestors.insert(parent)
                parent = (parent as NSString).deletingLastPathComponent
            }
        }
        let metadata = ancestors.sorted().map { "(literal \(quoted($0)))" }.joined(separator: " ")
        let allowed = roots.map { "(subpath \(quoted($0)))" }.joined(separator: " ")
        return """
        (version 1)
        (allow default)
        (deny network*)
        (deny file-read*)
        (allow file-read-metadata \(metadata))
        (allow file-read* \(allowed) (literal "/") (literal "/dev/null") (literal "/dev/urandom") (literal "/dev/random"))
        (deny file-write*)
        (allow file-write* (subpath \(quoted(workspace))) (literal "/dev/null"))
        (deny file-write* (literal \(quoted(workspace))))
        (deny mach-lookup)
        (deny appleevent-send)
        (deny process-info*)
        (allow process-info-pidinfo (target self))
        (deny signal (target others))
        """
    }

    struct Execution: Sendable {
        var exitCode: Int32
        var timedOut: Bool
        var stdout: String
        var stderr: String
        var changedFiles: [(name: String, size: Int)]
        var image: String?
    }

    func run(_ language: Language, code: String, conversationId: String,
             timeout: Int = defaultTimeout) async throws -> Execution {
        guard code.utf8.count <= Self.maximumCodeBytes else { throw AskLocalError.message(L("ask.code.tooLarge")) }
        guard isSupported else {
            throw AskLocalError.message("Code execution is unavailable: " +
                "untrusted process containment has not been validated for this runtime.")
        }
        guard let interpreter = interpreter(for: language)
        else { throw AskLocalError.message(L("ask.code.unavailable")) }
        try Task.checkCancellation()
        let root = try AskSecureDirectory.openRoot(baseDirectory)
        let sessions = try root.child("sessions", create: true, privateDirectory: true)
        let workspace = try sessions.child(
            AskSecureDirectory.sessionName(conversationId),
            create: true,
            privateDirectory: true
        )
        try workspace.lock()
        guard futimes(workspace.descriptor, nil) == 0 else { throw AskSecureDirectory.failure("touch workspace") }
        let temporary = try workspace.child(".tmp", create: true, privateDirectory: true)
        let workspaceURL = try workspace.url
        let scripts = try root.child("scripts", create: true, privateDirectory: true)
        let runID = UUID().uuidString
        let control = try scripts.child(runID, create: true, privateDirectory: true)
        defer { try? scripts.remove(runID) }
        let scriptName = "main." + language.fileExtension
        try control.createFile(scriptName, data: Data(code.utf8))
        let script = try control.url.appendingPathComponent(scriptName)
        let before = workspace.snapshot()
        let readable = try readableRoots(control: control, root: root, language: language, interpreter: interpreter)
        let profile = Self.profile(workspace: workspaceURL.path, home: NSHomeDirectory(), readable: readable)
        var env = launchEnvironment
        env["HOME"] = workspaceURL.path
        env["TMPDIR"] = try temporary.url.path + "/"
        // -f disables shell startup files; -I disables Python environment/user-site
        // injection, including modules in the writable current directory.
        let flags = language == .shell ? ["-f"] : ["-I"]
        let result = try await ManagedProcess().run(.init(executable: Self.sandboxExec,
                                                          arguments: ["-p", profile, interpreter.path] + flags +
                                                              [script.path], environment: env,
                                                          directoryDescriptor: workspace.descriptor,
                                                          timeout: Double(min(
                                                              max(1, timeout),
                                                              Self.maximumTimeout
                                                          )),
                                                          outputLimit: Self.maximumOutputCharacters))
        if result.termination == .cancelled {
            throw CancellationError()
        }
        try Task.checkCancellation()
        let changed = Self.changes(before: before, after: workspace.snapshot())
        return Execution(exitCode: result.exitCode, timedOut: result.termination == .timedOut,
                         stdout: result.stdout, stderr: result.stderr, changedFiles: changed,
                         image: Self.firstImage(changed, workspace: workspace))
    }

    private func readableRoots(control: AskSecureDirectory, root: AskSecureDirectory,
                               language: Language, interpreter: URL) throws -> [String] {
        var readable = try [control.url.path]
        if language == .python {
            // Version directory contains the executable, stdlib and extension libs.
            readable.append(interpreter.deletingLastPathComponent().deletingLastPathComponent().path)
        }
        let rootPath = try root.url.path
        for directory in readableDirectories where FileManager.default.fileExists(atPath: directory.path) {
            let opened = try AskSecureDirectory.openRoot(directory, create: false, privateRoot: false)
            let path = try opened.url.path
            guard !rootPath.hasPrefix(path + "/"), !path.hasPrefix(rootPath + "/"), path != rootPath,
                  path != "/", path != NSHomeDirectory() else {
                throw AskLocalError.message("Code execution refused an overlapping readable directory.")
            }
            readable.append(path)
        }
        return readable
    }

    private static func firstImage(_ changed: [(name: String, size: Int)], workspace: AskSecureDirectory) -> String? {
        for file in changed where ["png", "jpg", "jpeg"].contains((file.name as NSString).pathExtension.lowercased()) {
            if let data = try? workspace.readFile(file.name, limit: 10 * 1024 * 1024),
               let url = AskLocalTools.jpegDataURL(base64: data.base64EncodedString()) {
                return url
            }
        }
        return nil
    }

    static func changes(before: [String: (Date, Int)], after: [String: (Date, Int)]) -> [(name: String, size: Int)] {
        after.filter { name, value in before[name].map { $0.0 != value.0 || $0.1 != value.1 } ?? true }
            .map { (name: $0.key, size: $0.value.1) }
            .sorted { $0.name < $1.name }
    }

    static func report(_ execution: Execution, workspace: String) -> String {
        var lines = [execution.timedOut ? "Timed out; the program was stopped." : "Exit code: \(execution.exitCode)"]
        if !execution.stdout.isEmpty {
            lines += ["--- stdout ---", execution.stdout]
        }
        if !execution.stderr.isEmpty {
            lines += ["--- stderr ---", execution.stderr]
        }
        if execution.stdout.isEmpty, execution.stderr.isEmpty {
            lines.append("(no output)")
        }
        if !execution.changedFiles.isEmpty {
            lines.append("Files written in the workspace \(workspace):")
            lines += execution.changedFiles.prefix(50).map { "- \($0.name) (\($0.size) bytes)" }
        }
        if execution.image != nil {
            lines.append("The first new image is attached.")
        }
        return lines.joined(separator: "\n")
    }
}
