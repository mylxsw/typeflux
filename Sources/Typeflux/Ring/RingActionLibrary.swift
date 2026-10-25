import AppKit
import Foundation

/// One thing the library offers to put on the ring.
struct RingLibraryItem: Identifiable, Equatable {
    let kind: RingActionKind
    let title: String
    let subtitle: String
    let symbol: String
    /// The heading the item is listed under.
    let group: String

    var id: String {
        kind.pickerKey
    }

    var type: RingActionType {
        kind.type
    }

    /// Keywords, keys, folders and web pages are told apart by their second line; built-in actions
    /// and apps are named well enough by their title.
    var subtitleIdentifiesTarget: Bool {
        [.keyword, .keys, .folder, .url].contains(type)
    }

    func action(id: UUID = UUID()) -> RingAction {
        RingAction(id: id, kind: kind, title: title, symbol: symbol)
    }
}

/// An app the library can open.
struct RingLibraryApp: Equatable, Sendable {
    let name: String
    let bundleIdentifier: String
}

/// A key combination offered without recording.
struct RingKeyPreset: Equatable {
    let title: String
    let binding: HotkeyBinding

    private static func binding(_ keyCode: Int, _ flags: NSEvent.ModifierFlags) -> HotkeyBinding {
        HotkeyBinding(keyCode: keyCode, modifierFlags: UInt(flags.rawValue))
    }

    static var common: [RingKeyPreset] {
        [
            RingKeyPreset(title: L("ring.keys.reopenTab"), binding: binding(17, [.command, .shift])),
            RingKeyPreset(title: L("ring.keys.closeWindow"), binding: binding(13, .command)),
            RingKeyPreset(title: L("ring.keys.fullScreen"), binding: binding(3, [.control, .command])),
            RingKeyPreset(title: L("ring.keys.nextWindow"), binding: binding(50, .command)),
            RingKeyPreset(title: L("ring.keys.screenshotTools"), binding: binding(23, [.command, .shift]))
        ]
    }
}

/// Everything Settings → Ring can add, searchable across types. Pure: apps, keywords and
/// shortcuts are loaded by the caller and passed in.
struct RingActionLibrary {
    /// The order of the type cards.
    static let types: [RingActionType] = [.feature, .keyword, .system, .app, .keys, .shortcut, .url, .folder]
    /// Features suggested first, in order, while they are not on the ring yet.
    static let recommended: [RingActionKind] = [
        .feature(.chat), .system(.darkMode), .feature(.screenshotTranslation), .feature(.notes), .system(.emoji),
        .feature(.dictation), .feature(.ask), .feature(.translate)
    ]
    static let defaultFolders = ["~/Downloads", "~/Documents", "~/Desktop", "~"]

    var keywords: [KeywordHotkeyOption] = []
    var apps: [RingLibraryApp] = []
    var shortcuts: [String] = []
    var folders: [String] = RingActionLibrary.defaultFolders
    /// Shortcuts of the app whose actions are being edited (`RingAppShortcutCatalog`); listed
    /// before the common keys and suggested first.
    var appShortcuts: [RingLibraryItem] = []

    // MARK: - Browsing

    func items(of type: RingActionType) -> [RingLibraryItem] {
        switch type {
        case .feature:
            RingFeature.allCases.map(Self.item(for:))
        case .system:
            RingSystemAction.allCases.map(Self.item(for:))
        case .keyword:
            keywords.map { option in
                RingLibraryItem(kind: .keyword(keyword: option.keyword.keyword, pluginID: option.keyword.pluginID),
                                title: option.name, subtitle: option.keyword.keyword,
                                symbol: RingActionType.keyword.symbol, group: L("ring.library.group.keywords"))
            }
        case .app:
            apps.map { app in
                RingLibraryItem(kind: .app(bundleIdentifier: app.bundleIdentifier, name: app.name), title: app.name,
                                subtitle: app.bundleIdentifier, symbol: RingActionType.app.symbol,
                                group: L("ring.library.group.apps"))
            }
        case .keys:
            appShortcuts + RingKeyPreset.common.map { preset in
                RingLibraryItem(kind: .keys(preset.binding), title: preset.title,
                                subtitle: HotkeyFormat.display(preset.binding), symbol: RingActionType.keys.symbol,
                                group: L("ring.library.group.commonKeys"))
            }
        case .shortcut:
            shortcuts.map { Self.shortcutItem($0) }
        case .url:
            []
        case .folder:
            folders.map { Self.folderItem($0) }
        }
    }

    /// Items of `type` matching `query`. A shortcut name that is not listed can still be typed.
    func items(of type: RingActionType, matching query: String) -> [RingLibraryItem] {
        let matches = items(of: type).filter { TFSearchMatcher.matches(query, $0.title, $0.subtitle) }
        let trimmed = TFSearchMatcher.normalized(query)
        switch type {
        case .shortcut where !trimmed.isEmpty && !matches.contains(where: { $0.title == trimmed }):
            return matches + [Self.shortcutItem(trimmed, group: L("ring.library.group.typed"))]
        case .folder where Self.looksLikePath(trimmed):
            return [Self.folderItem(trimmed, group: L("ring.library.group.typed"))] + matches
        default:
            return matches
        }
    }

    // MARK: - Search

    /// Every type at once. A typed web address or path comes first as something to open.
    func search(_ query: String) -> [RingLibraryItem] {
        let trimmed = TFSearchMatcher.normalized(query)
        guard !trimmed.isEmpty else { return [] }
        var results: [RingLibraryItem] = []
        if let url = Self.urlItem(trimmed) {
            results.append(url)
        }
        if Self.looksLikePath(trimmed) {
            results.append(Self.folderItem(trimmed, group: L("ring.library.group.typed")))
        }
        for type in Self.types where type != .url {
            let typeTitle = type.title
            results += items(of: type).filter { TFSearchMatcher.matches(trimmed, $0.title, $0.subtitle, typeTitle) }
                .map { RingLibraryItem(kind: $0.kind, title: $0.title, subtitle: $0.subtitle, symbol: $0.symbol,
                                       group: typeTitle) }
        }
        return results
    }

    /// Up to `limit` suggestions that are not on the ring yet: the app's own shortcuts while an
    /// app's actions are edited, otherwise popular features.
    func recommendations(excluding actions: [RingAction], limit: Int = 4) -> [RingLibraryItem] {
        let present = Set(actions.map(\.kind.pickerKey))
        let fromApp = appShortcuts.filter { !present.contains($0.kind.pickerKey) }
        if !fromApp.isEmpty {
            return Array(fromApp.prefix(limit))
        }
        return Self.recommended.filter { !present.contains($0.pickerKey) }.prefix(limit).compactMap(Self.item(for:))
    }

    static func contains(_ item: RingLibraryItem, in actions: [RingAction]) -> Bool {
        actions.contains { $0.kind.pickerKey == item.kind.pickerKey }
    }

    // MARK: - Items

    static func item(for feature: RingFeature) -> RingLibraryItem {
        RingLibraryItem(kind: .feature(feature), title: feature.title, subtitle: feature.detail,
                        symbol: feature.symbol, group: L("ring.library.group." + feature.libraryGroup))
    }

    static func item(for system: RingSystemAction) -> RingLibraryItem {
        RingLibraryItem(kind: .system(system), title: system.title, subtitle: system.detail, symbol: system.symbol,
                        group: L("ring.library.group." + system.libraryGroup))
    }

    /// The library item for a built-in kind; other kinds depend on what is installed.
    static func item(for kind: RingActionKind) -> RingLibraryItem? {
        switch kind {
        case let .feature(feature): item(for: feature)
        case let .system(system): item(for: system)
        default: nil
        }
    }

    static func keysItem(_ binding: HotkeyBinding) -> RingLibraryItem {
        let display = HotkeyFormat.display(binding)
        return RingLibraryItem(kind: .keys(binding), title: L("ring.editor.keysTitle", display), subtitle: display,
                               symbol: RingActionType.keys.symbol, group: L("ring.library.group.typed"))
    }

    static func shortcutItem(_ name: String, group: String = L("ring.library.group.shortcuts")) -> RingLibraryItem {
        RingLibraryItem(kind: .shortcut(name: name), title: name, subtitle: RingActionType.shortcut.title,
                        symbol: RingActionType.shortcut.symbol, group: group)
    }

    static func folderItem(_ path: String, group: String = L("ring.library.group.folders")) -> RingLibraryItem {
        let expanded = RingSettingsPresentation.expandedFolderPath(path)
        let name = expanded == NSHomeDirectory() ? L("ring.library.home") : (expanded as NSString).lastPathComponent
        return RingLibraryItem(kind: .folder(path: path), title: name, subtitle: path,
                               symbol: RingActionType.folder.symbol, group: group)
    }

    /// A web page for text that is, or plainly means, an http(s) address: "github.com" counts.
    static func urlItem(_ text: String) -> RingLibraryItem? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(" "), !looksLikePath(trimmed) else { return nil }
        let candidate = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let title = RingSettingsPresentation.title(forURL: candidate) else { return nil }
        return RingLibraryItem(kind: .url(candidate), title: title, subtitle: candidate,
                               symbol: RingActionType.url.symbol, group: RingActionType.url.title)
    }

    static func looksLikePath(_ text: String) -> Bool {
        text.hasPrefix("/") || text.hasPrefix("~")
    }

    // MARK: - Defaults of an action

    /// The name a slice gets when the user has not renamed it.
    static func defaultTitle(for kind: RingActionKind, keywordName: (String, String) -> String? = { _, _ in nil })
        -> String {
        switch kind {
        case let .feature(feature): feature.title
        case let .system(system): system.title
        case let .keyword(keyword, pluginID): keywordName(keyword, pluginID) ?? keyword
        case let .app(_, name): name
        case let .keys(binding): L("ring.editor.keysTitle", HotkeyFormat.display(binding))
        case let .shortcut(name): name
        case let .url(url): RingSettingsPresentation.title(forURL: url) ?? url
        case let .folder(path): folderItem(path).title
        }
    }

    static func defaultSymbol(for kind: RingActionKind) -> String {
        switch kind {
        case let .feature(feature): feature.symbol
        case let .system(system): system.symbol
        default: kind.type.symbol
        }
    }
}

extension RingFeature {
    /// The library heading: "input", "screenshot" or "windows".
    var libraryGroup: String {
        switch self {
        case .dictation, .ask, .translate, .clipboard, .persona: "input"
        case .screenshot, .screenshotText, .screenshotTranslation: "screenshot"
        case .chat, .notes, .wordBook, .studio: "windows"
        }
    }
}

extension RingSystemAction {
    /// The library heading: "appearance", "desktop" or "security".
    var libraryGroup: String {
        switch self {
        case .darkMode, .mute, .keepAwake: "appearance"
        case .missionControl, .emoji: "desktop"
        case .lockScreen: "security"
        }
    }
}

/// Reads the user's shortcuts from the `shortcuts` command line tool.
enum RingShortcutsDiscovery {
    static let toolPath = "/usr/bin/shortcuts"

    /// One name per line; blank lines are skipped and duplicates kept once, in order.
    static func parse(_ output: String) -> [String] {
        var seen = Set<String>()
        return output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// The shortcut names, or nothing when the tool is missing, fails or takes longer than `timeout`.
    static func load(timeout: TimeInterval = 5) async -> [String] {
        guard FileManager.default.isExecutableFile(atPath: toolPath) else { return [] }
        return await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: toolPath)
            process.arguments = ["list"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return [] }
            let deadline = DispatchTime.now() + timeout
            DispatchQueue.global().asyncAfter(deadline: deadline) {
                if process.isRunning {
                    process.terminate()
                }
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return [] }
            return parse(String(bytes: data, encoding: .utf8) ?? "")
        }.value
    }
}
