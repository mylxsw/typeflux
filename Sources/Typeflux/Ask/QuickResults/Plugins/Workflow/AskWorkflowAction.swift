import Foundation

/// One step a workflow takes after a run, as `workflow.json` lists it:
/// `{ "action": "copy", "value": "{output.line1}" }`. The fields hold text with
/// placeholders (`AskWorkflowPlaceholders`). An action this version does not know
/// still decodes, so the editor can show it and validation can say so.
/// See `docs/design/workflow-gallery-output-actions.md` §3.3.
struct AskWorkflowAction: Codable, Equatable, Sendable {
    enum Kind: String, CaseIterable, Sendable {
        case copy, writeBack, notify, hud, open, reveal, speak, askAI, runKeyword

        /// The fields the action takes, in the order the editor shows them.
        var fields: [Field] {
            switch self {
            case .copy, .writeBack: [.value]
            case .notify: [.title, .body]
            case .hud: [.text]
            case .open: [.target]
            case .reveal: [.path]
            case .speak: [.text, .language]
            case .askAI: [.prompt]
            case .runKeyword: [.keyword, .argument]
            }
        }

        /// The field that must not be empty.
        var requiredField: Field {
            switch self {
            case .copy, .writeBack: .value
            case .notify: .body
            case .hud, .speak: .text
            case .open: .target
            case .reveal: .path
            case .askAI: .prompt
            case .runKeyword: .keyword
            }
        }

        var title: String {
            L("ask.workflow.action.kind." + rawValue)
        }

        var symbol: String {
            switch self {
            case .copy: "doc.on.doc"
            case .writeBack: "arrow.down.to.line"
            case .notify: "bell"
            case .hud: "rectangle.bottomthird.inset.filled"
            case .open: "arrow.up.right"
            case .reveal: "folder"
            case .speak: "speaker.wave.2"
            case .askAI: "sparkles"
            case .runKeyword: "arrow.right.to.line"
            }
        }

        /// The groups of the "Add action" menu: common, open, more.
        static let groups: [[Kind]] = [[.copy, .writeBack, .notify, .hud], [.open, .reveal],
                                       [.speak, .askAI, .runKeyword]]

        /// What a new action of this kind starts with.
        var template: AskWorkflowAction {
            var action = AskWorkflowAction(action: rawValue)
            switch self {
            case .copy, .writeBack: action.value = "{output}"
            case .notify: action.title = ""; action.body = "{output}"
            case .hud, .speak: action.text = "{output}"
            case .open: action.target = "https://"
            case .reveal: action.path = "{output}"
            case .askAI: action.prompt = "{output}"
            case .runKeyword: action.keyword = ""; action.argument = "{output}"
            }
            return action
        }
    }

    enum Field: String, CaseIterable, Sendable {
        case value, title, body, text, target, path, language, prompt, keyword, argument

        var title: String {
            L("ask.workflow.action.field." + rawValue)
        }
    }

    var action: String
    var value: String?
    var title: String?
    var body: String?
    var text: String?
    var target: String?
    var path: String?
    var language: String?
    var prompt: String?
    /// `runKeyword`: the launcher keyword to run, and what follows it.
    var keyword: String?
    var argument: String?

    /// How many times one run may start another with `runKeyword`, one after the other
    /// (`a` → `b` → `c` → `d`). Deeper, or back to a keyword already in the chain, is refused.
    static let maximumChain = 3

    init(action: String, value: String? = nil, title: String? = nil, body: String? = nil, text: String? = nil,
         target: String? = nil, path: String? = nil, language: String? = nil, prompt: String? = nil,
         keyword: String? = nil, argument: String? = nil) {
        self.action = action
        self.value = value
        self.title = title
        self.body = body
        self.text = text
        self.target = target
        self.path = path
        self.language = language
        self.prompt = prompt
        self.keyword = keyword
        self.argument = argument
    }

    var kind: Kind? {
        Kind(rawValue: action)
    }

    subscript(field: Field) -> String? {
        get {
            switch field {
            case .value: value
            case .title: title
            case .body: body
            case .text: text
            case .target: target
            case .path: path
            case .language: language
            case .prompt: prompt
            case .keyword: keyword
            case .argument: argument
            }
        }
        set {
            switch field {
            case .value: value = newValue
            case .title: title = newValue
            case .body: body = newValue
            case .text: text = newValue
            case .target: target = newValue
            case .path: path = newValue
            case .language: language = newValue
            case .prompt: prompt = newValue
            case .keyword: keyword = newValue
            case .argument: argument = newValue
            }
        }
    }

    /// As `workflow.json` holds it, for the editor's form.
    var jsonObject: [String: Any] {
        var object: [String: Any] = ["action": action]
        for field in Field.allCases {
            if let value = self[field] {
                object[field.rawValue] = value
            }
        }
        return object
    }

    // MARK: - Validation

    /// What stops the action from running; nil when it can run. `failure` says
    /// whether it is in the failure list, the only one where `{error}` means something.
    func problem(folder: URL, failure: Bool) -> String? {
        guard let kind else { return L("ask.workflow.problem.action.unknown", action) }
        let required = self[kind.requiredField]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if required.isEmpty {
            return L("ask.workflow.problem.action.missing", kind.requiredField.title)
        }
        if !failure, kind.fields.contains(where: { self[$0]?.contains("{error}") == true }) {
            return L("ask.workflow.problem.action.error")
        }
        switch kind {
        case .open:
            if !Self.isOpenable(template: target ?? "") {
                return L("ask.workflow.problem.action.open")
            }
        case .reveal:
            if !Self
                .isRevealable(template: path ?? "", folder: folder) {
                return L("ask.workflow.problem.action.reveal")
            }
        case .runKeyword:
            if !Self.isKeyword(template: keyword ?? "") {
                return L("ask.workflow.problem.action.keyword")
            }
        default:
            break
        }
        return nil
    }

    /// An `open` target this version opens: an http(s) link, `app:` and a name or
    /// bundle id, or a file path. What a placeholder will hold is checked when it runs.
    static func isOpenable(template: String) -> Bool {
        let fixed = template.trimmingCharacters(in: .whitespaces)
        if fixed.hasPrefix("{") {
            return true
        }
        guard let scheme = scheme(of: fixed) else { return true }
        return ["http", "https", "app", "file"].contains(scheme)
    }

    /// A `reveal` path inside the workflow's folder or under `~`, or one a placeholder fills in.
    static func isRevealable(template: String, folder: URL) -> Bool {
        let fixed = template.trimmingCharacters(in: .whitespaces)
        if fixed.hasPrefix("{") || fixed.hasPrefix("~") {
            return true
        }
        return AskWorkflowManifest.scriptURL(fixed, in: folder) != nil
    }

    /// A `runKeyword` keyword: one word, as the launcher matches it, or one a placeholder fills in.
    static func isKeyword(template: String) -> Bool {
        let word = template.trimmingCharacters(in: .whitespaces)
        if word.hasPrefix("{") {
            return true
        }
        return !word.isEmpty && !word.contains { $0.isWhitespace || AskKeywordMatcher.separators.contains($0) }
    }

    /// The lower-cased scheme of `text` ("https" in "https://…", "app" in "app:Notes"); nil without one.
    static func scheme(of text: String) -> String? {
        guard let colon = text.firstIndex(of: ":") else { return nil }
        let scheme = text[..<colon]
        guard let first = scheme.first, first.isLetter, scheme.count > 1,
              scheme.allSatisfy({ $0.isLetter || $0.isNumber || "+-.".contains($0) }) else { return nil }
        return scheme.lowercased()
    }
}
