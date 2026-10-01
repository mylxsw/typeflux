import Foundation

/// Runs short programs for Ask under a macOS Seatbelt profile: no network, no
/// reads from the user's home folder, and writes only inside a per-conversation
/// workspace in the temporary directory. Files persist between calls of the
/// same conversation so a program can build on earlier output.
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
    /// Extra folders programs may read, such as the Skills folder.
    var readableDirectories: [URL]
    var home: String
    var environment: [String: String]

    init(baseDirectory: URL = FileManager.default.temporaryDirectory.appendingPathComponent("TypefluxAskSandbox", isDirectory: true),
         readableDirectories: [URL] = [], home: String = NSHomeDirectory(),
         environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.baseDirectory = baseDirectory
        self.readableDirectories = readableDirectories
        self.home = home
        self.environment = environment
    }

    var isSupported: Bool { FileManager.default.isExecutableFile(atPath: Self.sandboxExec) }

    var launchEnvironment: [String: String] {
        StdioMCPClient.launchEnvironment(base: environment, overrides: [:], home: home)
    }

    /// Interpreters found on this Mac. The /usr/bin/python3 stub would open an
    /// installer dialog when the Command Line Tools are missing, so it only counts
    /// when they are installed.
    func interpreter(for language: Language) -> URL? {
        switch language {
        case .shell: return URL(fileURLWithPath: "/bin/zsh")
        case .javascript: return StdioMCPClient.resolveExecutable("node", searchPath: launchEnvironment["PATH"] ?? "")
        case .python:
            guard let url = StdioMCPClient.resolveExecutable("python3", searchPath: launchEnvironment["PATH"] ?? "") else { return nil }
            if url.path == "/usr/bin/python3" {
                let tools = ["/Library/Developer/CommandLineTools/usr/bin/python3", "/Applications/Xcode.app/Contents/Developer/usr/bin/python3"]
                return tools.contains(where: FileManager.default.isExecutableFile(atPath:)) ? url : nil
            }
            return url
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
        return AskToolDefinition(name: "run_code", description: description,
                                 parameters: JSONValue(data: try! JSONSerialization.data(withJSONObject: schema, options: .sortedKeys)))
    }

    func workspace(for conversationId: String) throws -> URL {
        let safe = conversationId.filter { $0.isLetter || $0.isNumber || $0 == "-" }.prefix(64)
        let url = baseDirectory.appendingPathComponent(safe.isEmpty ? "default" : String(safe), isDirectory: true)
        try FileManager.default.createDirectory(at: url.appendingPathComponent(".tmp"), withIntermediateDirectories: true)
        return URL(fileURLWithPath: Self.realPath(url.path), isDirectory: true)
    }

    /// Seatbelt matches real paths (/private/var/...), which URL.resolvingSymlinksInPath strips.
    static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Removes workspaces untouched for `age`, best effort.
    func pruneWorkspaces(olderThan age: TimeInterval = 7 * 24 * 3600, now: Date = Date()) {
        let items = (try? FileManager.default.contentsOfDirectory(at: baseDirectory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for item in items {
            let modified = (try? item.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? now
            if now.timeIntervalSince(modified) > age { try? FileManager.default.removeItem(at: item) }
        }
    }

    static func quoted(_ path: String) -> String {
        "\"" + path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Later rules win, so the workspace and readable folders are re-allowed after the home folder is denied.
    static func profile(workspace: String, home: String, readable: [String]) -> String {
        let allowed = ([workspace] + readable).map { "(subpath \(quoted($0)))" }.joined(separator: " ")
        return """
        (version 1)
        (allow default)
        (deny network*)
        (deny file-write*)
        (allow file-write* (subpath \(quoted(workspace))) (literal "/dev/null") (literal "/dev/tty") (literal "/dev/dtracehelper"))
        (deny file-read* (subpath \(quoted(home))))
        (allow file-read* \(allowed))
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

    func run(_ language: Language, code: String, conversationId: String, timeout: Int = defaultTimeout) async throws -> Execution {
        guard code.utf8.count <= Self.maximumCodeBytes else { throw AskLocalError.message(L("ask.code.tooLarge")) }
        guard isSupported, let interpreter = interpreter(for: language) else { throw AskLocalError.message(L("ask.code.unavailable")) }
        let workspace = try workspace(for: conversationId)
        let scriptDirectory = workspace.appendingPathComponent(".run", isDirectory: true)
        try FileManager.default.createDirectory(at: scriptDirectory, withIntermediateDirectories: true)
        let script = scriptDirectory.appendingPathComponent("main." + language.fileExtension)
        try Data(code.utf8).write(to: script)
        let before = Self.snapshot(workspace)

        // An interpreter installed under the home folder (pyenv, nvm) must stay readable.
        let realHome = Self.realPath(home)
        let interpreterRoot = (Self.realPath(interpreter.path) as NSString).deletingLastPathComponent
        let interpreterPrefix = (interpreterRoot as NSString).deletingLastPathComponent
        var readable = readableDirectories.map { Self.realPath($0.path) }
        if interpreterPrefix.hasPrefix(realHome + "/") { readable.append(interpreterPrefix) }
        let profile = Self.profile(workspace: workspace.path, home: realHome, readable: readable)

        var env = launchEnvironment
        env["HOME"] = workspace.path
        env["TMPDIR"] = workspace.appendingPathComponent(".tmp").path + "/"
        env["MPLBACKEND"] = "Agg"
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        env["LANG"] = "en_US.UTF-8"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.sandboxExec)
        process.arguments = ["-p", profile, interpreter.path, script.path]
        process.currentDirectoryURL = workspace
        process.environment = env
        process.standardInput = FileHandle.nullDevice
        let stdout = AskOutputCollector(limit: Self.maximumOutputCharacters)
        let stderr = AskOutputCollector(limit: Self.maximumOutputCharacters)
        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        outPipe.fileHandleForReading.readabilityHandler = { stdout.append($0.availableData) }
        errPipe.fileHandleForReading.readabilityHandler = { stderr.append($0.availableData) }

        let finished = AsyncStream<Void>.makeStream()
        process.terminationHandler = { _ in finished.continuation.yield(); finished.continuation.finish() }
        try process.run()
        let limit = min(max(1, timeout), Self.maximumTimeout)
        let timedOut = await withTaskCancellationHandler {
            await withTaskGroup(of: Bool.self) { group in
                group.addTask { for await _ in finished.stream {}; return false }
                group.addTask {
                    try? await Task.sleep(for: .seconds(limit))
                    return !Task.isCancelled
                }
                let first = await group.next() ?? false
                group.cancelAll()
                return first
            }
        } onCancel: {
            Self.stop(process)
        }
        if timedOut || Task.isCancelled { Self.stop(process) }
        process.waitUntilExit()
        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil
        stdout.append(outPipe.fileHandleForReading.readDataToEndOfFile())
        stderr.append(errPipe.fileHandleForReading.readDataToEndOfFile())
        try Task.checkCancellation()

        let changed = Self.changes(before: before, after: Self.snapshot(workspace))
        var image: String?
        for file in changed where ["png", "jpg", "jpeg"].contains((file.name as NSString).pathExtension.lowercased()) {
            if let data = try? Data(contentsOf: workspace.appendingPathComponent(file.name)),
               let url = AskLocalTools.jpegDataURL(base64: data.base64EncodedString()) {
                image = url
                break
            }
        }
        return Execution(exitCode: process.terminationStatus, timedOut: timedOut, stdout: stdout.text, stderr: stderr.text,
                         changedFiles: changed, image: image)
    }

    static func stop(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
            if process.isRunning { kill(pid, SIGKILL) }
        }
    }

    static func snapshot(_ directory: URL) -> [String: (Date, Int)] {
        var result: [String: (Date, Int)] = [:]
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return result }
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            guard url.path.hasPrefix(directory.path + "/") else { continue }
            let relative = String(url.path.dropFirst(directory.path.count + 1))
            result[relative] = (values.contentModificationDate ?? .distantPast, values.fileSize ?? 0)
        }
        return result
    }

    static func changes(before: [String: (Date, Int)], after: [String: (Date, Int)]) -> [(name: String, size: Int)] {
        after.filter { name, value in before[name].map { $0.0 != value.0 || $0.1 != value.1 } ?? true }
            .map { (name: $0.key, size: $0.value.1) }
            .sorted { $0.name < $1.name }
    }

    static func report(_ execution: Execution, workspace: String) -> String {
        var lines = [execution.timedOut ? "Timed out; the program was stopped." : "Exit code: \(execution.exitCode)"]
        if !execution.stdout.isEmpty { lines += ["--- stdout ---", execution.stdout] }
        if !execution.stderr.isEmpty { lines += ["--- stderr ---", execution.stderr] }
        if execution.stdout.isEmpty && execution.stderr.isEmpty { lines.append("(no output)") }
        if !execution.changedFiles.isEmpty {
            lines.append("Files written in the workspace \(workspace):")
            lines += execution.changedFiles.prefix(50).map { "- \($0.name) (\($0.size) bytes)" }
        }
        if execution.image != nil { lines.append("The first new image is attached.") }
        return lines.joined(separator: "\n")
    }
}

/// Collects process output up to a limit while still draining the pipe.
final class AskOutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var dropped = 0
    private let limit: Int

    init(limit: Int) { self.limit = limit }

    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        let room = max(0, limit - data.count)
        data.append(chunk.prefix(room))
        dropped += max(0, chunk.count - room)
    }

    var text: String {
        lock.lock(); defer { lock.unlock() }
        let body = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return dropped > 0 ? body + "\n[\(dropped) more bytes omitted]" : body
    }
}
