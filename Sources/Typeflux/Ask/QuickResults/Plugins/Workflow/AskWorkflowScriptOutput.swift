import Foundation

/// What a script printed when it adds actions of its own:
/// `{"text": "100 USD = 14,912.30 JPY", "actions": [{"action": "open", "target": "https://…"}]}`.
/// The launcher shows `text` and runs the actions after the configured ones, but only
/// when the manifest's `scriptActions` is on. See
/// `docs/design/workflow-gallery-output-actions.md` §3.6.
struct AskWorkflowScriptOutput: Equatable, Sendable {
    /// What to show, as if the script had printed only this.
    var text: String
    /// At most `Output.maximumActions`; the rest are dropped. Unknown actions stay,
    /// so the run can say they are not supported.
    var actions: [AskWorkflowAction]

    /// The envelope in `stdout`, or nil when it is not a JSON object with an
    /// `actions` array and nothing but `text` beside it. Other JSON (a list's
    /// `{"items": …}`, a formatted document that has an `actions` key) shows as it is.
    static func parse(_ stdout: String) -> AskWorkflowScriptOutput? {
        let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), trimmed.contains("\"actions\""), let data = trimmed.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              Set(object.keys).isSubset(of: ["text", "actions"]), let raw = object["actions"] as? [Any],
              object["text"] == nil || object["text"] is String else { return nil }
        let actions = raw.compactMap { ($0 as? [String: Any]).flatMap(action) }
        return AskWorkflowScriptOutput(text: (object["text"] as? String) ?? "",
                                       actions: Array(actions.prefix(AskWorkflowManifest.Output.maximumActions)))
    }

    /// One action as the script wrote it; nil without an `action` name. Fields that
    /// are not text (a number for `value`) are read as text.
    private static func action(_ object: [String: Any]) -> AskWorkflowAction? {
        guard let name = object["action"] as? String, !name.isEmpty else { return nil }
        var action = AskWorkflowAction(action: name)
        for field in AskWorkflowAction.Field.allCases {
            switch object[field.rawValue] {
            case let text as String: action[field] = text
            case let number as NSNumber: action[field] = number.stringValue
            default: break
            }
        }
        return action
    }

    /// The web hosts a workflow already names, in `workflow.json`'s actions or its
    /// code (files or `command.inline`): opening one of those needs no question. Read with the risk scanner, so
    /// what counts as "named" is what the trust panel showed.
    static func knownHosts(in folder: URL, fileManager: FileManager = .default) -> Set<String> {
        var files: [String: String] = [:]
        for path in AskWorkflowStderrLocator.files(in: folder, fileManager: fileManager)
            .union([AskWorkflowManifest.fileName]) {
            let url = folder.appendingPathComponent(path)
            guard let size = (try? fileManager.attributesOfItem(atPath: url.path))?[.size] as? Int,
                  size <= maximumScannedFile,
                  let data = fileManager.contents(atPath: url.path),
                  let text = String(data: data, encoding: .utf8) else { continue }
            files[path] = text
        }
        // An inline script is code too; scanned as a file of its own.
        if let text = files[AskWorkflowManifest.fileName],
           let manifest = try? JSONDecoder().decode(AskWorkflowManifest.self, from: Data(text.utf8)),
           let inline = manifest.command.inline {
            files["inline"] = inline
        }
        return Set(AskWorkflowRiskScanner.scan(files).filter { $0.kind == .network && !$0.detail.isEmpty }
            .map(\.detail))
    }

    /// Larger files are data, not code that names a host.
    static let maximumScannedFile = 512 * 1024

    /// The lower-cased host of a web link, the unit approvals are remembered by.
    static func host(of url: URL) -> String? {
        guard let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        return host
    }
}
