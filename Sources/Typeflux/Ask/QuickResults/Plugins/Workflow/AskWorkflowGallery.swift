import Foundation

/// The example workflows that ship with Typeflux, in `Sources/Typeflux/WorkflowGallery/`
/// (copied into the resource bundle as is): `gallery.json` lists them (category,
/// order, a sample run for the detail page), and each one is a workflow folder. Adding one copies it into the user's
/// workflows folder. See `docs/design/workflow-gallery-output-actions.md` §1.
struct AskWorkflowGallery: Equatable, Sendable {
    enum Category: String, CaseIterable, Codable, Sendable {
        case text, dev, network, system

        var title: String {
            L("ask.workflow.gallery.category." + rawValue)
        }
    }

    /// One example: the index entry and the folder it describes.
    struct Item: Equatable, Identifiable, Sendable {
        /// A sample run, shown as the launcher would show it, without running anything.
        struct Preview: Codable, Equatable, Sendable {
            var keyword: String
            var query: String
            var selection: String?
            var output: String
        }

        /// One line of the detail page's usage: what to type, and what it does.
        struct Usage: Codable, Equatable, Sendable {
            var example: String
            /// A key under `ask.workflow.gallery.`.
            var text: String

            var description: String {
                L("ask.workflow.gallery." + text)
            }
        }

        var id: String
        var category: Category
        var order: Int
        /// A tile color name (`orange`, `blue`…); the editor's palette when absent.
        var color: String?
        var preview: Preview?
        var usage: [Usage]
        /// The example's bundled folder.
        var folder: URL
        /// The manifest with its text in the interface language.
        var manifest: AskWorkflowManifest
        /// Reviewed network destinations from the bundled index, or a scan for older entries.
        var hosts: [String] = []

        var name: String {
            manifest.name
        }

        var summary: String {
            manifest.description ?? ""
        }

        var version: String {
            manifest.version ?? "1.0.0"
        }

        var keywords: [String] {
            manifest.keywords.map(\.keyword)
        }

        var runtime: AskWorkflowRuntime {
            manifest.command.runtime
        }

        var demonstrates: String {
            L("ask.workflow.gallery.\(id).demonstrates")
        }

        var symbol: String {
            if let icon = manifest.icon, icon.hasPrefix("sf:") {
                return String(icon.dropFirst(3))
            }
            return "chevron.left.forwardslash.chevron.right"
        }

        /// The example's files, by path relative to its folder, with the manifest localized.
        func files(fileManager: FileManager = .default) -> [String: Data] {
            var files: [String: Data] = [:]
            let root = folder.standardizedFileURL.path
            let enumerator = fileManager.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey],
                                                    options: [.skipsHiddenFiles])
            while let url = enumerator?.nextObject() as? URL {
                if url.lastPathComponent == "__pycache__" {
                    enumerator?.skipDescendants(); continue
                }
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                      let data = try? Data(contentsOf: url) else { continue }
                files[String(url.standardizedFileURL.path.dropFirst(root.count + 1))] = data
            }
            return files
        }

        /// The script the detail page shows: the default entry.
        var entryScript: String? {
            manifest.command.script
        }
    }

    static let indexName = "gallery.json"
    /// Text in a bundled manifest written `@L:fx.name` is looked up under `ask.workflow.gallery.`.
    static let localizedPrefix = "@L:"

    var items: [Item]

    /// The gallery that ships with the app, read again each time so its text follows the interface language.
    static var bundled: AskWorkflowGallery {
        load(root: Bundle.appResources.resourceURL?.appendingPathComponent("WorkflowGallery"))
    }

    /// Reads a gallery folder; examples whose folder or manifest cannot be read are left out.
    static func load(root: URL?, fileManager: FileManager = .default) -> AskWorkflowGallery {
        guard let root, let data = try? Data(contentsOf: root.appendingPathComponent(indexName)),
              let index = try? JSONDecoder().decode(Index.self, from: data)
        else { return AskWorkflowGallery(items: []) }
        let items = index.items.compactMap { entry -> Item? in
            let folder = root.appendingPathComponent(entry.id, isDirectory: true)
            guard let text = try? String(contentsOf: folder.appendingPathComponent(AskWorkflowManifest.fileName),
                                         encoding: .utf8),
                let manifest = localizedManifest(text) else { return nil }
            var item = Item(id: entry.id, category: entry.category, order: entry.order, color: entry.color,
                            preview: entry.preview, usage: entry.usage ?? [], folder: folder, manifest: manifest)
            if let reviewedHosts = entry.hosts {
                item.hosts = reviewedHosts
            } else {
                let contents = item.files(fileManager: fileManager).values.compactMap { String(data: $0, encoding: .utf8) }
                item.hosts = hosts(in: contents.joined(separator: "\n"))
            }
            return item
        }
        return AskWorkflowGallery(items: items.sorted { $0.order < $1.order })
    }

    private struct Index: Decodable {
        struct Entry: Decodable {
            var id: String
            var category: Category
            var order: Int
            var color: String?
            var preview: Item.Preview?
            var usage: [Item.Usage]?
            /// Explicit destinations avoid treating dependency license/documentation URLs as network calls.
            var hosts: [String]?
        }

        var items: [Entry]
    }

    func item(_ id: String) -> Item? {
        items.first { $0.id == id }
    }

    /// The examples in a category (all of them for nil) whose name, summary or keywords contain `query`.
    func filtered(category: Category?, query: String) -> [Item] {
        let query = query.trimmingCharacters(in: .whitespaces).lowercased()
        return items.filter { item in
            (category == nil || item.category == category)
                && (query.isEmpty || item.name.lowercased().contains(query) || item.summary.lowercased().contains(query)
                    || item.keywords.contains { $0.lowercased().contains(query) })
        }
    }

    /// How many examples each category has; empty categories are left out.
    var categoryCounts: [(category: Category, count: Int)] {
        Category.allCases.compactMap { category in
            let count = items.filter { $0.category == category }.count
            return count > 0 ? (category, count) : nil
        }
    }

    // MARK: - Rendering

    /// The bundled manifest's JSON with every `@L:` string looked up.
    static func localizedManifest(_ text: String) -> AskWorkflowManifest? {
        guard let object = localizedObject(text),
              let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return try? JSONDecoder().decode(AskWorkflowManifest.self, from: data)
    }

    static func localizedObject(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return localize(object) as? [String: Any]
    }

    private static func localize(_ value: Any) -> Any {
        switch value {
        case let string as String where string.hasPrefix(localizedPrefix):
            L("ask.workflow.gallery." + string.dropFirst(localizedPrefix.count))
        case let array as [Any]:
            array.map(localize)
        case let object as [String: Any]:
            object.mapValues(localize)
        default:
            value
        }
    }

    /// The files to write for `item` installed as `id` with `keywords` (one per manifest
    /// keyword, in order): its text localized and where it came from recorded in `origin`.
    static func render(_ item: Item, id: String, keywords: [String],
                       fileManager: FileManager = .default) -> [String: Data] {
        var files = item.files(fileManager: fileManager)
        guard let data = files[AskWorkflowManifest.fileName], let text = String(data: data, encoding: .utf8),
              var object = localizedObject(text) else { return files }
        object["id"] = id
        if var rows = object["keywords"] as? [[String: Any]] {
            for index in rows.indices where keywords.indices.contains(index) {
                rows[index]["keyword"] = keywords[index]
            }
            object["keywords"] = rows
        }
        object["origin"] = ["gallery": item.id, "version": item.version]
        if let rendered = AskWorkflowJSONLayout.format(object, like: text) {
            files[AskWorkflowManifest.fileName] = Data(rendered.utf8)
        }
        return files
    }

    // MARK: - Versions and hosts

    /// Whether `version` is older than `other`, comparing dot-separated numbers ("1.2" < "1.10").
    static func isOlder(_ version: String, than other: String) -> Bool {
        let left = version.split(separator: ".").map { Int($0) ?? 0 }
        let right = other.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0 ..< max(left.count, right.count) {
            let mine = index < left.count ? left[index] : 0, theirs = index < right.count ? right[index] : 0
            if mine != theirs {
                return mine < theirs
            }
        }
        return false
    }

    /// The hosts of the http(s) addresses in `text`, each once, in order.
    static func hosts(in text: String) -> [String] {
        guard let pattern = try? NSRegularExpression(pattern: #"https?://([A-Za-z0-9.-]+)"#) else { return [] }
        var seen = Set<String>()
        return pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            Range(match.range(at: 1), in: text).map { String(text[$0]).lowercased() }
        }.filter { seen.insert($0).inserted }
    }
}
