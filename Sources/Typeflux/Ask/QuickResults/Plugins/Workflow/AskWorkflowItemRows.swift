import Foundation

/// A workflow's item list as launcher rows: what each row's keys do, and its icon.
/// See `docs/design/ask-launcher-workflows.md` §4.2.
extension AskWorkflowPlugin {
    /// The result for a list. An empty one shows a single "No results" row.
    func itemsOutput(_ list: AskWorkflowItemList, base: AskPluginOutput, input: Input) -> AskPluginOutput {
        var output = base
        let rows = AskWorkflowItemRows(folder: workflow.folder, home: home, name: title)
        output.items = rows.items(list, replaces: input.selection != nil && input.query.isEmpty,
                                  original: base.original)
        output.body = list.items.map(\.title).joined(separator: "\n")
        // The rows carry Return, ⌥↩ and ⌘C; the result keeps running again (⌘R) and editing (⌘E).
        output.actions = base.actions.filter { action in
            switch action.kind {
            case .rerun, .editWorkflow: true
            default: false
            }
        }
        output.rerunAfter = list.rerun
        output.variables = list.variables
        return output
    }
}

/// Builds the rows of one workflow's list; the launcher and the editor's preview share it.
struct AskWorkflowItemRows {
    /// Relative paths (icons, files to open) are inside it.
    var folder: URL
    var home = NSHomeDirectory()
    /// The workflow's name, for asking the AI about a row.
    var name: String

    /// Every row; an empty list shows a single "No results" row.
    func items(_ list: AskWorkflowItemList, replaces: Bool, original: String) -> [AskPluginItem] {
        let items = list.items.enumerated().map { index, item in
            row(item, index: index, replaces: replaces, original: original)
        }
        return items.isEmpty
            ? [AskPluginItem(id: "empty", title: L("ask.workflow.items.empty"), icon: .symbol("magnifyingglass"),
                             valid: false)]
            : items
    }

    func row(_ item: AskWorkflowItemList.Item, index: Int, replaces: Bool, original: String) -> AskPluginItem {
        var actions: [AskPluginAction] = []
        if item.valid, let arg = item.arg, let main = action(item.action, arg: arg, app: item.app, replaces: replaces) {
            actions.append(main.with(.enter))
        } else if let autocomplete = item.autocomplete {
            // A row that cannot be acted on goes one level deeper on Return, as in Alfred.
            actions.append(AskPluginAction(kind: .runWith(autocomplete), title: L("ask.plugin.action.complete"),
                                           symbol: "arrow.right.to.line", shortcut: .enter))
        }
        let alt = item.alt
        if alt?.valid ?? item.valid, let arg = alt?.arg ?? item.arg,
           let option = action(alt?.action ?? .paste, arg: arg, app: item.app, replaces: replaces) {
            actions.append(option.with(.optionEnter))
        }
        let copy = item.copy ?? item.arg ?? item.title
        if !copy.isEmpty {
            actions.append(AskPluginAction(kind: .copy(copy), title: L("ask.plugin.action.copy"), symbol: "doc.on.doc",
                                           shortcut: .commandC))
        }
        let about = item.subtitle.isEmpty ? item.title : item.title + "\n" + item.subtitle
        actions.append(AskPluginAction(kind: .askAI(L("ask.workflow.askAI", name, original, about)),
                                       title: L("ask.quick.askAI"), symbol: "bubble.left", shortcut: nil))
        return AskPluginItem(id: item.uid.map { "uid:" + $0 } ?? "index:\(index)", title: item.title,
                             subtitle: item.subtitle, icon: item.icon.flatMap(icon), valid: item.valid,
                             autocomplete: item.autocomplete, actions: actions)
    }

    /// What `action` does with `arg`. Without an action, links and paths open and
    /// anything else is copied. Nil when it cannot be done (open something that is
    /// neither a link nor a path).
    func action(_ action: AskWorkflowItemList.Action?, arg: String, app: String?,
                replaces: Bool) -> AskPluginAction? {
        let target = openTarget(arg)
        switch action ?? (target != nil ? .open : .copy) {
        case .open:
            guard let target else { return nil }
            if let app, target.isFileURL {
                return AskPluginAction(kind: .openIn(target, application: app),
                                       title: L("ask.plugin.action.openIn", Self.applicationName(app)),
                                       symbol: "arrow.up.forward.app", shortcut: nil)
            }
            return AskPluginAction(kind: .open(target), title: L("ask.plugin.action.open"),
                                   symbol: "arrow.up.right.square", shortcut: nil)
        case .copy:
            return AskPluginAction(kind: .copy(arg), title: L("ask.plugin.action.copy"), symbol: "doc.on.doc",
                                   shortcut: nil)
        case .paste:
            return AskPluginAction(kind: .writeBack(arg),
                                   title: L(replaces ? "ask.plugin.action.replace" : "ask.plugin.action.insert"),
                                   symbol: replaces ? "arrow.down.to.line" : "text.insert", shortcut: nil)
        case .reveal:
            guard let url = fileURL(arg) else { return nil }
            return AskPluginAction(kind: .reveal(url), title: L("ask.plugin.action.reveal"), symbol: "folder",
                                   shortcut: nil)
        case .run:
            return AskPluginAction(kind: .runWith(arg), title: L("ask.plugin.action.run"), symbol: "play",
                                   shortcut: nil)
        case .askAI:
            return AskPluginAction(kind: .askAI(arg), title: L("ask.quick.askAI"), symbol: "bubble.left",
                                   shortcut: nil)
        }
    }

    /// An http(s) link or a file; nil for anything else (other schemes are not opened).
    func openTarget(_ arg: String) -> URL? {
        let text = arg.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: text), let scheme = url.scheme?.lowercased() {
            if scheme == "http" || scheme == "https" {
                return url.host == nil ? nil : url
            }
            if scheme == "file" {
                return url.standardizedFileURL
            }
        }
        guard text.hasPrefix("/") || text.hasPrefix("~") else { return nil }
        return fileURL(text)
    }

    /// A path: absolute, under `~`, a `file:` URL, or relative to the workflow folder.
    func fileURL(_ path: String) -> URL? {
        let text = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains("\n") else { return nil }
        if let url = URL(string: text), url.scheme?.lowercased() == "file" {
            return url.standardizedFileURL
        }
        if text == "~" || text.hasPrefix("~/") {
            return URL(fileURLWithPath: home + text.dropFirst()).standardizedFileURL
        }
        if text.hasPrefix("/") {
            return URL(fileURLWithPath: text).standardizedFileURL
        }
        return folder.appendingPathComponent(text).standardizedFileURL
    }

    func icon(_ icon: AskWorkflowItemList.Icon) -> AskPluginItem.Icon? {
        switch icon {
        case let .symbol(name): .symbol(name)
        case let .file(path): fileURL(path).map(AskPluginItem.Icon.image)
        case let .fileIcon(path): fileURL(path).map(AskPluginItem.Icon.fileIcon)
        case let .fileType(type): .fileType(type)
        }
    }

    /// The application as the action names it: "Visual Studio Code", or a bundle id as given.
    static func applicationName(_ app: String) -> String {
        app.hasSuffix(".app") ? String(app.dropLast(4)) : app
    }
}

extension AskPluginAction {
    /// The same action on another key.
    func with(_ shortcut: Shortcut) -> AskPluginAction {
        var copy = self
        copy.shortcut = shortcut
        return copy
    }
}
