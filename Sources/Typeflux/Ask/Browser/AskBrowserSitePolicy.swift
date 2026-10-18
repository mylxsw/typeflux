import Foundation

/// What the AI may do on one site in the embedded browser. The user sets it;
/// model output never changes it.
enum AskBrowserSitePermission: String, CaseIterable, Codable, Sendable {
    case off, ask, read, act

    var title: String { L("ask.web.permission." + rawValue) }
}

/// Per-site AI permissions, keyed by lowercased host. Unknown sites ask.
@MainActor
final class AskBrowserSitePolicy: ObservableObject {
    static let defaultsKey = "ask.web.sitePermissions"
    static let fallback = AskBrowserSitePermission.ask

    private let defaults: UserDefaults
    @Published private(set) var permissions: [String: AskBrowserSitePermission]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.dictionary(forKey: Self.defaultsKey) as? [String: String] ?? [:]
        permissions = stored.compactMapValues(AskBrowserSitePermission.init(rawValue:))
    }

    func permission(for host: String?) -> AskBrowserSitePermission {
        guard let host = Self.normalized(host) else { return Self.fallback }
        return permissions[host] ?? Self.fallback
    }

    func set(_ permission: AskBrowserSitePermission, for host: String) {
        guard let host = Self.normalized(host) else { return }
        permissions[host] = permission
        defaults.set(permissions.mapValues(\.rawValue), forKey: Self.defaultsKey)
    }

    func remove(_ host: String) {
        guard let host = Self.normalized(host) else { return }
        permissions[host] = nil
        defaults.set(permissions.mapValues(\.rawValue), forKey: Self.defaultsKey)
    }

    /// `www.` is the same site to the user; everything else is compared exactly.
    nonisolated static func normalized(_ host: String?) -> String? {
        guard var host = host?.lowercased().trimmingCharacters(in: .whitespaces), !host.isEmpty else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }
}

/// Maps a `web_browser` call to an approval risk. Tiers decide when Standard mode
/// asks the user; site permission `off` is enforced separately at execution.
enum AskBrowserRisk {
    enum Kind: Equatable { case none, observe, navigate, write, sensitive }

    static let observeActions: Set<String> = ["read", "snapshot", "screenshot"]
    static let navigateActions: Set<String> = ["open", "back", "scroll", "new_tab", "close_tab"]
    static let writeActions: Set<String> = ["click", "fill"]
    static let neutralActions: Set<String> = ["tabs", "select_tab", "wait", "handoff"]

    /// Words on a control that commit money, messages or deletions. Clicking one
    /// always asks, whatever the site permission.
    static let sensitiveWords = [
        "pay", "buy", "purchase", "checkout", "order", "send", "delete", "remove", "transfer", "confirm", "submit",
        "publish", "post", "unsubscribe", "支付", "付款", "购买", "下单", "结算", "发送", "删除", "转账", "确认",
        "提交", "发布", "注销", "退订", "購買", "送信", "削除", "결제", "구매", "전송", "삭제"
    ]

    static func kind(action: String, elementName: String?) -> Kind {
        if neutralActions.contains(action) { return .none }
        if observeActions.contains(action) { return .observe }
        if navigateActions.contains(action) { return .navigate }
        guard writeActions.contains(action) else { return .sensitive }
        if action == "click", isSensitive(elementName) { return .sensitive }
        return .write
    }

    static func isSensitive(_ name: String?) -> Bool {
        guard let name = name?.lowercased(), !name.isEmpty else { return false }
        return sensitiveWords.contains { word in
            // Latin words match whole words, so "Postman" or "Ordering" stay ordinary.
            if word.unicodeScalars.allSatisfy(\.isASCII) {
                return name.range(of: "\\b" + word + "\\b", options: .regularExpression) != nil
            }
            return name.contains(word)
        }
    }

    static func risk(_ kind: Kind, permission: AskBrowserSitePermission) -> AskToolRisk {
        switch (kind, permission) {
        case (.none, _): .none
        case (.sensitive, _): .destructive
        // Execution refuses `off`; nothing is gained by asking first.
        case (_, .off): .read
        case (.observe, .ask), (.navigate, .ask), (.write, .ask), (.write, .read): .write
        case (.observe, _), (.navigate, _), (.write, .act): .read
        }
    }
}
