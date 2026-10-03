import Foundation

/// A packaged instruction set the model can load on demand. Only the name and
/// description sit in the tool definition; the body is loaded when needed.
struct AskSkill: Equatable, Sendable {
    var name: String
    var description: String
    var body: String
    /// The folder holding a user skill's SKILL.md and any helper files.
    var directory: URL?
    /// Informational declarations only; never consumed by the execution authorization layer.
    var declaredPermissions: [String] = []
    var version: String?
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
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: userDirectory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        )) ?? []
        for folder in folders.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let file = folder.appendingPathComponent("SKILL.md")
            guard (try? folder.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
                  (try? file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
                  let text = try? String(contentsOf: file, encoding: .utf8),
                  var skill = Self.parse(text, fallbackName: folder.lastPathComponent) else { continue }
            skill.directory = folder
            byName[skill.name] = skill
        }
        return byName.values.sorted { $0.name < $1.name }.prefix(Self.maximumSkills).map { $0 }
    }

    /// Invalid or unsupported frontmatter is excluded from the library.
    static func parse(_ text: String, fallbackName: String) -> AskSkill? {
        try? AskSkillParser.parse(text, fallbackName: fallbackName)
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
        guard let data = try? JSONSerialization.data(withJSONObject: schema, options: .sortedKeys) else { return nil }
        return AskToolDefinition(name: "skill", description: description, parameters: JSONValue(data: data))
    }

    func load(_ name: String) throws -> String {
        guard let skill = skills().first(where: { $0.name == name }) else {
            throw AskLocalError.message(L("ask.skills.missing"))
        }
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
