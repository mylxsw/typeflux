import Foundation
import Security

/// Web search configuration for local Ask: the user's own Tavily or Brave key.
struct AskSearchSettings: Sendable {
    enum Provider: String, CaseIterable, Sendable { case none, tavily, brave }

    var defaults: UserDefaults
    var keychainService = "com.typeflux.ask.search"

    var provider: Provider {
        get { Provider(rawValue: defaults.string(forKey: "ask.search.provider") ?? "") ?? .none }
        nonmutating set { defaults.set(newValue.rawValue, forKey: "ask.search.provider") }
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: keychainService, kSecAttrAccount as String: "api-key"]
    }

    var apiKey: String {
        var item: CFTypeRef?
        var request = query
        request[kSecReturnData as String] = true
        guard SecItemCopyMatching(request as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    func setAPIKey(_ key: String) {
        SecItemDelete(query as CFDictionary)
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var item = query
        item[kSecValueData as String] = Data(trimmed.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }

    var isConfigured: Bool { provider != .none && !apiKey.isEmpty }
}

/// Web search executed on this Mac for local conversations. General web_fetch
/// fails closed until a transport can enforce the public-address policy at the
/// connection boundary; checking DNS before URLSession is not sufficient.
struct AskLocalWebTools: Sendable {
    /// Used only for the configured search provider, never arbitrary fetch URLs.
    var session: URLSession = .init(configuration: .ephemeral, delegate: AskPublicRedirectPolicy(), delegateQueue: nil)
    var searchProvider: @Sendable () -> (AskSearchSettings.Provider, String) = { (.none, "") }
    /// Resolves a host to its IP addresses; injectable for tests.
    var resolve: @Sendable (String) -> [String] = AskLocalWebTools.addresses(of:)
    var searchEndpoints: [AskSearchSettings.Provider: String] = [
        .tavily: "https://api.tavily.com/search", .brave: "https://api.search.brave.com/res/v1/web/search"
    ]

    var searchEnabled: Bool {
        let (provider, key) = searchProvider()
        return provider != .none && !key.isEmpty
    }

    static func schema(_ properties: [String: Any], required: [String]) -> JSONValue {
        JSONValue(data: try! JSONSerialization.data(withJSONObject: ["type": "object", "properties": properties, "required": required,
                                                                     "additionalProperties": false], options: .sortedKeys))
    }

    func definitions() -> [AskToolDefinition] {
        var result: [AskToolDefinition] = []
        if searchEnabled {
            result.append(AskToolDefinition(name: "web_search", description: "Search the public web for current or factual information. Returns titles, URLs and snippets. Cite the URLs you rely on.",
                                            parameters: Self.schema(["query": ["type": "string"], "count": ["type": "integer", "minimum": 1, "maximum": 10]], required: ["query"])))
        }
        return result
    }

    // MARK: - Address policy

    static func addresses(of host: String) -> [String] {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &list) == 0, let first = list else { return [] }
        defer { freeaddrinfo(list) }
        var result: [String] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let info = cursor {
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(info.pointee.ai_addr, info.pointee.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                result.append(String(cString: buffer))
            }
            cursor = info.pointee.ai_next
        }
        return result
    }

    /// True for globally routable unicast addresses.
    static func isPublic(_ address: String) -> Bool {
        let value = address.split(separator: "%").first.map(String.init) ?? address
        var v4 = in_addr()
        if inet_pton(AF_INET, value, &v4) == 1 {
            let b = withUnsafeBytes(of: v4.s_addr) { Array($0) }
            switch (b[0], b[1]) {
            case (0, _), (10, _), (127, _), (169, 254), (192, 168), (198, 18), (198, 19): return false
            case (172, 16 ... 31), (100, 64 ... 127): return false
            case (192, 0) where b[2] == 0 || b[2] == 2: return false
            case (198, 51) where b[2] == 100: return false
            case (203, 0) where b[2] == 113: return false
            default: return b[0] < 224
            }
        }
        var v6 = in6_addr()
        guard inet_pton(AF_INET6, value, &v6) == 1 else { return false }
        let b = withUnsafeBytes(of: v6) { Array($0) }
        if b[0 ..< 10].allSatisfy({ $0 == 0 }), b[10] == 0xFF, b[11] == 0xFF {
            return isPublic("\(b[12]).\(b[13]).\(b[14]).\(b[15])")
        }
        if b.allSatisfy({ $0 == 0 }) || (b[0 ..< 15].allSatisfy { $0 == 0 } && b[15] == 1) { return false }
        if b[0] == 0xFF || (b[0] & 0xFE) == 0xFC || (b[0] == 0xFE && (b[1] & 0xC0) == 0x80) { return false }
        if b[0] == 0x00, b[1] == 0x64, b[2] == 0xFF, b[3] == 0x9B { return false }
        if b[0] == 0x20, b[1] == 0x01, b[2] == 0x0D, b[3] == 0xB8 { return false }
        return true
    }

    func checkPublic(_ url: URL) throws { try Self.checkPublic(url, resolve: resolve) }

    static func checkPublic(_ url: URL, resolve: (String) -> [String] = addresses(of:)) throws {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), let host = url.host?.lowercased(), !host.isEmpty,
              url.user == nil, url.password == nil else { throw AskLocalError.message("Only public http(s) URLs without credentials can be fetched.") }
        let bare = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]."))
        if bare == "localhost" || bare.hasSuffix(".localhost") || bare.hasSuffix(".local") || bare.hasSuffix(".internal") {
            throw AskLocalError.message("This address is not reachable from the web tool.")
        }
        let addresses = resolve(bare)
        guard !addresses.isEmpty, addresses.allSatisfy(Self.isPublic) else {
            throw AskLocalError.message("This address is not reachable from the web tool.")
        }
    }

    // MARK: - Tools

    func execute(name: String, arguments: String) async -> (String, Bool) {
        do {
            let args = try AskLocalTools.jsonArguments(arguments)
            switch name {
            case "web_fetch": return (try await fetch(args["url"] as? String ?? ""), false)
            case "web_search": return (try await search(args["query"] as? String ?? "", count: args["count"] as? Int ?? 5), false)
            default: return ("This web tool is not available.", true)
            }
        } catch {
            return (error.localizedDescription, true)
        }
    }

    func fetch(_: String) async throws -> String {
        // Keep this entry point for calls from persisted runs. URLSession owns
        // resolution/connection selection independently of checkPublic, and its
        // response/metrics callbacks are too late to prevent private access.
        // Refuse before DNS, proxies, redirects, TLS or response allocation.
        // Re-enabling requires a verified transport, not an availability flag
        // or another DNS lookup. See docs/LOCAL_WEB_FETCH_BOUNDARY.md.
        throw AskLocalError.message("Local web_fetch is unavailable because a safe connection to the destination cannot be guaranteed. No request was sent.")
    }

    /// Offline HTML extraction retained independently of fetch availability.
    /// Does not load subresources or authorize a network request.
    static func htmlText(_ html: String) -> (String, String) {
        func replace(_ pattern: String, in text: String, with template: String) -> String {
            (try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]))
                .map { $0.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template) } ?? text
        }
        var title = ""
        if let regex = try? NSRegularExpression(pattern: "<title[^>]*>(.*?)</title>", options: [.caseInsensitive, .dotMatchesLineSeparators]),
           let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)), let range = Range(match.range(at: 1), in: html) {
            title = decodeEntities(String(html[range])).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        var text = html
        for tag in ["script", "style", "noscript", "template", "svg", "head", "title", "nav", "footer", "aside", "form", "button", "select"] {
            text = replace("<\(tag)\\b[^>]*>.*?</\(tag)>", in: text, with: " ")
        }
        text = replace("<!--.*?-->", in: text, with: " ")
        text = replace("<h([1-6])\\b[^>]*>", in: text, with: "\n# ")
        text = replace("<li\\b[^>]*>", in: text, with: "\n- ")
        text = replace("<(br|/p|/div|/section|/article|/h[1-6]|/li|/tr|/table|/blockquote|/pre|p|div|tr)\\b[^>]*>", in: text, with: "\n")
        text = replace("<[^>]+>", in: text, with: " ")
        text = decodeEntities(text)
        let lines = text.components(separatedBy: "\n").map { $0.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\r" }).joined(separator: " ") }
        return (title, lines.filter { !$0.isEmpty && $0 != "-" && $0 != "#" }.joined(separator: "\n"))
    }

    static func decodeEntities(_ text: String) -> String {
        var result = text
        for (entity, value) in ["&nbsp;": " ", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'"] {
            result = result.replacingOccurrences(of: entity, with: value)
        }
        if let regex = try? NSRegularExpression(pattern: "&#(x?)([0-9a-fA-F]+);") {
            for match in regex.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed() {
                guard let whole = Range(match.range, in: result), let hex = Range(match.range(at: 1), in: result),
                      let digits = Range(match.range(at: 2), in: result),
                      let code = UInt32(result[digits], radix: result[hex].isEmpty ? 10 : 16), let scalar = Unicode.Scalar(code) else { continue }
                result.replaceSubrange(whole, with: String(Character(scalar)))
            }
        }
        return result.replacingOccurrences(of: "&amp;", with: "&")
    }

    func search(_ query: String, count: Int) async throws -> String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 400 else { throw AskLocalError.message("A query of at most 400 characters is required.") }
        let (provider, key) = searchProvider()
        guard provider != .none, !key.isEmpty, let endpoint = searchEndpoints[provider].flatMap(URL.init(string:)) else {
            throw AskLocalError.message("Web search is not configured.")
        }
        let limit = min(max(count, 1), 10)
        var request: URLRequest
        if provider == .tavily {
            request = URLRequest(url: endpoint, timeoutInterval: 15)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["query": trimmed, "max_results": limit])
        } else {
            var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
            components.queryItems = [.init(name: "q", value: trimmed), .init(name: "count", value: String(limit))]
            request = URLRequest(url: components.url!, timeoutInterval: 15)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue(key, forHTTPHeaderField: "X-Subscription-Token")
        }
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, let body = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AskLocalError.message("Search is temporarily unavailable.")
        }
        let items = provider == .tavily
            ? (body["results"] as? [[String: Any]] ?? []).map { ($0["title"] as? String ?? "", $0["url"] as? String ?? "", $0["content"] as? String ?? "") }
            : ((body["web"] as? [String: Any])?["results"] as? [[String: Any]] ?? []).map { ($0["title"] as? String ?? "", $0["url"] as? String ?? "", $0["description"] as? String ?? "") }
        guard !items.isEmpty else { return "No results." }
        return items.prefix(limit).enumerated().map { index, item in
            var line = "\(index + 1). \(item.0)\n   \(item.1)"
            let snippet = item.2.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            if !snippet.isEmpty { line += "\n   " + snippet }
            return line
        }.joined(separator: "\n")
    }
}

/// Search-provider redirect preflight. This is not a socket destination guard
/// and must not be used to enable general-purpose web_fetch.
final class AskPublicRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_: URLSession, task _: URLSessionTask, willPerformHTTPRedirection _: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, (try? AskLocalWebTools.checkPublic(url)) != nil else { return completionHandler(nil) }
        completionHandler(request)
    }
}
