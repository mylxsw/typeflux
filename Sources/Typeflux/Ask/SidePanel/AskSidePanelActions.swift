import AppKit
import SwiftUI

/// What views inside the conversation use to open things in the side panel: links, files
/// named in messages and tool steps, sent attachments and artifacts. Views outside a
/// conversation window get nil and keep their own behavior.
struct AskSidePanelActions {
    /// A path inside the selected conversation's workspace (`work/analyze.py`), or an absolute
    /// path under it or a folder granted to it.
    var openFile: (String) -> Void = { _ in }
    /// A link from a message; `external` (⌘-click) always uses the system browser.
    var openLink: (URL, _ external: Bool) -> Void = { url, _ in NSWorkspace.shared.open(url) }
    var openArtifact: (AskArtifactRef, _ name: String) -> Void = { _, _ in }
    /// The panel's Files tab.
    var showFiles: () -> Void = {}
    /// The file's location on disk for the external-open menu, when it is in the workspace.
    var fileURL: (String) -> URL? = { _ in nil }
}

extension EnvironmentValues {
    @Entry var askSidePanelActions: AskSidePanelActions? = nil
}

/// Where a message link opens, from Settings → Agent → "Open links in".
enum AskLinkOpening: String, CaseIterable, Sendable {
    case sidePanel
    case browser
}

extension SettingsStore {
    var askLinkOpening: AskLinkOpening {
        get { defaults.string(forKey: "ask.links.opening").flatMap(AskLinkOpening.init(rawValue:)) ?? .sidePanel }
        set { defaults.set(newValue.rawValue, forKey: "ask.links.opening") }
    }
}

enum AskLinkRoute: Equatable {
    case sidePanel(URL)
    case browser(URL)
    /// A workspace path linked from a message, such as `outputs/report.html`.
    case workspaceFile(String)
}

enum AskLinkRouter {
    /// Markdown links to workspace paths carry this scheme, so a click can tell them from pages.
    static let fileScheme = "typeflux-file"
    private static let workspaceFolders = ["inputs", "outputs", "work"]

    /// Web pages open in the side panel unless the user chose the system browser, held ⌘,
    /// or there is no in-app browser; other schemes (`mailto:`) always leave Typeflux.
    static func route(_ url: URL, external: Bool, opening: AskLinkOpening, panelAvailable: Bool) -> AskLinkRoute {
        let scheme = url.scheme?.lowercased() ?? ""
        if scheme == fileScheme, let path = workspacePath(fromLink: url) { return .workspaceFile(path) }
        guard ["http", "https"].contains(scheme), !external, opening == .sidePanel, panelAvailable else {
            return .browser(url)
        }
        return .sidePanel(url)
    }

    /// A Markdown destination naming a file in the conversation workspace (`outputs/a.html`,
    /// `./work/b.py`) as a link a click can route; other destinations return nil.
    static func link(forDestination destination: String) -> URL? {
        guard let path = workspacePath(destination) else { return nil }
        var components = URLComponents()
        components.scheme = fileScheme
        components.path = path
        return components.url
    }

    static func workspacePath(fromLink url: URL) -> String? {
        guard url.scheme?.lowercased() == fileScheme else { return nil }
        return workspacePath(url.path)
    }

    /// A relative path under `inputs/`, `outputs/` or `work/`, without `.` parts; nil otherwise.
    static func workspacePath(_ raw: String) -> String? {
        let text = raw.removingPercentEncoding ?? raw
        guard !text.hasPrefix("/"), !text.contains("\\") else { return nil }
        let parts = text.split(separator: "/", omittingEmptySubsequences: true).filter { $0 != "." }.map(String.init)
        guard parts.count >= 2, workspaceFolders.contains(parts[0]), !parts.contains("..") else { return nil }
        return parts.joined(separator: "/")
    }
}
