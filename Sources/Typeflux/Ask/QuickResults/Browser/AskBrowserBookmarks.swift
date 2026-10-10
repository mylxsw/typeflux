import Foundation

/// Read-only adapters for Safari, Chromium profiles and Arc's saved sidebar.
enum AskBrowserBookmarks {
    // Native formats have different locations, parsing and access failures.
    // swiftlint:disable:next cyclomatic_complexity
    static func read(_ browser: AskSearchBrowser, home: URL) -> AskBrowserSearchSnapshot {
        let root = home.appendingPathComponent(browser.bookmarkRoot)
        var snapshot = AskBrowserSearchSnapshot()
        let manager = FileManager.default
        let files: [URL]
        do {
            switch browser {
            case .safari: files = [root.appendingPathComponent("Bookmarks.plist")]
            case .arc: files = [root.appendingPathComponent("StorableSidebar.json")]
            default:
                guard manager.fileExists(atPath: root.path) else { return snapshot }
                files = try manager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])
                    .sorted { $0.lastPathComponent < $1.lastPathComponent }
                    .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
                    .map { $0.appendingPathComponent("Bookmarks") }
            }
            for file in files {
                do {
                    // Missing bookmarks are normal for a new profile or unused browser.
                    let attributes: [FileAttributeKey: Any]
                    do { attributes = try manager.attributesOfItem(atPath: file.path) } catch let error as CocoaError
                        where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile { continue }
                    guard (attributes[.size] as? NSNumber)?.intValue ?? 0 <= 32_000_000 else {
                        throw CocoaError(.fileReadCorruptFile)
                    }
                    let data = try Data(contentsOf: file)
                    let entries: [AskBrowserSearchEntry] = switch browser {
                    case .safari: try safari(data)
                    case .arc: try arc(data)
                    default: try chromium(
                            data,
                            browser: browser,
                            profile: file.deletingLastPathComponent().lastPathComponent
                        )
                    }
                    snapshot.entries += entries
                } catch {
                    let failure = error as NSError
                    let permission = failure.code == NSFileReadNoPermissionError ||
                        (failure.domain == NSPOSIXErrorDomain && [1, 13].contains(failure.code))
                    let issue = AskBrowserSearchIssue(browser: browser, reason: permission ? .diskAccess : .unreadable)
                    if !snapshot.issues.contains(issue) { snapshot.issues.append(issue) }
                }
            }
        } catch {
            snapshot.issues.append(.init(browser: browser, reason: .diskAccess))
        }
        return snapshot
    }

    static func chromium(_ data: Data, browser: AskSearchBrowser, profile: String) throws -> [AskBrowserSearchEntry] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let roots = json["roots"] as? [String: Any] else { throw CocoaError(.fileReadCorruptFile) }
        var entries: [AskBrowserSearchEntry] = []
        func visit(_ node: [String: Any], folders: [String], depth: Int) {
            guard depth < 64, entries.count < 50000 else { return }
            let name = node["name"] as? String ?? ""
            if node["type"] as? String == "url", let url = node["url"] as? String,
               AskBrowserSearchEntry.bookmarkURL(url) != nil {
                entries.append(.init(
                    id: browser.id + ":" + profile + ":" + (node["id"] as? String ?? String(entries.count)),
                    kind: .bookmark,
                    browser: browser,
                    title: name,
                    url: url,
                    folder: folders.joined(separator: " / "),
                    profile: profile
                ))
            }
            let next = name.isEmpty ? folders : folders + [name]
            for child in node["children"] as? [[String: Any]] ?? [] {
                visit(child, folders: next, depth: depth + 1)
            }
        }
        for key in roots.keys
            .sorted() {
            if let node = roots[key] as? [String: Any] { visit(node, folders: [], depth: 0) }
        }
        return entries
    }

    static func safari(_ data: Data) throws -> [AskBrowserSearchEntry] {
        guard let root = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var entries: [AskBrowserSearchEntry] = []
        func visit(_ node: [String: Any], folders: [String], depth: Int) {
            guard depth < 64, entries.count < 50000 else { return }
            // Reading List is a separate source, not the user's bookmarks.
            guard node["Title"] as? String != "com.apple.ReadingList" else { return }
            let title = (node["URIDictionary"] as? [String: Any])?["title"] as? String ?? node["Title"] as? String ?? ""
            if let url = node["URLString"] as? String, AskBrowserSearchEntry.bookmarkURL(url) != nil {
                entries.append(.init(id: "safari:" + (node["WebBookmarkUUID"] as? String ?? String(entries.count)),
                                     kind: .bookmark, browser: .safari, title: title, url: url,
                                     folder: folders.joined(separator: " / ")))
            }
            let next = title.isEmpty ? folders : folders + [title]
            for child in node["Children"] as? [[String: Any]] ?? [] {
                visit(child, folders: next, depth: depth + 1)
            }
        }
        visit(root, folders: [], depth: 0)
        return entries
    }

    /// Arc bookmarks are favorites and pinned trees; daily/unpinned tabs are excluded.
    static func arc(_ data: Data) throws -> [AskBrowserSearchEntry] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sidebar = json["sidebar"] as? [String: Any],
              let containers = sidebar["containers"] as? [[String: Any]] else { throw CocoaError(.fileReadCorruptFile) }
        var entries: [AskBrowserSearchEntry] = []
        var seen = Set<String>()
        func pairs(_ values: [Any]) -> [String: [String: Any]] {
            var result: [String: [String: Any]] = [:]
            for index in stride(from: 0, to: max(0, values.count - 1), by: 2) {
                if let id = values[index] as? String,
                   let value = values[index + 1] as? [String: Any] { result[id] = value }
            }
            return result
        }
        for container in containers {
            let items = pairs(container["items"] as? [Any] ?? [])
            func visit(_ id: String, folders: [String], depth: Int) {
                guard depth < 64, entries.count < 50000, !seen.contains(id), let item = items[id] else { return }
                seen.insert(id)
                let title = item["title"] as? String ?? ""
                let tab = (item["data"] as? [String: Any])?["tab"] as? [String: Any]
                if let tab, let url = tab["savedURL"] as? String, AskBrowserSearchEntry.bookmarkURL(url) != nil {
                    entries.append(.init(id: "arc:" + id, kind: .bookmark, browser: .arc,
                                         title: title.isEmpty ? tab["savedTitle"] as? String ?? url : title,
                                         url: url, folder: folders.joined(separator: " / ")))
                }
                let next = title.isEmpty ? folders : folders + [title]
                let children = item["childrenIds"] as? [String] ?? items.keys.sorted().filter {
                    items[$0]?["parentID"] as? String == id
                }
                for child in children {
                    visit(child, folders: next, depth: depth + 1)
                }
            }
            // Favorites may be stored as alternating profile/container pairs.
            for id in container["topAppsContainerIDs"] as? [String] ?? [] where items[id] != nil {
                visit(id, folders: ["Favorites"], depth: 0)
            }
            let spaces = pairs(container["spaces"] as? [Any] ?? [])
            for id in spaces.keys.sorted() {
                guard let space = spaces[id] else { continue }
                let roots = space["newContainerIDs"] as? [Any] ?? space["containerIDs"] as? [Any] ?? []
                for index in stride(from: 0, to: max(0, roots.count - 1), by: 2) {
                    let pinned = roots[index] as? String == "pinned" || (roots[index] as? [String: Any])?["pinned"] !=
                        nil
                    if pinned, let root = roots[index + 1] as? String {
                        visit(root, folders: [space["title"] as? String ?? "Pinned"], depth: 0)
                    }
                }
            }
        }
        return entries
    }
}
