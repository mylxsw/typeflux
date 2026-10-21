import Darwin
import Foundation

/// What the AI may do on one site in the embedded browser. The user sets it;
/// model output never changes it.
enum AskBrowserSitePermission: String, CaseIterable, Codable, Sendable {
    case off, ask, read, act

    /// Compatibility values remain decodable; presentation offers one read/navigation choice.
    static let choices: [Self] = [.off, .ask, .read]
    var presented: Self { self == .act ? .read : self }
    var title: String { L("ask.web.permission." + presented.rawValue) }
}

/// Exact HTTP origin. Paths, cookies, display names and userinfo cannot mint authority.
struct AskHTTPOrigin: Hashable, Sendable, CustomStringConvertible {
    let scheme: String
    let host: String
    let port: Int

    init?(_ url: URL?) {
        guard let url, let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              components.user == nil, components.password == nil,
              let rawHost = components.url?.host?.lowercased(), !rawHost.isEmpty else { return nil }
        if components.host?.hasPrefix("[") == true, !rawHost.contains(":") { return nil }
        let host = rawHost.hasPrefix("[") && rawHost.hasSuffix("]") ? String(rawHost.dropFirst().dropLast()) : rawHost
        let authority = url.absoluteString.dropFirst(scheme.count + 3).prefix { !"/?#".contains($0) }
        guard !authority.hasSuffix(":"), components.rangeOfPort == nil || components.port != nil else { return nil }
        let port = components.port ?? (scheme == "http" ? 80 : 443)
        guard !host.contains("%"), !host.contains(where: \.isWhitespace),
              host.unicodeScalars.allSatisfy(\.isASCII),
              (1 ... 65535).contains(port)
        else { return nil }
        if host.contains(":") {
            var address = in6_addr()
            guard host.withCString({ inet_pton(AF_INET6, $0, &address) }) == 1 else { return nil }
            var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            guard inet_ntop(AF_INET6, &address, &buffer, socklen_t(buffer.count)) != nil else { return nil }
            self.host = String(cString: buffer)
        } else {
            guard host.utf8.count <= 253,
                  host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ label in
                      !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-" &&
                          label.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
                  }) else { return nil }
            self.host = host
        }
        self.scheme = scheme; self.port = port
    }

    init?(string: String) {
        self.init(URL(string: string))
    }

    var description: String {
        let authority = host.contains(":") ? "[" + host + "]" : host
        return scheme + "://" + authority +
            ((scheme == "http" && port == 80) || (scheme == "https" && port == 443) ? "" : ":\(port)")
    }
}

/// Versioned exact-origin policy, partitioned by the authenticated local profile.
@MainActor
final class AskBrowserSitePolicy: ObservableObject {
    static let defaultsKey = "ask.web.sitePermissions"
    static let originDefaultsKey = "ask.web.originPermissions.v2"
    static let fallback = AskBrowserSitePermission.ask
    private let defaults: UserDefaults
    private let owner: @MainActor () -> String
    private let deviceId: String
    @Published private var revision = 0

    init(defaults: UserDefaults = .standard, owner: @escaping @MainActor () -> String = { GlobalSoulOwner.currentID },
         deviceId: String? = nil) {
        self.defaults = defaults; self.owner = owner
        self.deviceId = deviceId ?? defaults.string(forKey: "ask.deviceId") ?? "local-browser-profile"
    }

    private var key: String {
        Self.originDefaultsKey + "." + AskToolPolicy.digest(owner() + "\u{0}" + deviceId)
    }

    var permissions: [String: AskBrowserSitePermission] {
        let raw = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
        return raw.filter { AskHTTPOrigin(string: $0.key)?.description == $0.key }
            .compactMapValues(AskBrowserSitePermission.init(rawValue:))
    }

    var legacyPreferences: [String: AskBrowserSitePermission] {
        (defaults.dictionary(forKey: Self.defaultsKey) as? [String: String] ?? [:])
            .compactMapValues(AskBrowserSitePermission.init(rawValue:))
    }

    func permission(for value: String?) -> AskBrowserSitePermission {
        guard let value else { return .ask }
        // Legacy denies retain their original www matching, including Unicode hosts.
        // This compatibility lookup can only deny; it never constructs an origin grant.
        if let url = URL(string: value), let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
           legacyPreferences.contains(where: { entry in
               entry.value == .off && [components.host, url.host].contains { host in
                   host != nil && entry.key == Self.normalized(host)
               }
           }) {
            return .off
        }
        guard let origin = AskHTTPOrigin(string: value) else { return .ask }
        return permissions[origin.description] ?? .ask
    }

    func set(_ permission: AskBrowserSitePermission, for value: String) {
        guard let origin = AskHTTPOrigin(string: value) else { return }
        var current = permissions; current[origin.description] = permission
        defaults.set(current.mapValues(\.rawValue), forKey: key); revision += 1
    }

    func remove(_ value: String) {
        if let origin = AskHTTPOrigin(string: value) {
            var current = permissions; current[origin.description] = nil
            defaults.set(current.mapValues(\.rawValue), forKey: key)
        } else {
            var legacy = legacyPreferences
            legacy[value] = nil
            defaults.set(legacy.mapValues(\.rawValue), forKey: Self.defaultsKey)
        }
        revision += 1
    }

    /// Cookie grouping and restrictive legacy compatibility only. Never an allow key.
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

    static func kind(action: String, elementName _: String?) -> Kind {
        if neutralActions.contains(action) { return .none }
        if observeActions.contains(action) { return .observe }
        if navigateActions.contains(action) { return .navigate }
        guard writeActions.contains(action) else { return .sensitive }
        // Generic DOM mutations do not establish harmless intent, including fills.
        return .sensitive
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
