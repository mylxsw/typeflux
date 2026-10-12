import Foundation

enum EmojiAction: Equatable, Sendable {
    case favorite(String)
    case variant(id: String, sequence: String)
    case copyAndStay
    case clearRecent
}

struct EmojiResult: Equatable, Sendable, Identifiable {
    var entry: EmojiEntry
    var sequence: String
    var name: String
    var reason: String
    var favorite: Bool
    var id: String {
        entry.id
    }
}

struct EmojiPresentation: Equatable, Sendable {
    var results: [EmojiResult]
    var scope: EmojiScope
    var language: AppLanguage
}

struct AskEmojiPlugin: AskLauncherPlugin {
    static let id = "emoji"
    static let keywords = [AskKeyword(keyword: "emoji", pluginID: id, aliases: ["表情"])]
    var id: String {
        Self.id
    }

    var title: String {
        L("emoji.title")
    }

    var symbol: String {
        "face.smiling"
    }

    var defaultKeywords: [AskKeyword] {
        Self.keywords
    }

    var runsWithoutInput: Bool {
        true
    }

    var usesSelectionInput: Bool {
        false
    }

    var entersOnReturn: Bool {
        true
    }

    var service: EmojiSearchService = .shared
    var usage: @MainActor @Sendable () -> EmojiUsage = { EmojiUsage() }

    func placeholder(selectionLines _: Int?) -> String {
        L("emoji.placeholder")
    }

    func chipDetail(for _: AskKeyword, language _: AppLanguage) -> String? {
        nil
    }

    func nextOptions(after _: AskPluginPlan, request _: AskPluginRequest, step _: Int) -> [String: String]? {
        nil
    }

    func plan(_: AskPluginRequest) async -> AskPluginPlan {
        AskPluginPlan(mode: .live, title: title, debounce: .milliseconds(60))
    }

    // Plan, search and adapt the result in one cancellation-aware operation.
    // swiftlint:disable:next function_body_length
    func run(_ request: AskPluginRequest, plan _: AskPluginPlan,
             progress _: @escaping AskPluginProgress) async throws -> AskPluginOutput {
        let usage = await usage()
        let scope = EmojiScope(rawValue: request.options["scope"] ?? "") ?? .all
        let query = request.origin == .argument ? request.text : ""
        let matches: [EmojiMatch]
        do {
            matches = try await service.search(query, scope: scope, usage: usage)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw AskPluginFailure(message: L("emoji.loadFailed"))
        }
        let selectedID = request.options["selectedQuery"] == query ? request.options["selectedID"] : nil
        let results = matches.map { match in
            let entry = match.entry
            let preferred = scope == .recent ? usage.recent.first { $0.id == entry.id }?.sequence : usage
                .variants[entry.id]
            // Pasting a complete variant searches and copies that exact sequence.
            let chosen = selectedID == entry.id ? request.options["selectedVariant"]
                .flatMap { $0.isEmpty ? nil : $0 } : nil
            let pasted = entry.variants
                .first { EmojiSearchService.emojiKey($0.sequence) == EmojiSearchService.emojiKey(query) }?.sequence
            let exact = chosen ?? pasted ?? preferred
            let sequence = entry.sequence(preferred: exact)
            return EmojiResult(
                entry: entry,
                sequence: sequence,
                name: entry.name(request.interfaceLanguage, sequence: sequence),
                reason: Self.reason(match.reason),
                favorite: usage.favorites.contains(entry.id)
            )
        }
        let items = results.map { result in
            AskPluginItem(id: result.id, title: result.sequence + " " + result.name, subtitle: result.reason,
                          actions: [
                              .init(
                                  kind: .copy(result.sequence),
                                  title: L("ask.plugin.action.copy"),
                                  symbol: "doc.on.doc",
                                  shortcut: .enter
                              ),
                              .init(
                                  kind: .copy(result.sequence),
                                  title: L("ask.plugin.action.copy"),
                                  symbol: "doc.on.doc",
                                  shortcut: .commandC
                              ),
                              .init(
                                  kind: .writeBack(result.sequence),
                                  title: L("emoji.insert"),
                                  symbol: "arrow.up.forward",
                                  shortcut: .optionEnter
                              )
                          ])
        }
        return AskPluginOutput(body: results.map(\.name).joined(separator: "\n"), original: query, meta: [],
                               source: L("ask.plugin.source.device"), actions: [], items: items,
                               selectedItem: results.firstIndex { $0.id == selectedID } ?? 0,
                               emoji: EmojiPresentation(
                                   results: results,
                                   scope: scope,
                                   language: request.interfaceLanguage
                               ))
    }

    static func reason(_ reason: String) -> String {
        if reason.hasPrefix("intent:") {
            return L("emoji.match.intent")
        }
        if reason.hasPrefix("typo:") {
            return L("emoji.match.typo") + " · " + reason.dropFirst(5)
        }
        return L("emoji.match." + reason)
    }
}
