import Foundation

/// Something a workflow's code looks like it does, for the assistant's proposals.
/// See `docs/design/ask-workflow-editor.md` §10.5.
struct AskWorkflowRisk: Hashable, Comparable, Sendable {
    enum Kind: String, CaseIterable, Comparable, Sendable {
        case network, writesFiles, runsPrograms, deletes, sensitive, elevated

        static func < (lhs: Kind, rhs: Kind) -> Bool {
            allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
        }

        /// Deleting, reading secrets and gaining privileges always need the user to look first.
        var isHigh: Bool {
            self == .deletes || self == .sensitive || self == .elevated
        }
    }

    var kind: Kind
    /// The host for network access; the matched code otherwise.
    var detail: String

    var isHigh: Bool {
        kind.isHigh
    }

    static func < (lhs: AskWorkflowRisk, rhs: AskWorkflowRisk) -> Bool {
        (lhs.kind, lhs.detail) < (rhs.kind, rhs.detail)
    }

    var title: String {
        switch kind {
        case .network: L(detail.isEmpty ? "ask.workflow.risk.networkUnknown" : "ask.workflow.risk.network", detail)
        case .writesFiles: L("ask.workflow.risk.writes")
        case .runsPrograms: L("ask.workflow.risk.programs", detail)
        case .deletes: L("ask.workflow.risk.deletes", detail)
        case .sensitive: L("ask.workflow.risk.sensitive", detail)
        case .elevated: L("ask.workflow.risk.elevated", detail)
        }
    }
}

/// A rule-based look at a workflow's files before the assistant's code runs. It is
/// a prompt to look, not a security boundary: code can always hide what it does. The
/// boundary is the user's confirmation before anything is saved and trusted.
enum AskWorkflowRiskScanner {
    private static func rx(_ pattern: String) -> NSRegularExpression {
        // Constant patterns; the tests compile every one.
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    private static let url = rx(#"https?://([A-Za-z0-9.-]+\.[A-Za-z]{2,}|localhost|\d{1,3}(?:\.\d{1,3}){3})"#)
    /// One pattern matching any of `alternatives`.
    private static func any(_ alternatives: [String]) -> NSRegularExpression {
        rx(alternatives.joined(separator: "|"))
    }

    private static let networkAPI = any([
        #"\b(?:urlopen|requests\.(?:get|post|put|delete|request)|httpx\.|fetch\s*\(|https?\.request|axios)"#,
        #"\b(?:curl\s|wget\s|URLSession|socket\.(?:socket|create_connection)|aiohttp)"#
    ])
    private static let rules: [(Kind, NSRegularExpression)] = [
        (.elevated, any([
            #"\bsudo\b"#, #"with administrator privileges"#,
            #"(?:curl|wget)\b[^\n|]*\|\s*(?:ba|z)?sh\b"#, #"base64\s+(?:-d|--decode)[^\n|]*\|\s*(?:ba|z)?sh\b"#
        ])),
        (.sensitive, any([
            #"~/\.ssh"#, #"\.ssh/"#, #"\bid_rsa\b"#, #"~/\.aws"#, #"\.aws/credentials"#, #"\.gnupg"#, #"\.netrc"#,
            #"Keychains"#, #"login\.keychain"#, #"security\s+(?:find|dump|export)-"#, #"Cookies(?:\.binarycookies)?\b"#,
            #"Application Support/Google/Chrome"#
        ])),
        (.deletes, any([
            #"\brm\s+-?[A-Za-z]*\s*[^\s]"#, #"\brmdir\b"#, #"os\.(?:remove|unlink|rmdir)\b"#, #"shutil\.rmtree"#,
            #"\bunlink(?:Sync)?\s*\("#, #"fs\.(?:rm|rmSync|rmdir)\b"#, #"Deno\.remove"#, #"trashItem"#, #"removeItem"#
        ])),
        (.runsPrograms, any([
            #"\bsubprocess\."#, #"os\.system"#, #"os\.popen"#, #"os\.exec"#, #"child_process"#, #"execSync"#,
            #"execFile"#, #"\bspawn(?:Sync)?\s*\("#, #"Bun\.spawn"#, #"Deno\.Command"#, #"do shell script"#,
            #"\beval\s"#, #"\b(?:ba|z)?sh\s+-c\b"#, #"\bxargs\b"#, #"\bopen\s+-a\b"#
        ])),
        (.writesFiles, any([
            #"open\([^)\n]*,\s*['"][wax]b?\+?['"]"#, #"\.write_(?:text|bytes)\("#, #"writeFile(?:Sync)?"#,
            #"fs\.(?:write|append)"#, #"Deno\.writeTextFile"#, #"Bun\.write"#,
            #"(?<![0-9&])>>?\s*(?!&|/dev/null)[\w"'$~./]"#
        ]))
    ]
    private typealias Kind = AskWorkflowRisk.Kind

    /// Every risk in the given files (path → contents). Comment lines are skipped, so
    /// a URL in a comment is not a network access.
    static func scan(_ files: [String: String]) -> Set<AskWorkflowRisk> {
        var risks = Set<AskWorkflowRisk>()
        for (path, text) in files where path != AskWorkflowManifest.fileName && !path.lowercased().hasSuffix(".md") {
            let code = text.split(separator: "\n", omittingEmptySubsequences: false).filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("#!") {
                    return false
                }
                return !(trimmed.hasPrefix("#") || trimmed.hasPrefix("//") || trimmed.hasPrefix("--")
                    || trimmed.hasPrefix("*") || trimmed.hasPrefix("/*"))
            }.joined(separator: "\n")
            let range = NSRange(code.startIndex..., in: code)
            var hosts = Set<String>()
            for match in url.matches(in: code, range: range) {
                if let host = Range(match.range(at: 1), in: code) {
                    hosts.insert(code[host].lowercased())
                }
            }
            for host in hosts {
                risks.insert(AskWorkflowRisk(kind: .network, detail: host))
            }
            if hosts.isEmpty, networkAPI.firstMatch(in: code, range: range) != nil {
                risks.insert(AskWorkflowRisk(kind: .network, detail: ""))
            }
            for (kind, pattern) in rules {
                for match in pattern.matches(in: code, range: range) {
                    guard let found = Range(match.range, in: code) else { continue }
                    let detail = kind == .writesFiles ? "" :
                        String(code[found].trimmingCharacters(in: .whitespaces).prefix(40))
                    risks.insert(AskWorkflowRisk(kind: kind, detail: detail))
                }
            }
        }
        return risks
    }

    /// What `current` does that `baseline` did not. Risks of the same kind and detail
    /// count as the same; any new host is new.
    static func newRisks(_ current: Set<AskWorkflowRisk>,
                         since baseline: Set<AskWorkflowRisk>) -> Set<AskWorkflowRisk> {
        current.subtracting(baseline)
    }

    /// The assistant may run code without asking: nothing high on a first version,
    /// nothing new against the version the user last approved after that.
    static func needsApproval(_ current: Set<AskWorkflowRisk>, baseline: Set<AskWorkflowRisk>?) -> Bool {
        guard let baseline else { return current.contains { $0.isHigh } }
        return !newRisks(current, since: baseline).isEmpty
    }
}
