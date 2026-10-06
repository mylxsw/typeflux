import Foundation

/// Finds where a script failed in what it wrote to stderr: Python tracebacks, Node
/// and Bun stacks, shell errors and osascript errors. Only files of the workflow
/// count, so a library's stack never marks the user's code.
enum AskWorkflowStderrLocator {
    struct Location: Equatable, Sendable {
        /// Relative to the workflow folder.
        var path: String
        var line: Int
        /// The last non-empty line of stderr, shown next to the marked line.
        var message: String
    }

    // Python: File "/…/main.py", line 12
    // Node / Bun / Deno: /…/main.js:12:5 or (file:///…/main.ts:12:5)
    // zsh: /…/main.sh:12: …   bash: /…/main.sh: line 12: …
    // osascript: /…/main.applescript:120:135: execution error
    private static let patterns: [NSRegularExpression] = [
        #"File "([^"]+)", line (\d+)"#,
        #"(?:file://)?((?:/|\./)?[^\s():"']+\.(?:js|mjs|cjs|ts|mts)):(\d+)(?::\d+)?"#,
        #"((?:/|\./)?[^\s:"']+\.(?:sh|zsh|bash)): line (\d+):"#,
        #"((?:/|\./)?[^\s:"']+\.(?:sh|zsh|bash)):(\d+):"#,
        #"((?:/|\./)?[^\s:"']+\.(?:applescript|scpt|js)):(\d+):\d+:"#
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    /// The last location in `stderr` inside `folder` whose file is one of `files`.
    static func locate(_ stderr: String, folder: URL, files: Set<String>) -> Location? {
        // Temporary folders appear both as /var/… and /private/var/…; compare without the prefix.
        let root = unprivate(folder.path) + "/"
        let range = NSRange(stderr.startIndex..., in: stderr)
        var best: Location?
        var bestOffset = -1
        for pattern in patterns {
            for match in pattern.matches(in: stderr, range: range) {
                guard let pathRange = Range(match.range(at: 1), in: stderr),
                      let lineRange = Range(match.range(at: 2), in: stderr),
                      let line = Int(stderr[lineRange]), line > 0 else { continue }
                var path = unprivate(String(stderr[pathRange]))
                if path.hasPrefix(root) {
                    path.removeFirst(root.count)
                }
                if path.hasPrefix("./") {
                    path.removeFirst(2)
                }
                guard files.contains(path) else { continue }
                if match.range.location >= bestOffset {
                    best = Location(path: path, line: line, message: "")
                    bestOffset = match.range.location
                }
            }
        }
        guard var best else { return nil }
        let message = stderr.split(separator: "\n").last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
        best.message = String(withoutLocation(message).prefix(200))
        return best
    }

    /// "/…/main.sh:4: command not found: x" → "command not found: x": the marked line
    /// already says where.
    static func withoutLocation(_ message: String) -> String {
        let range = NSRange(message.startIndex..., in: message)
        for pattern in patterns {
            guard let match = pattern.firstMatch(in: message, range: range), match.range.location == 0,
                  let end = Range(match.range, in: message)?.upperBound else { continue }
            let rest = message[end...].drop { $0 == ":" || $0 == " " }
            if !rest.isEmpty {
                return String(rest)
            }
        }
        return message
    }

    private static func unprivate(_ path: String) -> String {
        for prefix in ["/private/var/", "/private/tmp/", "/private/etc/"] where path.hasPrefix(prefix) {
            return String(path.dropFirst("/private".count))
        }
        return path
    }
}
