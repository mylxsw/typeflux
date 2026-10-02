import Foundation

/// A packaged instruction set the model can load on demand. Only the name and
/// description sit in the tool definition; the body is loaded when needed.
struct AskSkill: Equatable, Sendable {
    var name: String
    var description: String
    var body: String
    /// The folder holding a user skill's SKILL.md and any helper files.
    var directory: URL?
}

/// Built-in skills plus user skills in `Skills/<name>/SKILL.md` under Application
/// Support. A user skill replaces a built-in skill with the same name.
struct AskSkillLibrary: Sendable {
    static let maximumSkills = 50
    static let maximumBodyCharacters = 20000
    static let maximumDescriptionCharacters = 300

    var userDirectory: URL
    var builtins: [AskSkill] = AskBuiltinSkills.all

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Typeflux/Skills", isDirectory: true)
    }

    init(userDirectory: URL = AskSkillLibrary.defaultDirectory) {
        self.userDirectory = userDirectory
    }

    func skills() -> [AskSkill] {
        var byName: [String: AskSkill] = [:]
        for skill in builtins { byName[skill.name] = skill }
        let folders = (try? FileManager.default.contentsOfDirectory(at: userDirectory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        for folder in folders.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let file = folder.appendingPathComponent("SKILL.md")
            guard let text = try? String(contentsOf: file, encoding: .utf8),
                  var skill = Self.parse(text, fallbackName: folder.lastPathComponent) else { continue }
            skill.directory = folder
            byName[skill.name] = skill
        }
        return byName.values.sorted { $0.name < $1.name }.prefix(Self.maximumSkills).map { $0 }
    }

    /// Reads optional `name:` / `description:` front matter between `---` lines.
    static func parse(_ text: String, fallbackName: String) -> AskSkill? {
        var name = fallbackName
        var description = ""
        var body = text
        let lines = text.components(separatedBy: "\n")
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---",
           let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) {
            for line in lines[1 ..< end] {
                let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard parts.count == 2 else { continue }
                let value = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                if parts[0] == "name" { name = value }
                if parts[0] == "description" { description = value }
            }
            body = lines[(end + 1)...].joined(separator: "\n")
        }
        let slug = String(name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" })
            .split(separator: "-").joined(separator: "-")
        body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !slug.isEmpty, slug.count <= 64, slug.allSatisfy({ $0.isASCII }), !body.isEmpty else { return nil }
        if description.isEmpty {
            description = body.components(separatedBy: "\n").first { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.hasPrefix("#") } ?? slug
        }
        return AskSkill(name: slug, description: String(description.prefix(maximumDescriptionCharacters)),
                        body: String(body.prefix(maximumBodyCharacters)))
    }

    func definition(_ skills: [AskSkill]) -> AskToolDefinition? {
        guard !skills.isEmpty else { return nil }
        let index = skills.map { "- \($0.name): \($0.description)" }.joined(separator: "\n")
        let schema: [String: Any] = [
            "type": "object", "required": ["name"], "additionalProperties": false,
            "properties": ["name": ["type": "string", "enum": skills.map(\.name)]]
        ]
        let description = """
        Load the full instructions of a skill before doing a task it covers, then follow them. Skills:
        \(index)
        """
        return AskToolDefinition(name: "skill", description: description,
                                 parameters: JSONValue(data: try! JSONSerialization.data(withJSONObject: schema, options: .sortedKeys)))
    }

    func load(_ name: String) throws -> String {
        guard let skill = skills().first(where: { $0.name == name }) else { throw AskLocalError.message(L("ask.skills.missing")) }
        var text = "# Skill: \(skill.name)\n\n\(skill.body)"
        if let directory = skill.directory {
            let files = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
                .filter { $0 != "SKILL.md" && !$0.hasPrefix(".") }.sorted()
            if !files.isEmpty {
                text += "\n\nSkill files in \(directory.path) (readable by run_code):\n" + files.map { "- " + $0 }.joined(separator: "\n")
            }
        }
        return text
    }
}

extension AskSkill {
    /// Built-in skills describe themselves in the interface language; the model keeps the English text.
    var displayDescription: String {
        guard directory == nil, AskBuiltinSkills.all.contains(where: { $0.name == name }) else { return description }
        let key = "ask.skill." + name + ".description"
        let localized = L(key)
        return localized == key ? description : localized
    }
}

enum AskBuiltinSkills {
    static let all: [AskSkill] = [
        AskSkill(name: "email-reply", description: "Draft a clear, polite email reply that matches the thread's tone and language.", body: """
        1. Identify the sender's request, deadline and any open questions in the thread.
        2. Reply in the language of the email, matching its formality.
        3. Structure: a one-line acknowledgement, the answer or decision, next steps with owners and dates, a short closing.
        4. Keep it under 150 words unless the user asks for more; never invent facts, commitments or attachments.
        5. Offer the draft for review. Do not send anything; sending needs the user's explicit action.
        """),
        AskSkill(name: "meeting-notes", description: "Turn a transcript or rough notes into a summary with decisions and action items.", body: """
        Produce, in the notes' language:
        - **Summary**: three to five sentences.
        - **Decisions**: bullet list, each with the reason if stated.
        - **Action items**: owner — task — due date (write "unassigned" or "no date" when missing; never guess).
        - **Open questions**: anything unresolved.
        Keep names and numbers exactly as written and mark unclear passages as [unclear].
        """),
        AskSkill(name: "translate-polish", description: "Translate or polish text while preserving meaning, terminology and formatting.", body: """
        1. Confirm the target language and audience if they are not obvious.
        2. Preserve meaning, numbers, names, code, links and Markdown structure exactly.
        3. Keep domain terminology consistent; prefer the user's existing terms.
        4. For polishing, fix grammar and flow without changing the author's voice; list substantive changes briefly after the text.
        5. Return only the result unless the user asked for explanations.
        """),
        AskSkill(name: "data-analysis", description: "Analyze tabular data or numbers with run_code and report verified results, optionally with a chart.", body: """
        1. Load the data in run_code (paste small data inline; read files from the authorized folders with the files tool first).
        2. Inspect shape, columns and missing values before computing anything.
        3. Compute with code, never by mental arithmetic, and print the exact figures you report.
        4. For a chart, use matplotlib when available, save a PNG in the working directory and describe what it shows.
        5. Report findings with the numbers, the method and any caveats about data quality.
        """)
    ]
}
