import Foundation

/// A workflow's `workflow.json`: the keywords that start it, what it takes, how
/// it runs and what it prints. See `docs/design/ask-launcher-workflows.md` §2.
struct AskWorkflowManifest: Codable, Equatable, Sendable {
    struct Keyword: Codable, Equatable, Sendable {
        var keyword: String
        var title: String?
        var options: [String: String]?
    }

    struct Input: Codable, Equatable, Sendable {
        enum Argument: String, Codable, Sendable { case required, optional, none }
        enum Selection: String, Codable, Sendable { case ifEmpty, never, always }

        var argument: Argument = .optional
        var selection: Selection = .ifEmpty

        init(argument: Argument = .optional, selection: Selection = .ifEmpty) {
            self.argument = argument
            self.selection = selection
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            argument = try container.decodeIfPresent(Argument.self, forKey: .argument) ?? .optional
            selection = try container.decodeIfPresent(Selection.self, forKey: .selection) ?? .ifEmpty
        }
    }

    struct Run: Codable, Equatable, Sendable {
        enum Mode: String, Codable, Sendable { case onSubmit, live }

        var mode: Mode = .onSubmit
        var timeoutSeconds: Double?

        init(mode: Mode = .onSubmit, timeoutSeconds: Double? = nil) {
            self.mode = mode
            self.timeoutSeconds = timeoutSeconds
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            mode = try container.decodeIfPresent(Mode.self, forKey: .mode) ?? .onSubmit
            timeoutSeconds = try container.decodeIfPresent(Double.self, forKey: .timeoutSeconds)
        }
    }

    struct Command: Codable, Equatable, Sendable {
        var runtime: AskWorkflowRuntime
        /// The script, relative to the workflow's folder.
        var script: String?
        /// A shell script kept in the manifest itself (zsh and bash only).
        var inline: String?
        /// Each entry becomes one argument; only `{query}`, `{selection}` and `{option:name}` are replaced.
        var args: [String]?
        /// An interpreter of the user's choosing, such as a virtualenv's python.
        var interpreter: String?
    }

    enum Output: String, Codable, Sendable {
        /// Printed text, shown as it arrives.
        case text
        /// Nothing to show: the script does something and the launcher closes.
        case none
        /// `{"items": [...]}` lists; they come with W2.
        case items
        /// Text, until item lists arrive.
        case auto
    }

    var schema: Int
    var id: String
    var name: String
    var description: String?
    /// `sf:<symbol>` for an SF Symbol; anything else falls back to the runtime's.
    var icon: String?
    var version: String?
    var author: String?
    var keywords: [Keyword]
    var input: Input = .init()
    var run: Run = .init()
    var command: Command
    var output: Output = .auto
    var env: [String: String]?

    static let currentSchema = 1
    static let fileName = "workflow.json"
    static let defaultTimeout: Double = 30
    static let maximumTimeout: Double = 300

    init(schema: Int = currentSchema, id: String, name: String, description: String? = nil, icon: String? = nil,
         version: String? = nil, author: String? = nil, keywords: [Keyword], input: Input = .init(),
         run: Run = .init(), command: Command, output: Output = .auto, env: [String: String]? = nil) {
        self.schema = schema
        self.id = id
        self.name = name
        self.description = description
        self.icon = icon
        self.version = version
        self.author = author
        self.keywords = keywords
        self.input = input
        self.run = run
        self.command = command
        self.output = output
        self.env = env
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schema = try container.decodeIfPresent(Int.self, forKey: .schema) ?? Self.currentSchema
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        icon = try container.decodeIfPresent(String.self, forKey: .icon)
        version = try container.decodeIfPresent(String.self, forKey: .version)
        author = try container.decodeIfPresent(String.self, forKey: .author)
        keywords = try container.decodeIfPresent([Keyword].self, forKey: .keywords) ?? []
        input = try container.decodeIfPresent(Input.self, forKey: .input) ?? .init()
        run = try container.decodeIfPresent(Run.self, forKey: .run) ?? .init()
        command = try container.decode(Command.self, forKey: .command)
        output = try container.decodeIfPresent(Output.self, forKey: .output) ?? .auto
        env = try container.decodeIfPresent([String: String].self, forKey: .env)
    }

    /// The timeout a run gets: the manifest's, kept between one second and five minutes.
    var timeout: Double { min(Self.maximumTimeout, max(1, run.timeoutSeconds ?? Self.defaultTimeout)) }

    /// The argument template, `["{query}"]` unless the manifest says otherwise.
    var argumentTemplate: [String] { command.args ?? ["{query}"] }

    /// Replaces the placeholders in each argument in one pass, so text that came
    /// in (a query containing `{selection}`) is never expanded again. Every entry
    /// stays one argument, whatever it contains: nothing here reaches a shell as text.
    static func arguments(_ template: [String], query: String, selection: String?,
                          options: [String: String]) -> [String] {
        template.map { entry in
            var result = ""
            var rest = Substring(entry)
            while let open = rest.firstIndex(of: "{") {
                result += rest[..<open]
                guard let close = rest[open...].firstIndex(of: "}") else { break }
                let name = rest[rest.index(after: open) ..< close]
                switch name {
                case "query": result += query
                case "selection": result += selection ?? ""
                case _ where name.hasPrefix("option:"): result += options[String(name.dropFirst(7))] ?? ""
                default: result += rest[open ... close]
                }
                rest = rest[rest.index(after: close)...]
            }
            return result + rest
        }
    }

    // MARK: - Validation

    /// What is wrong with a manifest, naming the field so settings can point at it.
    struct Problem: Equatable, Sendable {
        var field: String
        var message: String
    }

    /// Problems that stop the workflow from running, in the order of its fields.
    func problems(in folder: URL, fileManager: FileManager = .default) -> [Problem] {
        var problems: [Problem] = []
        if schema != Self.currentSchema {
            problems.append(Problem(field: "schema", message: L("ask.workflow.problem.schema", schema)))
        }
        if !Self.isValidID(id) { problems.append(Problem(field: "id", message: L("ask.workflow.problem.id"))) }
        if name.trimmingCharacters(in: .whitespaces).isEmpty {
            problems.append(Problem(field: "name", message: L("ask.workflow.problem.name")))
        }
        if keywords.isEmpty { problems.append(Problem(field: "keywords", message: L("ask.workflow.problem.noKeywords"))) }
        for (index, keyword) in keywords.enumerated() {
            if let problem = AskKeywordMatcher.problem(with: keyword.keyword, among: Array(keywords.prefix(index)).map {
                AskKeyword(keyword: $0.keyword, pluginID: "")
            }) {
                problems.append(Problem(field: "keywords[\(index)]",
                                        message: keyword.keyword + ": " + AskKeywordList.message(for: problem)))
            }
        }
        if output == .items { problems.append(Problem(field: "output", message: L("ask.workflow.problem.items"))) }
        if run.mode == .live { problems.append(Problem(field: "run.mode", message: L("ask.workflow.problem.live"))) }
        problems += commandProblems(in: folder, fileManager: fileManager)
        return problems
    }

    private func commandProblems(in folder: URL, fileManager: FileManager) -> [Problem] {
        switch (command.script, command.inline) {
        case (nil, nil):
            return [Problem(field: "command.script", message: L("ask.workflow.problem.noScript"))]
        case (.some, .some):
            return [Problem(field: "command.inline", message: L("ask.workflow.problem.scriptAndInline"))]
        case (nil, .some):
            return command.runtime.allowsInline ? []
                : [Problem(field: "command.inline", message: L("ask.workflow.problem.inlineRuntime"))]
        case let (.some(script), nil):
            guard let url = Self.scriptURL(script, in: folder) else {
                return [Problem(field: "command.script", message: L("ask.workflow.problem.scriptOutside"))]
            }
            guard fileManager.fileExists(atPath: url.path) else {
                return [Problem(field: "command.script", message: L("ask.workflow.problem.scriptMissing", script))]
            }
            if command.runtime == .exec, !fileManager.isExecutableFile(atPath: url.path) {
                return [Problem(field: "command.script", message: L("ask.workflow.problem.notExecutable", script))]
            }
            return []
        }
    }

    /// Reverse-DNS style: letters, digits, dots, dashes and underscores.
    static func isValidID(_ id: String) -> Bool {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
        return !id.isEmpty && id.count <= 100 && id.unicodeScalars.allSatisfy { allowed.contains($0) && $0.isASCII }
            && !id.hasPrefix(".")
    }

    /// The script inside the workflow's folder; nil when the path leaves it, by
    /// `..` or through a symbolic link. A script that does not exist yet is returned
    /// as named, so the check can say it is missing.
    static func scriptURL(_ script: String, in folder: URL, fileManager: FileManager = .default) -> URL? {
        let components = script.split(separator: "/")
        guard !script.isEmpty, !script.hasPrefix("/"), !script.hasPrefix("~"), !components.contains("..") else { return nil }
        let url = folder.appendingPathComponent(script)
        guard fileManager.fileExists(atPath: url.path) else { return url }
        let root = folder.resolvingSymlinksInPath().path
        return url.resolvingSymlinksInPath().path.hasPrefix(root + "/") ? url : nil
    }
}
