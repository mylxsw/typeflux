import Foundation

/// The words of an approval: a question the user can answer yes or no, the
/// model's one-line reason, and at most a few facts about the effect. Tool
/// names and raw arguments stay behind the card's technical details.
enum AskApprovalCopy {
    struct Fact: Equatable, Hashable {
        var symbol: String
        var text: String
        var warning = false
        /// A file the fact can reveal in Finder.
        var revealPath: String? = nil
    }

    static let maxFacts = 3
    static let reasonLimit = 160

    // MARK: Question

    static func question(_ call: AskToolCall, mcpServer: String? = nil,
                         fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> String {
        let args = arguments(call)
        let action = args["action"] as? String ?? ""
        switch (call.function.name, action) {
        case ("files", "write"), ("project_files", "write"):
            guard let path = path(args) else { break }
            let key = fileExists(expanded(path)) ? "ask.approval.q.overwrite" : "ask.approval.q.create"
            return L(key, filename(path))
        case ("files", "edit"), ("project_files", "edit"):
            guard let path = path(args) else { break }
            return L("ask.approval.q.edit", filename(path))
        case ("run_command", _), ("command_job", "start"):
            return L("ask.approval.q.command")
        case ("run_code", _):
            if let language = args["language"] as? String, !language.isEmpty {
                return L("ask.approval.q.code", language)
            }
            return L("ask.approval.q.codeGeneric")
        case ("computer", "screenshot"):
            return L("ask.approval.q.screen")
        default:
            break
        }
        return L("ask.approval.q.generic", AskTheme.toolTitle(call, mcpServer: mcpServer))
    }

    // MARK: Reason

    /// The model's narration before the call, as one short paragraph.
    static func reason(_ text: String?) -> String? {
        guard let text else { return nil }
        let paragraph = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !paragraph.isEmpty else { return nil }
        return paragraph.count > reasonLimit ? String(paragraph.prefix(reasonLimit)) + "…" : paragraph
    }

    // MARK: Facts

    static func facts(_ call: AskToolCall, risk: AskToolRisk, targetSummary: String? = nil,
                      fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> [Fact] {
        let args = arguments(call)
        let action = args["action"] as? String ?? ""
        var facts: [Fact] = []
        switch (call.function.name, action) {
        case ("files", "write"), ("project_files", "write"):
            if let path = path(args) {
                facts.append(location(path))
                if fileExists(expanded(path)) {
                    facts.append(.init(symbol: "exclamationmark.triangle", text: L("ask.approval.fact.overwrite"), warning: true))
                } else {
                    facts.append(.init(symbol: "plus", text: L("ask.approval.fact.newFile")))
                }
            }
            if let content = args["content"] as? String, !content.isEmpty {
                facts.append(.init(symbol: "text.alignleft", text: L("ask.approval.fact.lines", lineCount(content))))
            }
        case ("files", "edit"), ("project_files", "edit"):
            if let path = path(args) { facts.append(location(path)) }
            let removed = lineCount(args["old_text"] as? String ?? "")
            let added = lineCount(args["new_text"] as? String ?? "")
            facts.append(.init(symbol: "pencil", text: L("ask.approval.fact.change", added, removed)))
        case ("run_command", _), ("command_job", "start"):
            facts.append(.init(symbol: "person", text: L("ask.approval.fact.account")))
        case ("computer", "screenshot"):
            facts.append(.init(symbol: "camera.viewfinder", text: L("ask.approval.fact.screenshot")))
        case ("computer", _), ("browser", _):
            if let target = readableTarget(targetSummary) {
                facts.append(.init(symbol: "macwindow", text: target))
            }
        case ("command_job", _): break
        default:
            if call.function.name != "run_code", let target = readableTarget(targetSummary) {
                facts.append(.init(symbol: "scope", text: target))
            }
        }
        if tone(call, risk: risk) == .destructive {
            facts.append(.init(symbol: "exclamationmark.octagon", text: L("ask.approval.fact.irreversible"), warning: true))
        }
        return Array(facts.prefix(maxFacts))
    }

    // MARK: Tone

    /// The colour the card wears. The permission policy is unchanged: a command
    /// still asks every time. Red is kept for commands that look irreversible, so
    /// a read-only check does not wear the same alarm as `rm -rf`.
    static func tone(_ call: AskToolCall, risk: AskToolRisk) -> AskToolRisk {
        guard risk == .destructive, call.function.name == "run_command" else { return risk }
        let command = arguments(call)["command"] as? String ?? ""
        return looksIrreversible(command) ? .destructive : .write
    }

    private static let irreversiblePattern = try! NSRegularExpression(pattern: [
        #"(^|[\s;&|(`$])(sudo|su|rm|rmdir|unlink|shred|dd|mkfs[.\w]*|diskutil|truncate|srm|kill|killall|pkill"#,
        #"|chmod|chown|chflags|launchctl|osascript|shutdown|reboot|halt|crontab|defaults|security|tccutil|mv|scp|rsync|ssh|curl|wget)(?=$|[\s;&|)])"#,
        #"|git\s+(push|reset|clean|checkout\s+--|rebase|filter-branch)|find\s.*-delete"#,
        #"|\|\s*(ba|z)?sh\b|xargs\s+rm"#,
    ].joined(), options: [.caseInsensitive])

    private static let redirectPattern = try! NSRegularExpression(pattern: #"(?<!<)>{1,2}\s*([^\s;|)]+)"#)
    private static let quotedPattern = try! NSRegularExpression(pattern: #"'[^']*'|"(?:[^"\\]|\\.)*""#)

    /// Whether a shell command plausibly deletes, overwrites, escalates or sends
    /// something. A heuristic for colour only; when in doubt it says yes.
    static func looksIrreversible(_ command: String) -> Bool {
        let raw = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return true }
        // Quoted text is data (an awk program, a message), not shell syntax.
        let trimmed = quotedPattern.stringByReplacingMatches(in: raw, range: NSRange(raw.startIndex..., in: raw),
                                                             withTemplate: "Q")
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        if irreversiblePattern.firstMatch(in: trimmed, range: range) != nil { return true }
        for match in redirectPattern.matches(in: trimmed, range: range) {
            guard let targetRange = Range(match.range(at: 1), in: trimmed) else { return true }
            let target = String(trimmed[targetRange])
            // `2>&1` duplicates a descriptor rather than writing a file.
            if target.hasPrefix("&") { continue }
            let scratch = ["/tmp/", "/private/tmp/", "$TMPDIR", "${TMPDIR"].contains { target.hasPrefix($0) }
            if !scratch, target != "/dev/null" { return true }
        }
        return false
    }

    // MARK: Helpers

    private static func arguments(_ call: AskToolCall) -> [String: Any] {
        (try? AskLocalTools.jsonArguments(call.function.arguments)) ?? [:]
    }

    private static func path(_ args: [String: Any]) -> String? {
        guard let path = args["path"] as? String, !path.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return path
    }

    private static func expanded(_ path: String) -> String { (path as NSString).expandingTildeInPath }

    private static func filename(_ path: String) -> String { (path as NSString).lastPathComponent }

    /// "Downloads / snake.html": the file and the folder it lives in.
    static func location(_ path: String) -> Fact {
        let full = expanded(path)
        let folder = ((full as NSString).deletingLastPathComponent as NSString).lastPathComponent
        let name = filename(path)
        let text = folder.isEmpty || folder == "/" ? name : folder + " / " + name
        return .init(symbol: "folder", text: text, revealPath: full.hasPrefix("/") ? full : nil)
    }

    static func lineCount(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        return text.split(separator: "\n", omittingEmptySubsequences: false).count
            - (text.hasSuffix("\n") ? 1 : 0)
    }

    /// A target summary worth showing: not a bare display id and not a long technical path.
    private static func readableTarget(_ summary: String?) -> String? {
        guard let summary = summary?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty,
              !summary.hasPrefix("display:"), summary.count <= 80 else { return nil }
        return summary
    }
}
