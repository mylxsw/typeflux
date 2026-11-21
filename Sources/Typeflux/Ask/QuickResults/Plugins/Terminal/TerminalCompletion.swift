import Foundation

/// Local completion at the end of a command line. No shell command is evaluated.
struct TerminalCompletion {
    private struct Query {
        let head: String
        let words: [String]
        let prefix: String
    }

    private struct Cycle {
        let cwd: String
        let path: String
        let head: String
        let candidates: [String]
        var current: String
        var next = 0
    }

    private var cycle: Cycle?
    var candidates: [String] { cycle?.candidates ?? [] }
    var selectedCandidate: String? {
        guard let cycle else { return nil }
        return cycle.candidates.first { cycle.head + Self.escaped($0) == cycle.current }
    }

    mutating func advance(_ text: String, cwd: String, path: String, home: String = NSHomeDirectory()) -> String? {
        if var cycle, cycle.current == text, cycle.cwd == cwd, cycle.path == path {
            let candidate = cycle.head + Self.escaped(cycle.candidates[cycle.next])
            cycle.current = candidate
            cycle.next = (cycle.next + 1) % cycle.candidates.count
            self.cycle = cycle
            return candidate
        }
        cycle = nil
        let query = Self.query(text)
        let candidates = Self.candidates(prefix: query.prefix, words: query.words, cwd: cwd, path: path, home: home)
        guard let common = Self.commonPrefix(candidates) else { return nil }
        let prefix = common.count > query.prefix.count ? common : candidates[0]
        var completed = query.head + Self.escaped(prefix)
        if candidates.count == 1, !prefix.hasSuffix("/") { completed += " " }
        if candidates.count > 1 {
            cycle = Cycle(cwd: cwd, path: path, head: query.head, candidates: candidates, current: completed,
                          next: common.count > query.prefix.count ? 0 : 1)
        }
        return completed
    }

    private static let subcommands: [String: [String]] = [
        "git": ["add", "branch", "checkout", "clone", "commit", "diff", "fetch", "log", "merge", "pull",
                "push", "rebase", "reset", "restore", "stash", "status", "switch", "tag"],
        "swift": ["build", "package", "run", "test"],
        "go": ["build", "clean", "fmt", "get", "install", "mod", "run", "test", "vet"],
        "npm": ["ci", "exec", "init", "install", "run", "start", "test", "uninstall", "update"],
        "brew": ["doctor", "info", "install", "list", "search", "uninstall", "update", "upgrade"],
        "docker": ["build", "compose", "exec", "images", "logs", "ps", "pull", "push", "run", "stop"],
        "kubectl": ["apply", "config", "delete", "describe", "exec", "get", "logs", "rollout"]
    ]

    static func candidates(prefix: String, words: [String], cwd: String, path: String, home: String) -> [String] {
        let manager = FileManager.default
        var matches: Set<String> = []
        if words.isEmpty, !prefix.contains("/") {
            matches.formUnion(["cd", "echo", "export", "pwd"].filter { $0.hasPrefix(prefix) })
            for entry in path.split(separator: ":", omittingEmptySubsequences: false) {
                let directory = resolve(String(entry), cwd: cwd, home: home)
                for name in entries(directory, prefix: prefix, manager: manager) {
                    let item = directory.appendingPathComponent(name)
                    if !isDirectory(item), manager.isExecutableFile(atPath: item.path) { matches.insert(name) }
                }
            }
        } else {
            if words.count == 1, let command = words.first {
                matches.formUnion((subcommands[(command as NSString).lastPathComponent] ?? [])
                    .filter { $0.hasPrefix(prefix) })
            }
            let pathPrefix = prefix.lastIndex(of: "/").map { String(prefix[...$0]) } ?? ""
            let directory = resolve(pathPrefix, cwd: cwd, home: home)
            let stem = String(prefix.dropFirst(pathPrefix.count))
            for name in entries(directory, prefix: stem, manager: manager) {
                let item = directory.appendingPathComponent(name)
                if isDirectory(item) {
                    matches.insert(pathPrefix + name + "/")
                } else if words.first != "cd", !words.isEmpty || manager.isExecutableFile(atPath: item.path) {
                    matches.insert(pathPrefix + name)
                }
            }
        }
        return matches.sorted()
    }

    private static func entries(_ directory: URL, prefix: String, manager: FileManager) -> [String] {
        (try? manager.contentsOfDirectory(atPath: directory.path))?.filter {
            $0.hasPrefix(prefix) && (!$0.hasPrefix(".") || prefix.hasPrefix("."))
                && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        } ?? []
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue
    }

    private static func resolve(_ directory: String, cwd: String, home: String) -> URL {
        if directory.hasPrefix("/") { return URL(fileURLWithPath: directory, isDirectory: true) }
        if directory == "~" || directory.hasPrefix("~/") {
            return URL(fileURLWithPath: home + directory.dropFirst(), isDirectory: true)
        }
        return URL(fileURLWithPath: cwd, isDirectory: true).appendingPathComponent(directory, isDirectory: true)
    }

    static func commonPrefix(_ candidates: [String]) -> String? {
        guard let first = candidates.first else { return nil }
        return candidates.dropFirst().reduce(first) { prefix, candidate in
            String(zip(prefix, candidate).prefix { $0.0 == $0.1 }.map(\.0))
        }
    }

    private static func query(_ text: String) -> Query {
        var words: [String] = []
        var start = text.startIndex
        var token = ""
        var quote: Character?
        var escape = false
        for index in text.indices {
            let character = text[index]
            if escape {
                token.append(character)
                escape = false
            } else if character == "\\" && quote != "'" {
                escape = true
            } else if let active = quote {
                if character == active { quote = nil } else { token.append(character) }
            } else if character == "'" || character == "\"" {
                quote = character
            } else if ";&|()".contains(character) {
                words.removeAll()
                token = ""
                start = text.index(after: index)
            } else if character.isWhitespace {
                if start != index { words.append(token) }
                token = ""
                start = text.index(after: index)
            } else {
                token.append(character)
            }
        }
        return Query(head: String(text[..<start]), words: words, prefix: token)
    }

    private static func escaped(_ value: String) -> String {
        value.enumerated().map { index, character in
            let literalTilde = character == "~" && !(index == 0 && value.hasPrefix("~/"))
            return character.isWhitespace || literalTilde || #"\\"'`$;&|()<>*?[]{}!#^="#.contains(character)
                ? "\\" + String(character) : String(character)
        }.joined()
    }
}
