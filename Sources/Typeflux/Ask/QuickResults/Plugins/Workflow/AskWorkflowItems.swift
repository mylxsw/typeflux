import Foundation

/// What a script printed as an item list: `{"items": [...]}`, in the format of
/// Alfred's Script Filter, so an Alfred script's output works as it is. Fields
/// Typeflux does not use are ignored. See `docs/design/ask-launcher-workflows.md` §4.2.
struct AskWorkflowItemList: Equatable, Sendable {
    /// What Return does with an item's `arg`.
    enum Action: String, Equatable, Sendable {
        /// A link or a file, with its application when the item names one.
        case open
        case copy
        /// Types it into the app the launcher came from.
        case paste
        /// Shows the file in Finder.
        case reveal
        /// Runs the workflow again with `arg` as what was typed.
        case run
        case askAI
    }

    enum Icon: Equatable, Sendable {
        /// `sf:symbol.name`.
        case symbol(String)
        /// An image file: relative to the workflow folder, absolute, or under `~`.
        case file(String)
        /// The Finder icon of this file (`{"type": "fileicon", "path": …}`).
        case fileIcon(String)
        /// The icon of a file type (`{"type": "filetype", "path": "public.folder"}`).
        case fileType(String)
    }

    /// What ⌥↩ does instead (`mods.alt`).
    struct Modifier: Equatable, Sendable {
        var arg: String?
        var subtitle: String?
        var action: Action?
        var valid: Bool?
    }

    struct Item: Equatable, Sendable {
        var uid: String?
        var title: String
        var subtitle = ""
        var arg: String?
        var icon: Icon?
        /// ⇥ puts this after the keyword and runs again, to go one level deeper.
        var autocomplete: String?
        /// False: the row can be seen and completed, not acted on ("No results").
        var valid = true
        var action: Action?
        /// The application `open` uses, by name or bundle id.
        var app: String?
        var alt: Modifier?
        /// What ⌘C copies: `mods.copy.arg`, or Alfred's `text.copy`.
        var copy: String?
    }

    /// More would not help anyone choose; the rest are dropped.
    static let maximumItems = 200
    /// Reruns come no sooner than this.
    static let minimumRerun = 0.5

    var items: [Item]
    /// Seconds after which the launcher runs the workflow again while the list is shown.
    var rerun: Double?
    /// Handed back as options on the next run.
    var variables: [String: String] = [:]

    /// The list in `text`, or nil when it is not a JSON object with an `items` array.
    static func parse(_ text: String) -> AskWorkflowItemList? {
        guard let object = jsonObject(text), let raw = object["items"] as? [Any] else { return nil }
        let items = raw.compactMap { ($0 as? [String: Any]).flatMap(item) }
        let rerun = number(object["rerun"]).map { max(minimumRerun, $0) }
        var variables: [String: String] = [:]
        for (name, value) in object["variables"] as? [String: Any] ?? [:] {
            if let value = string(value) {
                variables[name] = value
            }
        }
        return AskWorkflowItemList(items: Array(items.prefix(maximumItems)), rerun: rerun, variables: variables)
    }

    /// `{"text": "…"}`: a text card instead of a list.
    static func text(in output: String) -> String? {
        guard let object = jsonObject(output), object["items"] == nil else { return nil }
        return object["text"] as? String
    }

    private static func jsonObject(_ text: String) -> [String: Any]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// One item; nil without a title, which Alfred requires too.
    private static func item(_ object: [String: Any]) -> Item? {
        guard let title = string(object["title"])?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty
        else { return nil }
        var item = Item(title: title)
        item.uid = string(object["uid"])
        item.subtitle = string(object["subtitle"]) ?? ""
        item.arg = argument(object["arg"])
        item.icon = icon(object["icon"])
        item.autocomplete = string(object["autocomplete"])
        item.valid = flag(object["valid"]) ?? true
        item.action = (object["action"] as? String).flatMap(Action.init(rawValue:))
        item.app = string(object["app"]).flatMap { $0.isEmpty ? nil : $0 }
        let mods = object["mods"] as? [String: Any] ?? [:]
        if let alt = mods["alt"] as? [String: Any] {
            item.alt = Modifier(arg: argument(alt["arg"]), subtitle: string(alt["subtitle"]),
                                action: (alt["action"] as? String).flatMap(Action.init(rawValue:)),
                                valid: flag(alt["valid"]))
        }
        item.copy = (mods["copy"] as? [String: Any]).flatMap { argument($0["arg"]) }
            ?? ((object["text"] as? [String: Any]).flatMap { string($0["copy"]) })
        return item
    }

    private static func icon(_ value: Any?) -> Icon? {
        let path: String?
        let type: String?
        if let text = value as? String {
            path = text
            type = nil
        } else if let object = value as? [String: Any] {
            path = string(object["path"])
            type = string(object["type"])
        } else {
            return nil
        }
        guard let path, !path.isEmpty else { return nil }
        switch type {
        case "fileicon": return .fileIcon(path)
        case "filetype": return .fileType(path)
        default: return path.hasPrefix("sf:") ? .symbol(String(path.dropFirst(3))) : .file(path)
        }
    }

    /// Alfred allows a list of arguments; they become one per line.
    private static func argument(_ value: Any?) -> String? {
        if let list = value as? [Any] {
            let parts = list.compactMap(string)
            return parts.isEmpty ? nil : parts.joined(separator: "\n")
        }
        return string(value)
    }

    /// Text, or a number or boolean written as text.
    private static func string(_ value: Any?) -> String? {
        switch value {
        case let text as String: text
        case let number as NSNumber where CFGetTypeID(number) == CFBooleanGetTypeID():
            number.boolValue ? "true" : "false"
        case let number as NSNumber:
            number.stringValue
        default: nil
        }
    }

    private static func number(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber where CFGetTypeID(number) != CFBooleanGetTypeID(): number.doubleValue
        case let text as String: Double(text)
        default: nil
        }
    }

    /// `true` / `false`, also written as text or a number by scripts that are not careful.
    private static func flag(_ value: Any?) -> Bool? {
        switch value {
        case let number as NSNumber: number.boolValue
        case let text as String:
            switch text.lowercased() {
            case "true", "yes", "1": true
            case "false", "no", "0": false
            default: nil
            }
        default: nil
        }
    }
}

/// How the launcher shows one run's stdout, by the manifest's `display`.
enum AskWorkflowDecodedOutput: Equatable, Sendable {
    /// A text card, with a note when the output was meant to be something else.
    case text(String, note: String?)
    case items(AskWorkflowItemList)
    case markdown(String)

    /// `auto` lists `{"items": …}` and shows the rest as text; `items` says so when
    /// the output is not a list. `{"text": …}` is a text card in both.
    static func decode(_ stdout: String, display: AskWorkflowManifest.Output.Display) -> AskWorkflowDecodedOutput {
        let text = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        switch display {
        case .markdown:
            return .markdown(text)
        case .items, .auto:
            if let list = AskWorkflowItemList.parse(text) {
                return .items(list)
            }
            if let card = AskWorkflowItemList.text(in: text) {
                return .text(card, note: nil)
            }
            return .text(text, note: display == .items ? L("ask.workflow.items.invalid") : nil)
        case .text, .none, .image:
            return .text(text, note: nil)
        }
    }

    /// While the script still prints: lists only make sense once complete, so they
    /// are not shown growing (nor is anything that starts like one).
    static func streams(_ partial: String, display: AskWorkflowManifest.Output.Display) -> Bool {
        switch display {
        case .none, .items: false
        case .auto: !partial.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{")
        case .text, .markdown, .image: true
        }
    }
}
