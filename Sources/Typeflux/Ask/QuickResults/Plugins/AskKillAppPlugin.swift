import AppKit
import Foundation

/// Identifies one running instance, so a stale row cannot quit a replacement app.
struct AskKillAppTarget: Equatable, Sendable {
    var app: AskAppEntry
    var processID: Int32
    var launchDate: Date?
}

/// Lists running apps while typing; only an explicit result action quits an app.
struct AskKillAppPlugin: AskLauncherPlugin {
    static let id = "killApp"
    static let keywords = [AskKeyword(keyword: "kill", pluginID: id)]

    var applications: @MainActor @Sendable () -> [AskKillAppTarget] = { runningApplications() }
    var id: String { Self.id }
    var title: String { L("ask.plugin.kill.title") }
    var symbol: String { "xmark.app" }
    var defaultKeywords: [AskKeyword] { Self.keywords }
    var runsWithoutInput: Bool { true }
    var usesSelectionInput: Bool { false }
    var entersOnReturn: Bool { true }

    func placeholder(selectionLines _: Int?) -> String { L("ask.plugin.kill.placeholder") }
    func chipDetail(for _: AskKeyword, language _: AppLanguage) -> String? { nil }

    func plan(_: AskPluginRequest) async -> AskPluginPlan {
        AskPluginPlan(mode: .live, title: title, debounce: .milliseconds(16))
    }

    func run(_ request: AskPluginRequest, plan _: AskPluginPlan,
             progress _: @escaping AskPluginProgress) async throws -> AskPluginOutput {
        let targets = await applications().filter { $0.processID != ProcessInfo.processInfo.processIdentifier }
        let query = request.origin == .argument ? request.text.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let matches = query.isEmpty ? targets.sorted {
            $0.app.name.localizedStandardCompare($1.app.name) == .orderedAscending
        } : targets.compactMap { target -> (AskKillAppTarget, Double)? in
            AskAppMatcher.score(query, target.app).map { (target, $0) }
        }.sorted { lhs, rhs in
            lhs.1 == rhs.1 ? lhs.0.app.name.localizedStandardCompare(rhs.0.app.name) == .orderedAscending : lhs.1 > rhs.1
        }.map(\.0)
        var items = matches.map { target in
            AskPluginItem(id: String(target.processID), title: target.app.name,
                          subtitle: L("ask.plugin.kill.running", String(target.processID)),
                          icon: .fileIcon(target.app.url),
                          actions: [AskPluginAction(kind: .killApp(target), title: L("ask.plugin.kill.action"),
                                                    symbol: symbol, shortcut: .enter)])
        }
        if items.isEmpty {
            items = [AskPluginItem(id: "kill.empty", title: L("ask.plugin.kill.empty"),
                                   icon: .symbol(symbol), valid: false)]
        }
        return AskPluginOutput(body: items.map(\.title).joined(separator: "\n"), original: query, meta: [],
                               source: L("ask.plugin.source.device"), note: L("ask.plugin.kill.warning"),
                               actions: [], items: items)
    }

    func nextOptions(after _: AskPluginPlan, request _: AskPluginRequest, step _: Int) -> [String: String]? { nil }

    @MainActor
    static func runningApplications() -> [AskKillAppTarget] {
        NSWorkspace.shared.runningApplications.compactMap { running in
            guard running.activationPolicy == .regular, !running.isTerminated,
                  running.processIdentifier != ProcessInfo.processInfo.processIdentifier,
                  let url = running.bundleURL else { return nil }
            let name = running.localizedName ?? url.deletingPathExtension().lastPathComponent
            return AskKillAppTarget(app: AskAppEntry(name: name, url: url, bundleID: running.bundleIdentifier,
                                                     names: [url.deletingPathExtension().lastPathComponent]),
                                    processID: running.processIdentifier, launchDate: running.launchDate)
        }
    }

    @MainActor
    static func forceQuit(_ target: AskKillAppTarget) -> Bool {
        guard target.processID != ProcessInfo.processInfo.processIdentifier,
              let running = NSRunningApplication(processIdentifier: target.processID),
              !running.isTerminated, running.activationPolicy == .regular,
              running.bundleURL == target.app.url, running.bundleIdentifier == target.app.bundleID,
              running.launchDate == target.launchDate else { return false }
        return running.forceTerminate()
    }
}
